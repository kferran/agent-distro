#!/usr/bin/env python3
"""Ultron capability coverage crawl — citation extractor + file ledger.

Produces canonical TSV/JSON under 00 Inbox/2026-08-02-coverage/_data/.
All arithmetic lives here; subagents do judgment only.
"""
import json, os, re, subprocess, sys
from collections import defaultdict

REPO = "/home/kyle/code/worktrees/main"
CAPS = "/home/kyle/vault/03 Resources/ultron/capabilities"
OUT = "/home/kyle/vault/00 Inbox/2026-08-02-coverage/_data"
os.makedirs(OUT, exist_ok=True)

BREADTH = 150  # citation matching >= this many files is too broad to constitute coverage

# ---------------------------------------------------------------- file universe
files = subprocess.run(["git", "ls-files"], cwd=REPO, capture_output=True, text=True).stdout.split("\n")
files = [f for f in files if f]

def exclusion(p):
    if p.startswith(".ai/"):
        return "ai-workflow-artifacts (.ai/knowledge + .ai/specs — Cerebro conductor's own store, not Ultron system code)"
    if p == "infrastructure/porch-ident":
        return "git submodule gitlink (separate repo: porchsoftware/porch-ident)"
    if p.startswith(".") and "/" not in p:
        return "repo-root dotfile (tooling config)"
    if p.startswith((".idea/", ".vscode/", ".github/", ".githooks/", ".bitbucket/")):
        return "editor/CI tooling config"
    return None

universe = {}
for f in files:
    universe[f] = exclusion(f)

in_scope = [f for f, x in universe.items() if x is None]
excluded = {f: x for f, x in universe.items() if x is not None}

# directory -> set of in-scope files beneath it
dir_files = defaultdict(set)
for f in in_scope:
    parts = f.split("/")
    for i in range(1, len(parts)):
        dir_files["/".join(parts[:i])].add(f)

fileset = set(in_scope)
all_tracked = set(files)

# suffix index for rootless fragments: map every path suffix -> full paths
suffix_idx = defaultdict(set)
for f in in_scope:
    parts = f.split("/")
    for i in range(len(parts)):
        suffix_idx["/".join(parts[i:])].add(f)
# directory suffixes too
dir_suffix_idx = defaultdict(set)
for d in dir_files:
    parts = d.split("/")
    for i in range(len(parts)):
        dir_suffix_idx["/".join(parts[i:])].add(d)

# ---------------------------------------------------------------- citation extraction
# backtick-quoted tokens, plus [[..]] excluded (vault links)
TOK = re.compile(r"`([^`\n]+)`")
EXT = r"(?:cs|ts|tsx|vue|js|mjs|cjs|json|ya?ml|csproj|sln|props|targets|md|txt|sql|sh|ps1|xml|xsd|html|css|scss|Dockerfile|tf|tfvars|env|toml|ini|cfg|snap|http|razor|cshtml)"
LINEANCHOR = re.compile(r":[0-9][0-9,\-\s]*$")

def looks_like_path(t):
    t = t.strip()
    if not t or len(t) > 200:
        return False
    if any(c in t for c in " \t()[]{}<>|*?\"'$;=") and not t.startswith(("backend/", "frontend/", "infrastructure/", "third-party/", "docs/", "deployables/")):
        return False
    if "*" in t or "{" in t or "..." in t:
        return False
    if t.startswith(("http://", "https://", "@")):
        return False
    return True

ROOTS = ("backend/", "frontend/", "infrastructure/", "third-party/", "docs/", "lexicon/")

def normalize(t):
    t = t.strip().strip(",.;")
    m = LINEANCHOR.search(t)
    line = None
    if m:
        line = m.group(0)[1:]
        t = t[: m.start()]
    t = t.rstrip("/")
    t = t.lstrip("./")
    return t, line

