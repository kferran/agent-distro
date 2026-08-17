#!/usr/bin/env bats
# unlanded.sh — the landedness decision and the surfacing register.
#
# The rule under test: landedness is decided by CONTENT and DECLARATION, never by
# slug-mention + mtime. Every case below is drawn from a defect reproduced against
# the live corpus on 2026-07-31 (see 00 Inbox/2026-07-31-unlanded-report-sweep.md).

setup() {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"
  export VAULT_DIR="$BATS_TEST_TMPDIR/vault"
  mkdir -p "$CB_HOME/tasks" "$CB_HOME/logs" "$VAULT_DIR/00 Inbox"
  source "$BATS_TEST_DIRNAME/../lib/unlanded.sh"
}

# mktask SLUG STATUS DELIVERABLE [CLEARANCE] — a task dir with a terminal report.
mktask() {
  local slug="$1" st="$2" dl="$3" cl="${4:-}"
  local td="$CB_HOME/tasks/$slug"; mkdir -p "$td"
  { printf -- '---\nstatus: %s\nfinished: 2026-07-31T12:00:00-06:00\n' "$st"
    [ -n "$dl" ] && printf 'deliverable: %s\n' "$dl"
    printf -- '---\n\n# %s\n\nbody\n' "$slug"
  } > "$td/report.md"
  { [ -n "$cl" ] && printf -- '---\nclearance: %s\n---\n\n' "$cl"
    printf '# Objective\n\nwork\n'
  } > "$td/brief.md"
  printf '%s\n' "$td"
}

# --- frontmatter parsing ----------------------------------------------------

@test "ul_report_field reads status and deliverable from the frontmatter block" {
  td="$(mktask alpha complete '00 Inbox/a.md')"
  [ "$(ul_report_field "$td/report.md" status)" = "complete" ]
  [ "$(ul_report_field "$td/report.md" deliverable)" = "00 Inbox/a.md" ]
}

@test "ul_report_field ignores a same-named line in the body, not just the frontmatter" {
  td="$(mktask alpha complete '00 Inbox/a.md')"
  printf 'deliverable: 00 Inbox/DECOY.md\n' >> "$td/report.md"
  [ "$(ul_report_field "$td/report.md" deliverable)" = "00 Inbox/a.md" ]
}

@test "ul_clearance returns the value when present and empty when absent" {
  td="$(mktask alpha complete '00 Inbox/a.md' standard)"
  [ "$(ul_clearance "$td/brief.md")" = "standard" ]
  td2="$(mktask beta complete '00 Inbox/b.md')"
  [ -z "$(ul_clearance "$td2/brief.md")" ]
}

# --- path normalisation (defect 3's sibling: the declared path has 4 shapes) --

@test "ul_paths strips an absolute vault prefix from a declared deliverable" {
  run ul_paths "/home/kyle/vault/00 Inbox/x.md" "/home/kyle/vault"
  [ "$output" = "00 Inbox/x.md" ]
}

@test "ul_paths splits a comma-separated multi-file deliverable into one path per line" {
  run ul_paths "00 Inbox/a.md, 00 Inbox/b.md" "$VAULT_DIR"
  [ "${lines[0]}" = "00 Inbox/a.md" ]
  [ "${lines[1]}" = "00 Inbox/b.md" ]
}

@test "ul_paths marks a prose deliverable as unparseable rather than guessing a path" {
  run ul_paths "01 Projects/x/plans/  (three files — a.md, b.md)" "$VAULT_DIR"
  [ "$output" = "!prose" ]
}

@test "ul_paths treats an explicit none as no declaration" {
  run ul_paths "none" "$VAULT_DIR"
  [ -z "$output" ]
}

