#!/usr/bin/env bats
# cb-reap must fetch before its commit arithmetic. A stale origin ref makes pushed
# work read as unpushed, so the session never reaps and the resume note records a
# wrong count (2026-07-31).

@test "cb-reap fetches before computing ahead/unpushed" {
  run grep -n "fetch origin" scripts/cerebro/cb-reap
  [ "$status" -eq 0 ]
  fetch_line="$(grep -n 'git -C "$wt" fetch origin' scripts/cerebro/cb-reap | head -1 | cut -d: -f1)"
  ahead_line="$(grep -n 'ahead=\$(git -C "\$wt" rev-list --count origin/main..HEAD' scripts/cerebro/cb-reap | head -1 | cut -d: -f1)"
  [ -n "$fetch_line" ]
  [ -n "$ahead_line" ]
  [ "$fetch_line" -lt "$ahead_line" ]
}

@test "a failed fetch is non-fatal but stamps the resume note UNVERIFIED" {
  grep -q '_fresh=no' scripts/cerebro/cb-reap
  grep -q 'counts UNVERIFIED' scripts/cerebro/cb-reap
}

@test "cb-pr-check uses ls-remote (a live query), not a local ref" {
  grep -q 'ls-remote --heads origin' scripts/cerebro/cb-pr-check
}

@test "no cerebro script compares against origin/ without a fetch in the same file" {
  fails=""
  for f in scripts/cerebro/cb-*; do
    [ -f "$f" ] || continue
    grep -q 'rev-list --count.*origin/' "$f" || continue
    grep -q 'fetch origin' "$f" || fails="$fails $f"
  done
  [ -z "$fails" ] || { echo "missing fetch in:$fails"; false; }
}
