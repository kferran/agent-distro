#!/usr/bin/env python3
"""deploy_tracker_web — crawl the EDJ deployment tracker (web UI) and compute
per-environment deployment verdicts for EJA/ASD keys. Read-only. stdlib only.
See 99 Meta/specs/2026-06-22-deploy-verify-design.md."""
import re, json, sys, argparse, datetime, urllib.request, urllib.parse

TRACKER = "http://deployment-tracker.np.porch.internal"
CORE_ENVS = [
    ("dev",        "core-edj:edj.dev.annuity.porch.software"),
    ("test",       "core-edj:edj-test.dev.annuity.porch.software"),
    ("demo",       "core-edj:edj-demo.np.annuity.porch.software"),
    ("playground", "core-edj:edj-playground.np.annuity.porch.software"),
    ("preprod",    "core-edj:edj-preprod.np.annuity.porch.software"),
    ("uat",        "core-edj:edj-uat.np.annuity.porch.software"),
]
UAT_ZONE = "core-edj:edj-uat.np.annuity.porch.software"

_OPT_RE = re.compile(r'<option value="([^"]+)"')
_KEY_RE = re.compile(r"\b(?:EJA|ASD)-\d+\b")
_CROCK = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

def parse_promotions(stage_html):
    """Option values that carry a 26-char ULID segment = promotions (builds)."""
    return [v for v in _OPT_RE.findall(stage_html)
            if any(len(p) == 26 for p in v.split("."))]

def extract_keys(html):
    """Distinct EJA-/ASD- keys mentioned anywhere in the page."""
    return set(_KEY_RE.findall(html))

def ulid_timestamp(value):
    """UTC datetime from the 26-char ULID segment's 48-bit ms prefix, else None."""
    for part in value.split("."):
        if len(part) == 26:
            ms = 0
            for c in part.upper()[:10]:
                ms = ms * 32 + _CROCK.index(c)
            return datetime.datetime.utcfromtimestamp(ms / 1000)
    return None

def _stage_url(warehouse, stage):
    return f"{TRACKER}/?{urllib.parse.urlencode({'warehouse': warehouse, 'stage': stage})}"

def _promo_url(warehouse, stage, promotion):
    return f"{TRACKER}/?{urllib.parse.urlencode({'warehouse': warehouse, 'stage': stage, 'promotion': promotion})}"

def fetch(url, timeout=25):
    """Real HTTP GET (plain http; tracker holds its own backend creds)."""
    with urllib.request.urlopen(url, timeout=timeout) as r:
        body = r.read().decode("utf-8", "replace")
    if not body:
        raise RuntimeError(f"empty body from {url}")
    return body

def crawl_stage(warehouse, stage, fetch=fetch, since=None):
    """Union of keys + (oldest,newest) window across a stage's promotions.
    Tolerates individual empty (infra-only) builds. If `since` (a datetime) is
    given, only fetch promotion detail pages at-or-after it — older builds' keys
    are already in the cached union (incremental crawl, avoids re-fetching the
    full history). A per-promotion fetch failure is skipped (counted, not fatal),
    so one slow/timed-out build never aborts the whole crawl."""
    proms = parse_promotions(fetch(_stage_url(warehouse, stage)))
    keys, dates, empty, skipped_old, failures = set(), [], 0, 0, 0
    first = {}   # key -> earliest build ts (iso) OBSERVED IN THIS CRAWL that carried it
    for p in proms:
        ts = ulid_timestamp(p)
        if since is not None and ts is not None and ts < since:
            skipped_old += 1
            continue
        try:
            page_keys = extract_keys(fetch(_promo_url(warehouse, stage, p)))
        except Exception as e:
            failures += 1
            print(f"  [warn] {stage} promo {p[:14]} fetch failed: {e}", file=sys.stderr)
            continue
        if not page_keys:
            empty += 1
        keys |= page_keys
        if ts:
            dates.append(ts)
            # "which build first carried this key" — the association the old crawl threw
            # away by unioning keys. Without it the tracker answers "is it deployed?" but
            # not "was it deployed WHEN?", and for reconciling a Failed QE against a retest
            # only the second question matters. (2026-07-31: EJA-3881 read as "deployed 24h
            # before the retest" on a merge-time reading; the real Playground margin was
            # 5m10s, which flips the conclusion.)
            iso = ts.isoformat()
            for k in page_keys:
                if k not in first or iso < first[k]:
                    first[k] = iso
    window = ({"oldest": min(dates).isoformat(), "newest": max(dates).isoformat()}
              if dates else None)
    return {"keys": sorted(keys), "first_seen": first, "window": window,
            "promotions": len(proms),
            "fetched": len(proms) - skipped_old, "skipped_old": skipped_old,
            "empty_promotions": empty, "fetch_failures": failures}

_CAVEAT = ("absent != undeployed: the tracker attributes builds by commit-message key, "
           "so by-proxy or unkeyed merges can read as absent — verify before acting")

