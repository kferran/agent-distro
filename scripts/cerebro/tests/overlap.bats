#!/usr/bin/env bats
# lib/overlap.sh — R5 dispatch serialization. Surface same-subsystem /
# file-overlap AT DISPATCH, so two conductors don't discover each other at PR
# time. Coarse by design: candidate side declared-only, can't-tell degrades to
# warn, different repo is always parallel.

setup() {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks" "$CB_HOME/logs"
  export CB_VAULT="$BATS_TEST_TMPDIR/vault"
  ITEMS="$CB_VAULT/00 Inbox"; mkdir -p "$ITEMS"
  export CB_SESSION_LIST_CMD="printf ''"
  source scripts/cerebro/lib/paths.sh
  source scripts/cerebro/lib/classify.sh
  source scripts/cerebro/lib/overlap.sh
}

mk_item() {  # mk_item <slug> <domain> [files-frontmatter-line]
  { printf -- '---\nslug: %s\nstatus: active\nrepo: ultron\ndomain: %s\n' "$1" "$2"
    [ -n "${3:-}" ] && printf '%s\n' "$3"
    printf -- '---\n\n# %s\n' "$1"; } > "$ITEMS/$1.md"
}

mk_task() {  # mk_task <slug> <target> <worktree> — a LIVE code task
  local d="$CB_HOME/tasks/$1"; mkdir -p "$d"
  printf 'kind=code\nworktree=%s\njira=\nsession=%s\ntarget=%s\n' "$3" "$1" "$2" > "$d/meta"
  export CB_SESSION_LIST_CMD="${CB_SESSION_LIST_CMD%\'}; printf '$1\n'"
}

# a real git worktree with real changed files — the in-flight side is evidence,
# not declaration, so the tests use actual git rather than a stub
mk_worktree() {  # mk_worktree <path> <file>...
  local wt="$1"; shift
  mkdir -p "$wt"; git -C "$wt" init -q -b main
  git -C "$wt" config user.email t@t; git -C "$wt" config user.name t
  echo seed > "$wt/seed"; git -C "$wt" add seed; git -C "$wt" commit -qm seed
  git -C "$wt" update-ref refs/remotes/origin/main HEAD
  local f
  for f in "$@"; do mkdir -p "$wt/$(dirname "$f")"; echo change > "$wt/$f"; done
  git -C "$wt" add -A; git -C "$wt" commit -qm work
}

live() { export CB_SESSION_LIST_CMD="printf '$1\n'"; }