# --- path + human locator (regression, 2026-08-05) --------------------------
# The env-error-monitor declares `<real path> (trend line, <timestamp>)` on every
# run. A blanket `(` -> !prose rule read that as "no declared destination", so the
# register was set to cry wolf hourly on a task class that writes its own vault
# output. Existence is the gate — a locator on a path that is NOT on disk still
# reads as prose, so this resolves a real declaration without guessing at one.

@test "ul_paths resolves a real path carrying a trailing human locator" {
  mkdir -p "$VAULT_DIR/02 Areas/Engineering-Work"
  echo "- trend line" > "$VAULT_DIR/02 Areas/Engineering-Work/env-error-monitor-log.md"
  run ul_paths "02 Areas/Engineering-Work/env-error-monitor-log.md (trend line, 2026-08-05 18:10 MT)" "$VAULT_DIR"
  [ "$output" = "02 Areas/Engineering-Work/env-error-monitor-log.md" ]
}

@test "ul_paths still refuses to guess when the locator's path does not exist" {
  run ul_paths "00 Inbox/never-written.md (trend line, 2026-08-05 18:10 MT)" "$VAULT_DIR"
  [ "$output" = "!prose" ]
}

@test "ul_paths does not resolve a multi-file declaration that also carries a locator" {
  run ul_paths "a.md, b.md (two of them)" "$VAULT_DIR"
  [ "$output" = "!prose" ]
}

# --- the landedness rule ----------------------------------------------------

@test "a declared deliverable that exists is landed — with NO mtime comparison" {
  td="$(mktask alpha complete '00 Inbox/a.md' standard)"
  printf 'landed content\n' > "$VAULT_DIR/00 Inbox/a.md"
  # DEFECT 3: the deliverable is written BEFORE report.md, so it is always older.
  touch -d '2020-01-01' "$VAULT_DIR/00 Inbox/a.md"
  run ul_classify "$td" "$VAULT_DIR"
  [ "${output%%$'\t'*}" = "landed" ]
}

@test "a declared deliverable that is missing is unlanded, and says which path" {
  td="$(mktask alpha complete '00 Inbox/gone.md' standard)"
  run ul_classify "$td" "$VAULT_DIR"
  [ "${output%%$'\t'*}" = "not-represented" ]
  [[ "$output" == *"00 Inbox/gone.md"* ]]
}

# --- the `landed` marker outranks the declaration (2026-08-16) ----------------
# cb-land records where it ACTUALLY filed; `deliverable:` is only what the agent
# declared. Measured: three tasks surfaced 27x each over 56h as "declared
# deliverable absent" while their reports sat on disk exactly where cb-land put
# them. The whole register exists to make an unlanded report impossible to
# ignore, so a false positive costs more here than a miss.

@test "the landed marker outranks a declaration that points somewhere else" {
  td="$(mktask alpha complete '00 Inbox/the-agent-invented-this.md' standard)"
  printf '04 Archive/2026-Q3/landed-reports/real.md\n' > "$td/landed"
  mkdir -p "$VAULT_DIR/04 Archive/2026-Q3/landed-reports"
  printf 'x\n' > "$VAULT_DIR/04 Archive/2026-Q3/landed-reports/real.md"
  run ul_classify "$td" "$VAULT_DIR"
  [ "${output%%$'\t'*}" = "landed" ]
  [[ "$output" == *"cb-land filed it"* ]]
}

@test "an ABSOLUTE path in the landed marker resolves — it is not vault-relative" {
  td="$(mktask alpha complete '' standard)"
  printf '%s\n' "$VAULT_DIR/00 Inbox/abs.md" > "$td/landed"
  printf 'x\n' > "$VAULT_DIR/00 Inbox/abs.md"
  run ul_classify "$td" "$VAULT_DIR"
  [ "${output%%$'\t'*}" = "landed" ]
}

