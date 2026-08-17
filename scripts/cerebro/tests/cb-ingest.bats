#!/usr/bin/env bats
# cb-ingest — applies ADDITIVE, self-declared vault landings from finished reports.
# Every refusal path matters at least as much as the apply paths: this script is
# allowed to write the vault, so the tests pin what it must REFUSE to touch.

setup() {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks" "$CB_HOME/logs"
  export VAULT_DIR="$BATS_TEST_TMPDIR/vault"
  mkdir -p "$VAULT_DIR/00 Inbox" "$VAULT_DIR/03 Resources" "$VAULT_DIR/People" "$VAULT_DIR/.claude"
  git -C "$VAULT_DIR" init -q 2>/dev/null || true
  git -C "$VAULT_DIR" config user.email t@t; git -C "$VAULT_DIR" config user.name t
  printf 'seed\n' > "$VAULT_DIR/seed.md"
  git -C "$VAULT_DIR" add -A >/dev/null; git -C "$VAULT_DIR" commit -qm seed >/dev/null
  export QUEUE="$CB_HOME/logs/ingest-queue"
}

# mk_report <slug> <block-body...>  (block body is the inside of the fence)
mk_report() {
  local slug="$1"; shift
  mkdir -p "$CB_HOME/tasks/$slug"
  { printf -- '---\nstatus: complete\n---\n\n# Report\n\n'
    printf '```cb-ingest\n'; printf '%s\n' "$@"; printf '```\n'; } > "$CB_HOME/tasks/$slug/report.md"
  printf '%s %s report=%s deliverable=none\n' "$(date -Is)" "$slug" \
    "$CB_HOME/tasks/$slug/report.md" >> "$QUEUE"
}

@test "no queue → clean no-op" {
  run scripts/cerebro/cb-ingest --drain
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to do"* ]]
}

@test "new-file: creates the target and commits locally" {
  mk_report newdoc "target: 00 Inbox/2026-07-30-finding.md" "mode: new-file" "---" "# Finding" "" "Body text."
  run scripts/cerebro/cb-ingest --drain
  [ "$status" -eq 0 ]
  [ -f "$VAULT_DIR/00 Inbox/2026-07-30-finding.md" ]
  grep -q "Body text." "$VAULT_DIR/00 Inbox/2026-07-30-finding.md"
  git -C "$VAULT_DIR" log -1 --format=%s | grep -q "cb-ingest: applied 1"
}

@test "it commits LOCALLY and never pushes (no remote configured is not an error)" {
  mk_report nopush "target: 00 Inbox/x.md" "mode: new-file" "---" "content"
  run scripts/cerebro/cb-ingest --drain
  [ "$status" -eq 0 ]
  [ "$(git -C "$VAULT_DIR" log --oneline | wc -l)" -eq 2 ]   # seed + one ingest commit
}

@test "append: adds to the end of an existing file" {
  printf '# Doc\n\nexisting\n' > "$VAULT_DIR/03 Resources/doc.md"
  mk_report app "target: 03 Resources/doc.md" "mode: append" "---" "## New Section" "" "added"
  run scripts/cerebro/cb-ingest --drain
  grep -q "existing" "$VAULT_DIR/03 Resources/doc.md"
  grep -q "## New Section" "$VAULT_DIR/03 Resources/doc.md"
}

@test "insert-before: places content above a unique anchor" {
  printf '# Glossary\n\n### Alpha\n\n### Zulu\n' > "$VAULT_DIR/03 Resources/g.md"
  mk_report ins "target: 03 Resources/g.md" "mode: insert-before" "anchor: ### Zulu" "---" "### Mike" "" "def"
  run scripts/cerebro/cb-ingest --drain
  # Mike must appear before Zulu
  local m z
  m=$(grep -n '### Mike' "$VAULT_DIR/03 Resources/g.md" | cut -d: -f1)
  z=$(grep -n '### Zulu' "$VAULT_DIR/03 Resources/g.md" | cut -d: -f1)
  [ "$m" -lt "$z" ]
}