@test "no in-flight tasks → clear, nothing surfaced" {
  mk_item cand forms
  run cb_overlap_check cand ultron forms main
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "declared file overlap with a live conductor → REFUSE, naming the files" {
  mk_worktree "$BATS_TEST_TMPDIR/wt-other" "src/forms/Stamp.cs" "src/other/X.cs"
  mk_item other forms
  mk_task other ultron "$BATS_TEST_TMPDIR/wt-other"
  mk_item cand forms "files: src/forms/Stamp.cs, src/forms/New.cs"
  live other
  run cb_overlap_check cand ultron forms main
  [ "$status" -eq 1 ]
  [[ "$output" == *"both touch"* ]]
  [[ "$output" == *"src/forms/Stamp.cs"* ]]
  [[ "$output" != *"src/other/X.cs"* ]]     # only the intersection is named
}

@test "same subsystem, no file overlap → WARN and proceed (the worked-example shape)" {
  mk_worktree "$BATS_TEST_TMPDIR/wt-other" "scripts/cerebro/cb-ingest"
  mk_item other cerebro
  mk_task other ultron "$BATS_TEST_TMPDIR/wt-other"
  mk_item cand cerebro "files: scripts/cerebro/cb-intake"
  live other
  run cb_overlap_check cand ultron cerebro main
  [ "$status" -eq 0 ]                        # a warn NEVER blocks
  [[ "$output" == *"same subsystem"* ]]
  [[ "$output" == *"domain: cerebro"* ]]
  [[ "$output" != *"both touch"* ]]
}

@test "a different repo is always parallel — no overlap note at all" {
  mk_worktree "$BATS_TEST_TMPDIR/wt-other" "src/forms/Stamp.cs"
  mk_item other forms
  mk_task other friday "$BATS_TEST_TMPDIR/wt-other"
  mk_item cand forms "files: src/forms/Stamp.cs"
  live other
  run cb_overlap_check cand ultron forms main
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "candidate declaring NO files can never be refused — only warned" {
  mk_worktree "$BATS_TEST_TMPDIR/wt-other" "src/forms/Stamp.cs"
  mk_item other forms
  mk_task other ultron "$BATS_TEST_TMPDIR/wt-other"
  mk_item cand forms                          # declares nothing
  live other
  run cb_overlap_check cand ultron forms main
  [ "$status" -eq 0 ]
  [[ "$output" == *"same subsystem"* ]]
}

@test "an unreadable worktree degrades to a warn, never a refusal" {
  mk_item other forms
  mk_task other ultron "$BATS_TEST_TMPDIR/gone"     # never created
  mk_item cand forms "files: src/forms/Stamp.cs"
  live other
  run cb_overlap_check cand ultron forms main
  [ "$status" -eq 0 ]
  [[ "$output" == *"unreadable"* ]]
  [[ "$output" == *"not blocking"* ]]
}

@test "a DEAD conductor's task serializes nothing" {
  mk_worktree "$BATS_TEST_TMPDIR/wt-other" "src/forms/Stamp.cs"
  mk_item other forms
  mk_task other ultron "$BATS_TEST_TMPDIR/wt-other"
  mk_item cand forms "files: src/forms/Stamp.cs"
  export CB_SESSION_LIST_CMD="printf ''"      # nothing alive
  run cb_overlap_check cand ultron forms main
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "uncommitted work in the other worktree still counts as owned" {
  mk_worktree "$BATS_TEST_TMPDIR/wt-other" "src/forms/Other.cs"
  echo dirty > "$BATS_TEST_TMPDIR/wt-other/src/forms/Dirty.cs"   # never committed
  mk_item other forms
  mk_task other ultron "$BATS_TEST_TMPDIR/wt-other"
  mk_item cand forms "files: src/forms/Dirty.cs"
  live other
  run cb_overlap_check cand ultron forms main
  [ "$status" -eq 1 ]
  [[ "$output" == *"src/forms/Dirty.cs"* ]]
}

@test "the task's own slug never collides with itself" {
  mk_worktree "$BATS_TEST_TMPDIR/wt-cand" "src/forms/Stamp.cs"
  mk_item cand forms "files: src/forms/Stamp.cs"
  mk_task cand ultron "$BATS_TEST_TMPDIR/wt-cand"
  live cand
  run cb_overlap_check cand ultron forms main
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "declared files parse from a YAML block list too" {
  { printf -- '---\nslug: cand\nstatus: queued\nrepo: ultron\ndomain: forms\nfiles:\n'
    printf -- '  - src/forms/Stamp.cs\n  - src/forms/Other.cs\n---\n'; } > "$ITEMS/cand.md"
  run cb_overlap_declared_files cand
  [ "$status" -eq 0 ]
  [[ "$output" == *"src/forms/Stamp.cs"* ]]
  [[ "$output" == *"src/forms/Other.cs"* ]]
}

# The dev-item template documents `files:` with an inline comment on that very
# line. Unstripped, every item created from the template and left unfilled would
# "declare" the help text as a path.
@test "an UNFILLED template line declares nothing" {
  mk_item cand forms "files:            # optional, code lane — paths this item is EXPECTED to touch"
  run cb_overlap_declared_files cand
  [ -z "$output" ]
}

@test "a trailing comment is stripped from a real declaration" {
  mk_item cand forms "files: src/forms/Stamp.cs   # from the RCA fix brief"
  run cb_overlap_declared_files cand
  [ "${lines[0]}" = "src/forms/Stamp.cs" ]
  [ "${#lines[@]}" -eq 1 ]
}

@test "an unfilled template item cannot be refused" {
  mk_worktree "$BATS_TEST_TMPDIR/wt-other" "src/forms/Stamp.cs"
  mk_item other forms
  mk_task other ultron "$BATS_TEST_TMPDIR/wt-other"
  mk_item cand forms "files:            # optional, code lane — paths this item is EXPECTED to touch"
  live other
  run cb_overlap_check cand ultron forms main
  [ "$status" -eq 0 ]
  [[ "$output" != *"both touch"* ]]
}

@test "comment lines inside a block list are skipped" {
  { printf -- '---\nslug: cand\nstatus: queued\nrepo: ultron\ndomain: forms\nfiles:\n'
    printf -- '  # from the RCA fix brief\n  - src/forms/Stamp.cs\n---\n'; } > "$ITEMS/cand.md"
  run cb_overlap_declared_files cand
  [ "${lines[0]}" = "src/forms/Stamp.cs" ]
  [ "${#lines[@]}" -eq 1 ]
}

@test "declared files parse from an inline comma list" {
  mk_item cand forms "files: a/b.cs, c/d.cs"
  run cb_overlap_declared_files cand
  [ "${lines[0]}" = "a/b.cs" ]
  [ "${lines[1]}" = "c/d.cs" ]
}

@test "a domain mismatch between live tasks stays silent" {
  mk_worktree "$BATS_TEST_TMPDIR/wt-other" "src/products/P.cs"
  mk_item other products
  mk_task other ultron "$BATS_TEST_TMPDIR/wt-other"
  mk_item cand forms "files: src/forms/Stamp.cs"
  live other
  run cb_overlap_check cand ultron forms main
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
