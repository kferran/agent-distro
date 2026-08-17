import os, datetime
import deploy_tracker_web as dt

FIX = os.path.join(os.path.dirname(__file__), "fixtures")

def _read(name):
    with open(os.path.join(FIX, name), encoding="utf-8") as f:
        return f.read()

def test_parse_promotions_returns_ulid_options_only():
    proms = dt.parse_promotions(_read("stage_page.html"))
    assert len(proms) >= 1
    assert all(any(len(p) == 26 for p in v.split(".")) for v in proms)
    assert "core-edj" not in proms

def test_extract_keys_finds_eja_and_asd():
    keys = dt.extract_keys(_read("promo_page.html"))
    assert any(k.startswith("EJA-") for k in keys)
    assert all(k.split("-")[0] in ("EJA", "ASD") for k in keys)

def test_ulid_timestamp_decodes_known_value():
    ts = dt.ulid_timestamp("edj-uat.np.annuity.porch.software.01kve5dwhfnb1kgw07jg8fg28n.14d8477")
    assert isinstance(ts, datetime.datetime)
    assert 2025 < ts.year < 2028

def test_ulid_timestamp_none_when_no_ulid():
    assert dt.ulid_timestamp("no-ulid-here") is None

def test_crawl_stage_assembles_keys_and_window():
    stage_html = _read("stage_page.html")
    promo_html = _read("promo_page.html")
    def fake_fetch(url):
        return promo_html if "promotion=" in url else stage_html
    out = dt.crawl_stage("core-edj", "edj-uat.np.annuity.porch.software", fake_fetch)
    assert out["promotions"] >= 1
    assert len(out["keys"]) >= 1
    assert out["window"]["oldest"] <= out["window"]["newest"]

WINDOWS = {dt.UAT_ZONE: {"oldest": "2026-05-06T00:09:00", "newest": "2026-06-18T20:05:00"}}

def _verdict(cands, union):
    return dt.compute_verdict(cands, union, WINDOWS)

def test_in_uat_via_byproxy_sibling():
    cands = {"ASD-690": [{"key": "EJA-1869", "resolutiondate": "2026-06-04"},
                          {"key": "EJA-1870", "resolutiondate": "2026-06-04"}]}
    union = {"EJA-1870": [dt.UAT_ZONE]}
    r = _verdict(cands, union)["ASD-690"]
    assert r["headline"] == "in UAT"
    assert r["env_map"]["uat"] == "EJA-1870"
    assert r["carrying_key"] == "EJA-1870"

def test_promoted_not_uat_when_only_lower_env():
    cands = {"T": [{"key": "EJA-9001", "resolutiondate": "2026-06-10"}]}
    union = {"EJA-9001": ["core-edj:edj-playground.np.annuity.porch.software"]}
    r = _verdict(cands, union)["T"]
    assert r["headline"] == "promoted, not UAT"
    assert r["env_map"]["playground"] == "EJA-9001"
    assert r["env_map"]["uat"] is None

def test_genuine_gap_absent_and_in_window():
    cands = {"ASD-286": [{"key": "EJA-2532", "resolutiondate": "2026-05-15"}]}
    r = _verdict(cands, {})["ASD-286"]
    assert r["headline"] == "genuine gap"
    assert r["caveat"]

def test_pre_window_absent_and_old():
    cands = {"ASD-151": [{"key": "EJA-1975", "resolutiondate": "2026-04-14"}]}
    r = _verdict(cands, {})["ASD-151"]
    assert r["headline"] == "pre-window (cannot confirm)"

def test_too_new_absent_and_after_window():
    cands = {"X": [{"key": "EJA-3159", "resolutiondate": "2026-06-22"}]}
    r = _verdict(cands, {})["X"]
    assert r["headline"] == "too-new"

def test_carrying_key_is_furthest_progressed():
    # two different keys in different envs, none in UAT → carrying_key is the higher one
    cands = {"T": [{"key": "EJA-700", "resolutiondate": "2026-06-10"},
                   {"key": "EJA-701", "resolutiondate": "2026-06-10"}]}
    union = {"EJA-700": ["core-edj:edj.dev.annuity.porch.software"],
             "EJA-701": ["core-edj:edj-preprod.np.annuity.porch.software"]}
    r = dt.compute_verdict(cands, union, WINDOWS)["T"]
    assert r["headline"] == "promoted, not UAT"
    assert r["carrying_key"] == "EJA-701"  # preprod beats dev

_ULID_A = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
_ULID_B = "01BX5ZZKBKACTAV9WEVGEMMVRZ"

def test_crawl_stage_tolerates_some_empty_builds():
    stage_html = f'<option value="s.{_ULID_A}.aa"><option value="s.{_ULID_B}.bb">'
    def fake_fetch(url):
        if "promotion=" not in url:
            return stage_html
        return "EJA-42 here" if _ULID_A in url else "infra bump, no tickets"
    out = dt.crawl_stage("w", "s", fake_fetch)
    assert out["keys"] == ["EJA-42"]
    assert out["empty_promotions"] == 1
    assert out["promotions"] == 2

def test_crawl_stage_since_skips_old_promotions():
    # _ULID_A ("01A…") is older than _ULID_B ("01B…"). since = the newer ts → only the
    # newer promo is fetched; the older one is skipped (incremental crawl, the timeout fix).
    stage_html = f'<option value="s.{_ULID_A}.aa"><option value="s.{_ULID_B}.bb">'
    def fake_fetch(url):
        return stage_html if "promotion=" not in url else "EJA-99 here"
    since = max(dt.ulid_timestamp(f"s.{_ULID_A}.aa"), dt.ulid_timestamp(f"s.{_ULID_B}.bb"))
    out = dt.crawl_stage("w", "s", fake_fetch, since=since)
    assert out["skipped_old"] == 1
    assert out["fetched"] == 1
    assert out["promotions"] == 2
    assert out["keys"] == ["EJA-99"]

def test_crawl_stage_survives_a_failed_promotion_fetch():
    # one promo detail page raises → skipped + counted, the crawl still returns the rest.
    stage_html = f'<option value="s.{_ULID_A}.aa"><option value="s.{_ULID_B}.bb">'
    def fake_fetch(url):
        if "promotion=" not in url: return stage_html
        if _ULID_A in url: raise TimeoutError("boom")
        return "EJA-77 here"
    out = dt.crawl_stage("w", "s", fake_fetch)
    assert out["fetch_failures"] == 1
    assert out["keys"] == ["EJA-77"]

def test_crawl_is_broken_only_when_all_empty():
    assert dt.crawl_is_broken(50, 0) is True
    assert dt.crawl_is_broken(50, 300) is False
    assert dt.crawl_is_broken(0, 0) is False
