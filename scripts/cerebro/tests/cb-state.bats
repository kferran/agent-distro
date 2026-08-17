#!/usr/bin/env bats
# cb-state — the verified state reader. The property under test is that it CANNOT
# report a state it did not just fetch (2026-07-31: three wrong "unpushed" claims in
# one session, all from pre-fetch rev-list counts).

setup() {
  TMP="$(mktemp -d)"
  export CB_MAIN_WORKTREE="$TMP/main"
  export CB_WORKTREE_ROOT="$TMP/worktrees"
  mkdir -p "$CB_WORKTREE_ROOT"

  # an "origin" bare repo + a main clone
  git init -q --bare "$TMP/origin.git"
  git clone -q "$TMP/origin.git" "$CB_MAIN_WORKTREE"
  cd "$CB_MAIN_WORKTREE"
  git config user.email t@t; git config user.name t
  echo one > f; git add f; git commit -qm one; git push -q origin HEAD:main
  git branch -q -m main 2>/dev/null || true
}

teardown() { rm -rf "$TMP"; }

@test "refuses to report when the fetch fails, rather than using a stale ref" {
  git -C "$CB_MAIN_WORKTREE" remote set-url origin /nonexistent/path.git
  run "$BATS_TEST_DIRNAME/../cb-state"
  [ "$status" -eq 3 ]
  [[ "$output" == *"refusing to report state from a stale ref"* ]]
}

@test "reports unpushed=0 for a branch whose commits are on the remote" {
  cd "$CB_MAIN_WORKTREE"
  git checkout -qb feat; echo two >> f; git commit -qam two; git push -q origin feat
  git checkout -q main
  git worktree add -q "$CB_WORKTREE_ROOT/feat" feat
  run "$BATS_TEST_DIRNAME/../cb-state"
  [ "$status" -eq 0 ]
  echo "$output" | grep -E '^feat[[:space:]]+0[[:space:]]' || { echo "$output"; false; }
}

@test "the regression: a commit pushed by someone else still reads unpushed=0" {
  # This is the exact 2026-07-31 miss — the local ref for origin/feat is stale
  # because the push happened outside this checkout. A pre-fetch count says
  # "unpushed", cb-state must say 0 because it fetches first.
  cd "$CB_MAIN_WORKTREE"
  git checkout -qb feat; echo two >> f; git commit -qam two; git push -q origin feat
  git checkout -q main
  git worktree add -q "$CB_WORKTREE_ROOT/feat" feat

  # advance the branch from a SEPARATE clone, so this checkout's origin/feat is stale
  git clone -q "$TMP/origin.git" "$TMP/other"
  cd "$TMP/other"; git config user.email t@t; git config user.name t
  git checkout -q feat; echo three >> f; git commit -qam three; git push -q origin feat
  # mirror that commit into the worktree WITHOUT fetching, as a local commit
  cd "$CB_WORKTREE_ROOT/feat"; echo three > f; git commit -qam three --allow-empty

  # stale read (what the old code did) claims unpushed
  stale="$(git -C "$CB_WORKTREE_ROOT/feat" rev-list --count origin/feat..HEAD)"
  [ "$stale" -gt 0 ]

  # cb-state fetches first, so origin/feat is current
  run "$BATS_TEST_DIRNAME/../cb-state"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fetched "* ]]
}

@test "--json carries fetched_at so a consumer can see the read is fresh" {
  run "$BATS_TEST_DIRNAME/../cb-state" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"fetched_at"'* ]]
  [[ "$output" == *'"origin_main"'* ]]
}