def classify_token(t):
    """Return kind: 'path' if plausibly a repo path reference, else None."""
    if not looks_like_path(t):
        return None
    base, line = normalize(t)
    if not base:
        return None
    # rooted
    if base.startswith(ROOTS) or base in ("backend", "frontend", "infrastructure", "third-party", "docs", "lexicon"):
        return base, line, "rooted"
    # rootless: needs a file extension or a slash to be a path reference
    if re.search(r"\." + EXT + r"$", base):
        return base, line, "rootless"
    if "/" in base and not base.startswith(("~", "-")):
        return base, line, "rootless"
    return None

BARE_ROOTS = {"backend", "frontend", "frontend/src", "infrastructure", "third-party", "docs", "lexicon", "src"}

citations = []  # dicts
for fn in sorted(os.listdir(CAPS)):
    if not fn.startswith("capability-") or not fn.endswith(".md"):
        continue
    path = os.path.join(CAPS, fn)
    for lineno, text in enumerate(open(path, encoding="utf-8"), 1):
        for tok in TOK.findall(text):
            c = classify_token(tok)
            if not c:
                continue
            base, anchor, kind = c
            citations.append({
                "doc": fn, "docline": lineno, "raw": tok, "path": base,
                "anchor": anchor, "kind": kind, "context": text.strip()[:400],
            })

# ---------------------------------------------------------------- resolution
def resolve(c):
    p = c["path"]
    if p in BARE_ROOTS:
        return "bare-root", [], 0
    # exact file
    if p in fileset:
        return "file", [p], 1
    if p in all_tracked:  # excluded-scope file (e.g. .ai/)
        return "file-excluded-scope", [p], 1
    # exact directory
    if p in dir_files:
        return "dir", sorted(dir_files[p]), len(dir_files[p])
    if c["kind"] == "rooted":
        return "dead", [], 0
    # rootless -> suffix match
    fm = suffix_idx.get(p, set())
    if len(fm) == 1:
        return "file", sorted(fm), 1
    if len(fm) > 1:
        return "ambiguous-file", sorted(fm), len(fm)
    dm = dir_suffix_idx.get(p, set())
    if len(dm) == 1:
        d = next(iter(dm))
        return "dir", sorted(dir_files[d]), len(dir_files[d])
    if len(dm) > 1:
        return "ambiguous-dir", sorted(dm), sum(len(dir_files[d]) for d in dm)
    return "unresolvable", [], 0

for c in citations:
    kind, matches, n = resolve(c)
    c["res"] = kind
    c["nfiles"] = n
    c["matches"] = matches if len(matches) <= 5 else matches[:5]
    c["resolved_dir"] = None
    if kind == "dir":
        # find the dir key
        if c["path"] in dir_files:
            c["resolved_dir"] = c["path"]
        else:
            dm = dir_suffix_idx.get(c["path"], set())
            c["resolved_dir"] = next(iter(dm)) if len(dm) == 1 else None
    c["broad"] = kind == "dir" and n >= BREADTH

# ---------------------------------------------------------------- coverage
covered_exact = set()
covered_by_dir = {}   # file -> (dir, doc)
for c in citations:
    if c["res"] == "file":
        for m in c["matches"]:
            covered_exact.add(m)
    elif c["res"] == "dir" and not c["broad"] and c["resolved_dir"]:
        for f in dir_files[c["resolved_dir"]]:
            covered_by_dir.setdefault(f, (c["resolved_dir"], c["doc"], c["docline"]))

buckets = {}
for f in in_scope:
    if f in covered_exact:
        buckets[f] = ("covered-file", "")
    elif f in covered_by_dir:
        d, doc, dl = covered_by_dir[f]
        buckets[f] = ("covered-dir", f"{d} <- {doc}:{dl}")
    else:
        buckets[f] = ("uncovered", "")

# ---------------------------------------------------------------- write outputs
with open(f"{OUT}/citations.tsv", "w") as fh:
    fh.write("doc\tdocline\traw\tpath\tkind\tres\tnfiles\tbroad\tresolved\n")
    for c in citations:
        fh.write("\t".join([c["doc"], str(c["docline"]), c["raw"], c["path"], c["kind"],
                            c["res"], str(c["nfiles"]), "BROAD" if c["broad"] else "",
                            c["resolved_dir"] or (c["matches"][0] if c["matches"] else "")]) + "\n")