def compute_verdict(candidates, union, windows):
    """candidates: {ticket: [{key, resolutiondate}]}; union: {key: [zone,...]};
    windows: {zone: {oldest, newest}}. Returns {ticket: {headline, env_map, carrying_key, caveat}}."""
    uat_win = windows.get(UAT_ZONE)
    out = {}
    for ticket, cands in candidates.items():
        env_map = {}
        for label, zone in CORE_ENVS:
            env_map[label] = next((c["key"] for c in cands if zone in union.get(c["key"], [])), None)
        anywhere = any(union.get(c["key"]) for c in cands)
        if env_map["uat"]:
            headline, caveat = "in UAT", None
        elif anywhere:
            headline, caveat = "promoted, not UAT", None
        else:
            res = [c["resolutiondate"][:10] for c in cands if c.get("resolutiondate")]
            newest = max(res) if res else None
            if uat_win and newest:
                if newest < uat_win["oldest"][:10]:
                    headline, caveat = "pre-window (cannot confirm)", None
                elif newest > uat_win["newest"][:10]:
                    headline, caveat = "too-new", None
                else:
                    headline, caveat = "genuine gap", _CAVEAT
            else:
                headline, caveat = "unknown", None
        carrying = next((env_map[l] for l, _ in reversed(CORE_ENVS) if env_map[l]), None)
        out[ticket] = {"headline": headline, "env_map": env_map,
                       "carrying_key": carrying, "caveat": caveat}
    return out

DEFAULT_CACHE = "/tmp/deploy-tracker-cache.json"
INTEGRATION_WAREHOUSES = ["integration-acord", "integration-cannex", "integration-coop",
    "integration-dtcc", "integration-edj", "integration-mocksso", "integration-schema",
    "integration-sftp", "integrations"]

def _load_cache(path):
    try:
        with open(path) as f: return json.load(f)
    except FileNotFoundError:
        return {"union": {}, "windows": {}, "stages_covered": []}

def _save_cache(path, cache):
    with open(path, "w") as f: json.dump(cache, f)

def crawl_is_broken(total_builds, total_keys):
    """Aggregate UI-breakage signal: builds exist but the whole crawl yielded zero keys."""
    return total_builds > 0 and total_keys == 0

_OVERLAP = datetime.timedelta(days=1)  # re-fetch the last day of builds to catch boundary stragglers

def cmd_crawl(args):
    cache = {"union": {}, "windows": {}, "stages_covered": []} if args.refresh else _load_cache(args.cache)
    targets = [("core-edj", z.split(":", 1)[1]) for _, z in CORE_ENVS]  # all core-edj envs
    if args.integration:
        for w in INTEGRATION_WAREHOUSES:
            page = fetch(f"{TRACKER}/?warehouse={w}")
            for s in re.findall(r'<option value="((?:validation|development)-[^"]+)"', page):
                targets.append((w, s))
    total_fetched = 0
    for warehouse, stage in targets:
        zone = f"{warehouse}:{stage}"
        # INCREMENTAL: re-fetch only promotions newer than the cached window (minus a 1d
        # overlap). This fixes the two-headed bug: the old code SKIPPED already-covered
        # zones on a normal run (cache froze forever), and --refresh re-fetched the ENTIRE
        # history (timed out). Now every run advances the window cheaply; --refresh still
        # forces a full rebuild (since stays None on the wiped cache).
        since = None
        if not args.refresh:
            w = cache["windows"].get(zone)
            if w and w.get("newest"):
                try:
                    since = datetime.datetime.fromisoformat(w["newest"][:19]) - _OVERLAP
                except ValueError:
                    since = None
        try:
            res = crawl_stage(warehouse, stage, since=since)
        except Exception as e:  # a bad stage page shouldn't kill the other zones
            print(f"  [warn] zone {zone} crawl failed: {e}", file=sys.stderr)
            continue
        total_fetched += res["fetched"]
        for k in res["keys"]:
            cache["union"].setdefault(k, [])
            if zone not in cache["union"][k]:
                cache["union"][k].append(zone)
        # first_seen[key][zone] = earliest build carrying it. Keep the EARLIEST across runs:
        # an incremental crawl only sees recent builds, so a later run must never overwrite
        # an earlier, truer date.
        fs = cache.setdefault("first_seen", {})
        for k, iso in res.get("first_seen", {}).items():
            z = fs.setdefault(k, {})
            if zone not in z or iso < z[zone]:
                z[zone] = iso
        if res["window"]:  # merge with the prior window — incremental fetch only advances newest
            old = cache["windows"].get(zone)
            cache["windows"][zone] = ({
                "oldest": min(old["oldest"], res["window"]["oldest"]),
                "newest": max(old["newest"], res["window"]["newest"]),
            } if old else res["window"])
        if zone not in cache["stages_covered"]:
            cache["stages_covered"].append(zone)
        newest = cache["windows"].get(zone, {}).get("newest", "-")[:10]
        print(f"crawled {zone}: {res['fetched']}/{res['promotions']} fetched "
              f"(skip {res['skipped_old']} old, fail {res['fetch_failures']}), "
              f"{len(res['keys'])} new-keys, window→{newest}", file=sys.stderr)
    if crawl_is_broken(total_fetched, len(cache["union"])):
        raise RuntimeError(f"crawl: {total_fetched} builds fetched but 0 keys — tracker UI may have changed")
    _save_cache(args.cache, cache)
    newest_overall = max((w["newest"][:10] for w in cache["windows"].values() if w.get("newest")), default="none")
    print(json.dumps({"stages_covered": cache["stages_covered"],
                      "keys": len(cache["union"]), "newest_build": newest_overall}))

