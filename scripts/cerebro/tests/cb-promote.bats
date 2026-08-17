#!/usr/bin/env bats
# cb-promote (T36): research report with promote_to: code → a DRAFTING dev
# item seed. Routing stays Kyle's — the script never sets queued.

setup() {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks/probe-p"
  export CB_VAULT="$BATS_TEST_TMPDIR/vault"
  ITEMS="$CB_VAULT/00 Inbox"; mkdir -p "$ITEMS"
  cat > "$CB_HOME/tasks/probe-p/report.md" <<'EOF'
---
status: complete
confidence: high
from_commit: abc123
promote_to: code
---
# Report — probe-p

## Answer

The gate misfires because the filter is null; a one-file fix in the
validation collection closes it.

## Evidence

Long evidence body that must NOT be pasted into the seed.

## Recommended next action

Wire IsExternalReplacementAndLifePolicy as the per-policy filter.
EOF
}

@test "promote_to: code report → drafting dev item with source pointer + seed" {
  run scripts/cerebro/cb-promote probe-p
  [ "$status" -eq 0 ]
  [ -f "$ITEMS/probe-p-code.md" ]
  grep -q '^status: drafting' "$ITEMS/probe-p-code.md"
  grep -q 'tasks/probe-p/report.md' "$ITEMS/probe-p-code.md"
  grep -q 'filter is null' "$ITEMS/probe-p-code.md"          # Answer seeded
  grep -q 'IsExternalReplacementAndLifePolicy' "$ITEMS/probe-p-code.md"  # rec next action seeded
  ! grep -q 'Long evidence body' "$ITEMS/probe-p-code.md"    # linked, not pasted
  [[ "$output" == *"probe-p-code.md"* ]]                     # prints the path
}

@test "--slug overrides the derived item slug" {
  run scripts/cerebro/cb-promote probe-p --slug fix-null-filter
  [ "$status" -eq 0 ]
  [ -f "$ITEMS/fix-null-filter.md" ]
  grep -q '^slug: fix-null-filter' "$ITEMS/fix-null-filter.md"
}

@test "never sets queued — drafting only" {
  run scripts/cerebro/cb-promote probe-p
  ! grep -q 'status: queued' "$ITEMS/probe-p-code.md"
}

@test "non-promote report refuses" {
  sed -i 's/^promote_to: code/promote_to: none/' "$CB_HOME/tasks/probe-p/report.md"
  run scripts/cerebro/cb-promote probe-p
  [ "$status" -ne 0 ]
  [[ "$output" == *"promote_to"* ]]
  [ ! -f "$ITEMS/probe-p-code.md" ]
}

@test "missing report refuses" {
  run scripts/cerebro/cb-promote ghost
  [ "$status" -ne 0 ]
}

@test "existing dev item refuses (never overwrite)" {
  printf 'precious' > "$ITEMS/probe-p-code.md"
  run scripts/cerebro/cb-promote probe-p
  [ "$status" -ne 0 ]
  [ "$(cat "$ITEMS/probe-p-code.md")" = "precious" ]
}