@test "REFUSE: insert-before when the anchor is ambiguous" {
  printf '### Dup\n\n### Dup\n' > "$VAULT_DIR/03 Resources/d.md"
  mk_report amb "target: 03 Resources/d.md" "mode: insert-before" "anchor: ### Dup" "---" "### New"
  run scripts/cerebro/cb-ingest --drain
  [[ "$output" == *"0 applied, 1 refused"* ]]
  ! grep -q "### New" "$VAULT_DIR/03 Resources/d.md"
  grep -q "matched 2x" "$VAULT_DIR/00 Inbox/$(TZ=America/Denver date +%F)-vault-maintenance-ratify.md"
}

@test "REFUSE: a non-additive mode" {
  printf 'x\n' > "$VAULT_DIR/03 Resources/r.md"
  mk_report repl "target: 03 Resources/r.md" "mode: replace" "---" "clobber"
  run scripts/cerebro/cb-ingest --drain
  [[ "$output" == *"1 refused"* ]]
  [ "$(cat "$VAULT_DIR/03 Resources/r.md")" = "x" ]
}

@test "REFUSE: identity and policy files are never touched" {
  for t in CLAUDE.md profile.md personality.md hot.md board.md; do
    printf 'ORIGINAL\n' > "$VAULT_DIR/$t"
  done
  mk_report id1 "target: CLAUDE.md" "mode: append" "---" "malicious"
  mk_report id2 "target: hot.md" "mode: append" "---" "malicious"
  run scripts/cerebro/cb-ingest --drain
  [[ "$output" == *"0 applied, 2 refused"* ]]
  [ "$(cat "$VAULT_DIR/CLAUDE.md")" = "ORIGINAL" ]
  [ "$(cat "$VAULT_DIR/hot.md")" = "ORIGINAL" ]
}

@test "REFUSE: People/ and Confidential/ and .claude/ are never touched" {
  printf 'ORIGINAL\n' > "$VAULT_DIR/People/someone.md"
  mk_report ppl "target: People/someone.md" "mode: append" "---" "performance note"
  mk_report conf "target: Confidential/secret.md" "mode: new-file" "---" "secret"
  mk_report cl "target: .claude/settings.json" "mode: new-file" "---" "{}"
  run scripts/cerebro/cb-ingest --drain
  [[ "$output" == *"0 applied, 3 refused"* ]]
  [ "$(cat "$VAULT_DIR/People/someone.md")" = "ORIGINAL" ]
  [ ! -e "$VAULT_DIR/Confidential/secret.md" ]
}

@test "REFUSE: path traversal and absolute paths" {
  mk_report trav "target: ../../etc/evil.md" "mode: new-file" "---" "no"
  mk_report abs "target: /tmp/evil.md" "mode: new-file" "---" "no"
  run scripts/cerebro/cb-ingest --drain
  [[ "$output" == *"0 applied, 2 refused"* ]]
  [ ! -e /tmp/evil.md ]
}

@test "REFUSE: a report with NO cb-ingest block — destination is judgment" {
  mkdir -p "$CB_HOME/tasks/prose"
  printf -- '---\nstatus: complete\n---\n\n## Proposed vault landing\n\nAppend this somewhere sensible.\n' \
    > "$CB_HOME/tasks/prose/report.md"
  printf '%s prose report=%s deliverable=none\n' "$(date -Is)" "$CB_HOME/tasks/prose/report.md" >> "$QUEUE"
  run scripts/cerebro/cb-ingest --drain
  [[ "$output" == *"1 refused"* ]]
  grep -q "left for /ingest" "$VAULT_DIR/00 Inbox/$(TZ=America/Denver date +%F)-vault-maintenance-ratify.md"
}

@test "REFUSE: new-file whose target already exists" {
  printf 'ORIGINAL\n' > "$VAULT_DIR/03 Resources/exists.md"
  mk_report dup "target: 03 Resources/exists.md" "mode: new-file" "---" "clobber"
  run scripts/cerebro/cb-ingest --drain
  [[ "$output" == *"1 refused"* ]]
  [ "$(cat "$VAULT_DIR/03 Resources/exists.md")" = "ORIGINAL" ]
}