@test "a landed marker whose target is GONE is unlanded, and says so distinctly" {
  td="$(mktask alpha complete '00 Inbox/whatever.md' standard)"
  printf '00 Inbox/was-here.md\n' > "$td/landed"
  run ul_classify "$td" "$VAULT_DIR"
  [ "${output%%$'\t'*}" = "not-represented" ]
  # deleted-after-landing is a DIFFERENT failure from never-landed; the message
  # has to distinguish them or the fix trades one wrong reason for another.
  [[ "$output" == *"GONE"* ]]
  [[ "$output" == *"00 Inbox/was-here.md"* ]]
}

@test "an empty landed marker falls through to the declaration, not to landed" {
  td="$(mktask alpha complete '00 Inbox/declared.md' standard)"
  : > "$td/landed"
  printf 'x\n' > "$VAULT_DIR/00 Inbox/declared.md"
  run ul_classify "$td" "$VAULT_DIR"
  [ "${output%%$'\t'*}" = "landed" ]
  [[ "$output" == *"declared deliverable present"* ]]
}

@test "a multi-file deliverable is landed only when EVERY declared path exists" {
  td="$(mktask alpha complete '00 Inbox/a.md, 00 Inbox/b.md' standard)"
  printf 'x\n' > "$VAULT_DIR/00 Inbox/a.md"
  run ul_classify "$td" "$VAULT_DIR"
  [ "${output%%$'\t'*}" = "not-represented" ]
  printf 'x\n' > "$VAULT_DIR/00 Inbox/b.md"
  run ul_classify "$td" "$VAULT_DIR"
  [ "${output%%$'\t'*}" = "landed" ]
}

# INVERTED 2026-08-14. This asserted the opposite — an absent clearance was
# blocked-ingest even with the deliverable present — and that was right while
# /ingest, which fails closed on the same field, was the only path into the
# vault. cb-land is that path now: `clearance:` is script-written, an absent one
# is a scaffold bug rather than a sensitivity signal, and the lander reads it as
# `standard` and files the report. Left as it was, the register would report
# `blocked-ingest` for reports demonstrably sitting in the vault.
@test "an absent clearance falls through to the content test — it no longer blocks" {
  td="$(mktask charter complete '00 Inbox/a.md')"
  printf 'x\n' > "$VAULT_DIR/00 Inbox/a.md"
  run ul_classify "$td" "$VAULT_DIR"
  [ "${output%%$'\t'*}" = "landed" ]
  [[ "$output" != *blocked-ingest* ]]
}

@test "an absent clearance does not certify either — a missing deliverable is still unlanded" {
  # The half that keeps the relaxation honest: falling through means the CONTENT
  # test decides, not that everything without a clearance reads landed.
  td="$(mktask charter complete '00 Inbox/gone.md')"
  run ul_classify "$td" "$VAULT_DIR"
  [ "${output%%$'\t'*}" = "not-represented" ]
  [[ "$output" == *"00 Inbox/gone.md"* ]]
}

@test "a confidential clearance is blocked-ingest, never proposed for landing" {
  td="$(mktask secret complete '00 Inbox/a.md' confidential)"
  printf 'x\n' > "$VAULT_DIR/00 Inbox/a.md"
  run ul_classify "$td" "$VAULT_DIR"
  [ "${output%%$'\t'*}" = "blocked-ingest" ]
}

@test "an unrecognised clearance still blocks — only EMPTY was relaxed" {
  td="$(mktask oddcl complete '00 Inbox/a.md' internal-only)"
  printf 'x\n' > "$VAULT_DIR/00 Inbox/a.md"
  run ul_classify "$td" "$VAULT_DIR"
  [ "${output%%$'\t'*}" = "blocked-ingest" ]
  [[ "$output" == *"unrecognised"* ]]
}

@test "no declared destination is unknown — the sweep never guesses one" {
  td="$(mktask alpha complete '' standard)"
  run ul_classify "$td" "$VAULT_DIR"
  [ "${output%%$'\t'*}" = "unknown" ]
}