def cmd_verdict(args):
    cache = _load_cache(args.cache)
    # STALENESS GUARD: a stale cache makes "too-new" verdicts unreliable — a fix newer than
    # the last crawled build reads too-new even if it actually deployed. Warn (don't fail) so
    # the caller re-runs `crawl` first (now incremental/fast).
    uat = cache.get("windows", {}).get(UAT_ZONE, {})
    if uat.get("newest"):
        try:
            age = (datetime.datetime.utcnow() - datetime.datetime.fromisoformat(uat["newest"][:19])).days
            if age > 3:
                print(f"[warn] deploy cache stale: newest UAT build {uat['newest'][:10]} ({age}d old). "
                      f"Run `crawl` first — 'too-new' verdicts are unreliable until then.", file=sys.stderr)
        except ValueError:
            pass
    raw = sys.stdin.read() if args.candidates == "-" else open(args.candidates).read()
    candidates = json.loads(raw)
    print(json.dumps(compute_verdict(candidates, cache["union"], cache["windows"]), indent=2))

def cmd_when(args):
    """WAS it deployed when? — the question a Failed-QE reconciliation actually asks.

    Prints, per stage, the earliest build that carried KEY, and (with --at) whether that
    predates a given instant. --at accepts an ISO timestamp; bare dates mean 00:00 UTC."""
    cache = _load_cache(args.cache)
    fs = cache.get("first_seen", {})
    if not fs:
        print("[warn] this cache predates first_seen — run `crawl --refresh` to populate it.",
              file=sys.stderr)
    seen = fs.get(args.key, {})
    at = None
    if args.at:
        s = args.at.strip().replace("Z", "")
        if len(s) == 10: s += "T00:00:00"
        try:
            at = datetime.datetime.fromisoformat(s[:19])
        except ValueError:
            print(f"error: --at '{args.at}' is not an ISO timestamp", file=sys.stderr); return 2
    out = {"key": args.key, "at": at.isoformat() if at else None, "stages": {}}
    for label, zone in CORE_ENVS:
        iso = seen.get(zone)
        win = cache.get("windows", {}).get(zone, {})
        row = {"first_carried": iso}
        if iso and at:
            row["deployed_before_at"] = iso < at.isoformat()
            # Sign handled explicitly: floor-division on a negative delta reports a 51-minute
            # gap as "-1h 8m", and a margin that reads wrong is the exact failure this
            # command exists to prevent. "before"/"after" is stated, never inferred from sign.
            secs = (at - datetime.datetime.fromisoformat(iso[:19])).total_seconds()
            mag = abs(secs)
            row["margin"] = (f"{int(mag // 3600)}h {int(mag % 3600 // 60)}m "
                             f"{'before' if secs >= 0 else 'AFTER'} --at")
        elif at and not iso:
            # absent from first_seen is NOT proof it never deployed — an incremental crawl
            # may simply not have fetched the introducing build. Say so rather than implying.
            row["deployed_before_at"] = None
            row["note"] = ("no build in the crawled window carried this key; "
                           f"window starts {win.get('oldest','?')[:19]} — "
                           "re-run `crawl --refresh` before concluding it never deployed")
        out["stages"][label] = row
    print(json.dumps(out, indent=2))
    return 0

def main(argv=None):
    p = argparse.ArgumentParser(description="EDJ deployment tracker verifier (read-only)")
    p.add_argument("--cache", default=DEFAULT_CACHE)
    sub = p.add_subparsers(dest="cmd", required=True)
    w = sub.add_parser("when", help="when did KEY first reach each env (and was that before --at)?")
    w.add_argument("key"); w.add_argument("--at", default=None)
    w.set_defaults(func=cmd_when)
    c = sub.add_parser("crawl"); c.add_argument("--integration", action="store_true")
    c.add_argument("--refresh", action="store_true"); c.set_defaults(func=cmd_crawl)
    v = sub.add_parser("verdict"); v.add_argument("--candidates", default="-")
    v.set_defaults(func=cmd_verdict)
    args = p.parse_args(argv)
    args.func(args)

if __name__ == "__main__":
    main()