@test "idempotent: re-running does not duplicate content" {
  printf '# Doc\n\n### Zulu\n' > "$VAULT_DIR/03 Resources/i.md"
  mk_report idem "target: 03 Resources/i.md" "mode: insert-before" "anchor: ### Zulu" "---" "### Mike"
  run scripts/cerebro/cb-ingest --drain
  [ "$(grep -c '### Mike' "$VAULT_DIR/03 Resources/i.md")" -eq 1 ]
  # re-queue the same finding and drain again
  printf '%s idem report=%s deliverable=none\n' "$(date -Is)" "$CB_HOME/tasks/idem/report.md" >> "$QUEUE"
  run scripts/cerebro/cb-ingest --drain
  [ "$(grep -c '### Mike' "$VAULT_DIR/03 Resources/i.md")" -eq 1 ]
}

@test "the queue line is marked [ingested-DATE] and not re-processed" {
  mk_report mark "target: 00 Inbox/m.md" "mode: new-file" "---" "c"
  run scripts/cerebro/cb-ingest --drain
  grep -q "\[ingested-$(TZ=America/Denver date +%F)\]" "$QUEUE"
  run scripts/cerebro/cb-ingest --drain
  [[ "$output" == *"0 applied, 0 refused"* ]]
}

@test "multiple blocks in one report are applied independently" {
  printf '### Zulu\n' > "$VAULT_DIR/03 Resources/multi.md"
  mkdir -p "$CB_HOME/tasks/many"
  { printf -- '---\nstatus: complete\n---\n\n'
    printf '```cb-ingest\ntarget: 00 Inbox/one.md\nmode: new-file\n---\nfirst\n```\n'
    printf '```cb-ingest\ntarget: 03 Resources/multi.md\nmode: insert-before\nanchor: ### Zulu\n---\n### Alpha\n```\n'
  } > "$CB_HOME/tasks/many/report.md"
  printf '%s many report=%s deliverable=none\n' "$(date -Is)" "$CB_HOME/tasks/many/report.md" >> "$QUEUE"
  run scripts/cerebro/cb-ingest --drain
  [[ "$output" == *"2 applied"* ]]
  [ -f "$VAULT_DIR/00 Inbox/one.md" ]
  grep -q "### Alpha" "$VAULT_DIR/03 Resources/multi.md"
}

@test "one bad block does not block a good one in the same report" {
  mkdir -p "$CB_HOME/tasks/mixed"
  { printf -- '---\nstatus: complete\n---\n\n'
    printf '```cb-ingest\ntarget: CLAUDE.md\nmode: append\n---\nno\n```\n'
    printf '```cb-ingest\ntarget: 00 Inbox/good.md\nmode: new-file\n---\nyes\n```\n'
  } > "$CB_HOME/tasks/mixed/report.md"
  printf '%s mixed report=%s deliverable=none\n' "$(date -Is)" "$CB_HOME/tasks/mixed/report.md" >> "$QUEUE"
  run scripts/cerebro/cb-ingest --drain
  [[ "$output" == *"1 applied, 1 refused"* ]]
  [ -f "$VAULT_DIR/00 Inbox/good.md" ]
}

@test "--dry-run applies nothing, commits nothing, marks nothing" {
  mk_report dryrun "target: 00 Inbox/dry.md" "mode: new-file" "---" "c"
  run scripts/cerebro/cb-ingest --dry-run
  [[ "$output" == *"WOULD apply"* ]]
  [ ! -e "$VAULT_DIR/00 Inbox/dry.md" ]
  [ "$(git -C "$VAULT_DIR" log --oneline | wc -l)" -eq 1 ]   # seed only
  ! grep -q "ingested-" "$QUEUE"
}

@test "a missing report file is refused, not crashed on" {
  printf '%s ghost report=%s/tasks/ghost/report.md deliverable=none\n' "$(date -Is)" "$CB_HOME" >> "$QUEUE"
  run scripts/cerebro/cb-ingest --drain
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 refused"* ]]
}