@test "a non-terminal report is not a candidate at all" {
  td="$(mktask alpha running '00 Inbox/gone.md' standard)"
  run ul_classify "$td" "$VAULT_DIR"
  [ "${output%%$'\t'*}" = "skip" ]
}

# --- defect 1: a slug mention must never certify ------------------------------

@test "DEFECT 1: a process log naming the slug does not make it landed" {
  td="$(mktask charter-review complete '00 Inbox/gone.md' standard)"
  # every process-log surface found on 2026-07-31, each newer than report.md
  for f in board.md "00 Inbox/2026-07-31-vault-maintenance-ratify.md" \
           "00 Inbox/2026-07-31-reaped-sessions.md" "Daily/2026-07-31.md"; do
    mkdir -p "$VAULT_DIR/$(dirname "$f")"
    printf 'charter-review is blocked and cannot be ingested\n' > "$VAULT_DIR/$f"
  done
  run ul_classify "$td" "$VAULT_DIR"
  [ "${output%%$'\t'*}" = "not-represented" ]
}

@test "DEFECT 2: a deliverable outside the old narrow root list is still landed" {
  td="$(mktask metrics complete '02 Areas/Org-Performance/metrics/m.md' standard)"
  mkdir -p "$VAULT_DIR/02 Areas/Org-Performance/metrics"
  printf 'x\n' > "$VAULT_DIR/02 Areas/Org-Performance/metrics/m.md"
  run ul_classify "$td" "$VAULT_DIR"
  [ "${output%%$'\t'*}" = "landed" ]
}

# --- cb-ingest block: reuse cb-ingest's own content test ----------------------

@test "a declared cb-ingest block whose content is in the target reads as landed" {
  td="$(mktask blk complete '' standard)"
  printf 'x\n' > "$VAULT_DIR/00 Inbox/t.md"
  printf '## Findings\nbody\n' >> "$VAULT_DIR/00 Inbox/t.md"
  cat >> "$td/report.md" <<'EOF'

```cb-ingest
target: 00 Inbox/t.md
mode: append
---
## Findings

body
```
EOF
  run ul_classify "$td" "$VAULT_DIR"
  [ "${output%%$'\t'*}" = "landed" ]
}

@test "a declared cb-ingest block not yet applied reads as unlanded" {
  td="$(mktask blk complete '' standard)"
  printf 'unrelated\n' > "$VAULT_DIR/00 Inbox/t.md"
  cat >> "$td/report.md" <<'EOF'

```cb-ingest
target: 00 Inbox/t.md
mode: append
---
## Findings

body
```
EOF
  run ul_classify "$td" "$VAULT_DIR"
  [ "${output%%$'\t'*}" = "not-represented" ]
}

# --- the register: age quiets, it never removes ------------------------------

@test "ul_register_note records first_seen and increments surfaces on re-surface" {
  reg="$CB_HOME/logs/unlanded-register"
  ul_register_note "$reg" alpha not-represented 1000
  ul_register_note "$reg" alpha not-represented 2000
  run grep -c '^alpha' "$reg"
  [ "$output" = "1" ]
  line="$(grep '^alpha' "$reg")"
  [[ "$line" == *"first=1000"* ]]
  [[ "$line" == *"last=2000"* ]]
  [[ "$line" == *"surfaces=2"* ]]
}

@test "DEFECT 4: an aged item stays on the register — age never removes it" {
  reg="$CB_HOME/logs/unlanded-register"
  # e2e-product-findings-tickets: surfaced at 46h and 47h, then vanished at 48h.
  ul_register_note "$reg" e2e not-represented 1000
  run ul_register_aged "$reg" 172800 1000000   # window 48h, now far past it
  [[ "$output" == *e2e* ]]
}

@test "a register entry is cleared only when it lands, never by time" {
  reg="$CB_HOME/logs/unlanded-register"
  ul_register_note "$reg" alpha not-represented 1000
  ul_register_clear "$reg" alpha
  run grep -c '^alpha' "$reg"
  [ "$status" -ne 0 ]
}

