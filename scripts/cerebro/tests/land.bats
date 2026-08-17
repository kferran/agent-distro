setup() { export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME"; load ../lib/land.sh; }

# --- cb_local_date: Kyle's LOCAL date, never the UTC server clock ---

@test "cb_local_date is the America/Denver calendar date" {
  run cb_local_date
  [ "$status" -eq 0 ]
  [ "$output" = "$(TZ=America/Denver date +%F)" ]
}

@test "cb_local_date shape is YYYY-MM-DD" {
  run cb_local_date
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

# --- cb_deliverable_path: the computed landing destination ---

@test "cb_deliverable_path composes 00 Inbox/<LOCAL>-<KIND>-<SLUG>.md" {
  run cb_deliverable_path research probe-x
  [ "$status" -eq 0 ]
  [ "$output" = "00 Inbox/$(TZ=America/Denver date +%F)-research-probe-x.md" ]
}

@test "cb_deliverable_path is repo-relative, not absolute (it is written into meta and commits)" {
  run cb_deliverable_path ops sweep-x
  [[ "$output" == 00\ Inbox/* ]]
  [[ "$output" != /* ]]
}

@test "cb_deliverable_path takes an explicit LOCAL override" {
  run cb_deliverable_path ops sweep-x 2026-01-02
  [ "$status" -eq 0 ]
  [ "$output" = "00 Inbox/2026-01-02-ops-sweep-x.md" ]
}

@test "cb_deliverable_path carries the kind through (code/research/ops are distinct paths)" {
  run cb_deliverable_path code fix-x 2026-01-02
  [ "$output" = "00 Inbox/2026-01-02-code-fix-x.md" ]
  run cb_deliverable_path research fix-x 2026-01-02
  [ "$output" = "00 Inbox/2026-01-02-research-fix-x.md" ]
}

# An empty component would compose `00 Inbox/2026-01-02--x.md` — a malformed
# path is exactly the silent failure the computed path exists to remove.
@test "cb_deliverable_path refuses an empty KIND (exit 2, message on stderr)" {
  run cb_deliverable_path "" probe-x
  [ "$status" -eq 2 ]
  [[ "$output" == *"KIND"* ]]
}

@test "cb_deliverable_path refuses an empty SLUG (exit 2, message on stderr)" {
  run cb_deliverable_path research ""
  [ "$status" -eq 2 ]
  [[ "$output" == *"SLUG"* ]]
}

@test "cb_deliverable_path refuses with no arguments at all" {
  run cb_deliverable_path
  [ "$status" -eq 2 ]
}

@test "a refusal prints nothing on stdout (no half-composed path reaches a caller)" {
  run bash -c "source scripts/cerebro/lib/land.sh; cb_deliverable_path '' probe-x 2>/dev/null"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

# land.sh is SOURCED by cb-brief/cb-start — a `set -e` in it would leak into
# every caller and into bats `load`.
@test "land.sh sets no shell options on its sourcer" {
  run bash -c "set +e; source scripts/cerebro/lib/land.sh; case \$- in *e*) echo LEAKED;; *) echo clean;; esac"
  [ "$output" = "clean" ]
}