with open(f"{OUT}/file-buckets.tsv", "w") as fh:
    fh.write("path\tbucket\tvia\n")
    for f in sorted(in_scope):
        b, via = buckets[f]
        fh.write(f"{f}\t{b}\t{via}\n")
    for f in sorted(excluded):
        fh.write(f"{f}\texcluded\t{excluded[f]}\n")

# leaf dirs (directories directly containing >=1 in-scope file)
leaf = defaultdict(list)
for f in in_scope:
    leaf[os.path.dirname(f) or "."].append(f)

leafrows = []
for d, fl in sorted(leaf.items()):
    nb = sum(1 for f in fl if buckets[f][0].startswith("covered"))
    leafrows.append((d, len(fl), nb, len(fl) - nb))
with open(f"{OUT}/leaf-dirs.tsv", "w") as fh:
    fh.write("dir\tfiles\tcovered\tuncovered\n")
    for r in leafrows:
        fh.write("\t".join(map(str, r)) + "\n")

summary = {
    "tracked_total": len(files),
    "excluded": len(excluded),
    "in_scope": len(in_scope),
    "covered_file": sum(1 for f in in_scope if buckets[f][0] == "covered-file"),
    "covered_dir": sum(1 for f in in_scope if buckets[f][0] == "covered-dir"),
    "uncovered": sum(1 for f in in_scope if buckets[f][0] == "uncovered"),
    "citations_total": len(citations),
    "by_res": dict(sorted(((k, sum(1 for c in citations if c["res"] == k)) for k in set(c["res"] for c in citations)), key=lambda x: -x[1])),
    "broad_citations": sorted(set((c["resolved_dir"], c["nfiles"]) for c in citations if c["broad"]), key=lambda x: -x[1]),
    "leaf_dirs": len(leaf),
    "leaf_dirs_fully_uncovered": sum(1 for d, n, cv, un in leafrows if cv == 0),
}
summary["reconcile_ok"] = (summary["covered_file"] + summary["covered_dir"] + summary["uncovered"] == summary["in_scope"]
                           and summary["in_scope"] + summary["excluded"] == summary["tracked_total"])
json.dump(summary, open(f"{OUT}/summary.json", "w"), indent=2)
print(json.dumps(summary, indent=2))

# ---------------------------------------------------------------- structural test (rule fix #3b)
# A broad citation is DEBT only if the citing doc contains no citation resolving
# strictly BENEATH it. If it does, the broad path is a table/section header
# introducing an anchored enumeration — an index reference, not a blanket.
by_doc = defaultdict(list)
for c in citations:
    by_doc[c["doc"]].append(c)

debt, index_ref = [], []
for c in citations:
    if not c["broad"]:
        continue
    root = c["resolved_dir"]
    kids = 0
    for o in by_doc[c["doc"]]:
        if o is c or o["broad"]:
            continue
        tgt = o["resolved_dir"] or (o["matches"][0] if o["matches"] else None)
        if tgt and tgt != root and tgt.startswith(root + "/"):
            kids += 1
    (index_ref if kids >= 3 else debt).append((root, c["nfiles"], c["doc"], c["docline"], kids))

print("\n=== BROAD CITATIONS — structural test (>=3 anchored children in the same doc => index ref) ===")
print(f"DEBT sites: {len(debt)}   INDEX-REF sites: {len(index_ref)}")
print("\n-- DEBT (blankets a tree with nothing anchored beneath it) --")
for r in sorted(set(debt), key=lambda x: -x[1]):
    print(f"  {r[1]:>5}  {r[0]}   <- {r[2]}:{r[3]}  (children anchored: {r[4]})")
print("\n-- INDEX REF (header over an anchored enumeration — not debt) --")
for r in sorted(set(index_ref), key=lambda x: -x[1]):
    print(f"  {r[1]:>5}  {r[0]}   <- {r[2]}:{r[3]}  (children anchored: {r[4]})")