@test "ul_register_clear leaves other slugs intact" {
  reg="$CB_HOME/logs/unlanded-register"
  ul_register_note "$reg" alpha not-represented 1000
  ul_register_note "$reg" beta unknown 1000
  ul_register_clear "$reg" alpha
  run grep -c '^beta' "$reg"
  [ "$output" = "1" ]
}

@test "a new entry first seen OUTSIDE the window is backlog, not a disappearance" {
  reg="$CB_HOME/logs/unlanded-register"
  ul_register_note "$reg" old not-represented 1000 0
  [ "$(ul_register_origin "$reg" old)" = "backlog" ]
}

@test "a new entry first seen INSIDE the window is watched" {
  reg="$CB_HOME/logs/unlanded-register"
  ul_register_note "$reg" fresh not-represented 1000 1
  [ "$(ul_register_origin "$reg" fresh)" = "watched" ]
}

@test "origin is set once — a backlog item never promotes itself by being re-seen" {
  reg="$CB_HOME/logs/unlanded-register"
  ul_register_note "$reg" old not-represented 1000 0
  ul_register_note "$reg" old not-represented 2000 1
  ul_register_note "$reg" old not-represented 3000 1
  [ "$(ul_register_origin "$reg" old)" = "backlog" ]
}

@test "a watched item that ages out keeps origin=watched — the e2e disappearance case" {
  reg="$CB_HOME/logs/unlanded-register"
  ul_register_note "$reg" e2e not-represented 1000 1     # seen in window
  ul_register_note "$reg" e2e not-represented 999000 0   # now well past it
  [ "$(ul_register_origin "$reg" e2e)" = "watched" ]
  [[ "$(grep '^e2e' "$reg")" == *"first=1000"* ]]
}

@test "a kind=code task is skipped — its deliverable is a PR, not a vault landing" {
  td="$(mktask conductor complete '' )"
  printf 'kind=code\n' > "$td/meta"
  rm -f "$td/brief.md"          # code task dirs routinely carry no brief
  run ul_classify "$td" "$VAULT_DIR"
  [ "${output%%$'\t'*}" = "skip" ]
  [[ "$output" == *"PR"* ]]
  # and it must NOT be reported with a clearance reason, which would be false
  [[ "$output" != *clearance* ]]
}

# INVERTED 2026-08-14, same change as the absent-clearance case above. This
# asserted `blocked-ingest` with a "no brief.md" reason. A missing brief and a
# brief missing the field produce the same empty clearance, and empty no longer
# blocks — so the distinction has no outcome left to carry, and keeping the
# stricter rule here would block precisely what cb-land files. The coverage
# stays: a missing brief must not be treated as a sensitivity declaration.
@test "a missing brief.md does not block either — no brief is not a clearance" {
  td="$(mktask nobrief complete '00 Inbox/a.md')"
  rm -f "$td/brief.md"
  printf 'x\n' > "$VAULT_DIR/00 Inbox/a.md"
  run ul_classify "$td" "$VAULT_DIR"
  [ "${output%%$'\t'*}" = "landed" ]
  [[ "$output" != *clearance* ]]
}

@test "ul_paths strips YAML quotes from a declared deliverable" {
  mkdir -p "$VAULT_DIR/02 Areas/Engineering-Work"
  : > "$VAULT_DIR/02 Areas/Engineering-Work/env-error-monitor-log.md"
  run ul_paths '"02 Areas/Engineering-Work/env-error-monitor-log.md"' "$VAULT_DIR"
  [ "$output" = "02 Areas/Engineering-Work/env-error-monitor-log.md" ]
}

@test "ul_paths strips single quotes too, and re-trims inside them" {
  run ul_paths "' 00 Inbox/x.md '" "$VAULT_DIR"
  [ "$output" = "00 Inbox/x.md" ]
}
