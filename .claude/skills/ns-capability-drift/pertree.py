#!/usr/bin/env python3
"""Slice the canonical ledger into per-tree uncovered rollups for the judgment subagents."""
import os, csv
from collections import defaultdict

DATA = "/home/kyle/vault/00 Inbox/2026-08-02-coverage/_data"
rows = list(csv.DictReader(open(f"{DATA}/file-buckets.tsv"), delimiter="\t"))

# roll up uncovered files to a "subsystem" granularity per tree.
# rule: depth-N prefix, N chosen per tree so rows are meaningful units.
DEPTH = {
    "backend": 4,        # backend/<area>/<project>/<subdir>
    "frontend": 4,       # frontend/src/<layer>/<slice>
    "third-party": 3,    # third-party/<pkg>/<src|test>
    "infrastructure": 4, # infrastructure/<stack>/<env>/<unit>
    "docs": 2,
}

trees = defaultdict(lambda: defaultdict(lambda: {"unc": [], "cov": 0}))
tree_tot = defaultdict(lambda: {"files": 0, "cov": 0, "unc": 0, "exc": 0})

for r in rows:
    p, b = r["path"], r["bucket"]
    t = p.split("/")[0] if "/" in p else "(root files)"
    if b == "excluded":
        tree_tot[t]["exc"] += 1
        continue
    tree_tot[t]["files"] += 1
    d = DEPTH.get(t, 2)
    key = "/".join(p.split("/")[:d]) if p.count("/") >= d else os.path.dirname(p) or p
    if b == "uncovered":
        tree_tot[t]["unc"] += 1
        trees[t][key]["unc"].append(p)
    else:
        tree_tot[t]["cov"] += 1
        trees[t][key]["cov"] += 1

os.makedirs(f"{DATA}/per-tree", exist_ok=True)
for t, groups in trees.items():
    safe = t.replace("/", "_").replace("(", "").replace(")", "").replace(" ", "-")
    with open(f"{DATA}/per-tree/{safe}.tsv", "w") as fh:
        fh.write(f"# tree={t} in_scope={tree_tot[t]['files']} covered={tree_tot[t]['cov']} uncovered={tree_tot[t]['unc']} excluded={tree_tot[t]['exc']}\n")
        fh.write("subsystem\tuncovered_files\tcovered_files\tsample_paths\n")
        for k in sorted(groups, key=lambda x: -len(groups[x]["unc"])):
            g = groups[k]
            if not g["unc"]:
                continue
            fh.write(f"{k}\t{len(g['unc'])}\t{g['cov']}\t{'; '.join(sorted(g['unc'])[:6])}\n")

print("tree\tin_scope\tcovered\tuncovered\texcluded")
for t in sorted(tree_tot, key=lambda x: -tree_tot[x]["files"]):
    v = tree_tot[t]
    print(f"{t}\t{v['files']}\t{v['cov']}\t{v['unc']}\t{v['exc']}")
