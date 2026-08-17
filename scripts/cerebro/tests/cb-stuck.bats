#!/usr/bin/env bats
# R3 — the stuck-agent evidence printer. The ladder itself is a documented
# procedure in the board skill (deciding an agent is confused is not
# mechanically verifiable — Cerebro-spec §8.3's admission rule). cb-stuck only
# gathers what the rungs need. Read-only is the whole contract, so it is tested.

setup() {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks"
  export CB_SESSION_LIST_CMD="printf ''"
  export CB_PEEK_CMD="printf 'pane line one\npane line two\n'"
}

mk_task() {  # mk_task <slug> [kind] [target]
  local d="$CB_HOME/tasks/$1"; mkdir -p "$d"
  printf 'kind=%s\nworktree=/tmp/wt-%s\njira=EJA-1\nsession=%s\ntarget=%s\n' \
    "${2:-code}" "$1" "$1" "${3:-ultron}" > "$d/meta"
}
live() { export CB_SESSION_LIST_CMD="printf '$1\n'"; }

@test "refuses without a slug" {
  run scripts/cerebro/cb-stuck
  [ "$status" -eq 2 ]
  [[ "$output" == *usage* ]]
}

@test "refuses a slug with shell metacharacters" {
  run scripts/cerebro/cb-stuck 'x;touch /tmp/cb-stuck-pwn'
  [ "$status" -eq 2 ]
  [ ! -e /tmp/cb-stuck-pwn ]
}

@test "refuses an unknown task rather than inventing one" {
  run scripts/cerebro/cb-stuck nosuch
  [ "$status" -eq 1 ]
  [[ "$output" == *"no Cerebro task"* ]]
}

@test "prints the evidence a live task's ladder needs" {
  mk_task wedged; live wedged
  run scripts/cerebro/cb-stuck wedged
  [ "$status" -eq 0 ]
  [[ "$output" == *"session   wedged (alive)"* ]]
  [[ "$output" == *"worktree  /tmp/wt-wedged"* ]]
  [[ "$output" == *"state     "* ]]
  [[ "$output" == *"pane line one"* ]]      # rung 1 is answered inline
  [[ "$output" == *"last write"* ]]
}

@test "prints the ladder, in order, with both cautions" {
  mk_task wedged; live wedged
  run scripts/cerebro/cb-stuck wedged
  [[ "$output" == *"1. Peek the pane"* ]]
  [[ "$output" == *"2. Waiting on a question"* ]]
  [[ "$output" == *"3. Confused or looping"* ]]
  [[ "$output" == *"4. Genuinely wedged"* ]]
  [[ "$output" == *"5. Second relaunch fails"* ]]
  [[ "$output" == *"low context reading is not wedging"* ]]
  [[ "$output" == *"pkill-and-restart the watcher"* ]]
}

@test "the rung-4 command is the full cb-resume for THIS slug and target" {
  mk_task wedged code ultron; live wedged
  run scripts/cerebro/cb-stuck wedged
  [[ "$output" == *"cb-resume wedged --target ultron"* ]]
  [[ "$output" != *"cb-start --code --adopt"* ]]
}

@test "a dead session says so instead of pretending to peek" {
  mk_task gone                       # not in CB_SESSION_LIST_CMD
  run scripts/cerebro/cb-stuck gone
  [ "$status" -eq 0 ]
  [[ "$output" == *"session   gone (gone)"* ]]   # cb_session_alive's own vocabulary
  [[ "$output" == *"nothing to peek"* ]]
  [[ "$output" != *"pane line one"* ]]
}

@test "an unreadable pane degrades instead of failing" {
  mk_task wedged; live wedged
  export CB_PEEK_CMD="false"      # NOT `exit 1` — eval'd, that would exit cb-stuck itself
  run scripts/cerebro/cb-stuck wedged
  [ "$status" -eq 0 ]
  [[ "$output" == *"not readable"* ]]
}

@test "READ-ONLY: it mutates nothing under CB_HOME" {
  mk_task wedged; live wedged
  before="$(find "$CB_HOME" -type f -printf '%p %T@ %s\n' | sort)"
  run scripts/cerebro/cb-stuck wedged
  [ "$status" -eq 0 ]
  after="$(find "$CB_HOME" -type f -printf '%p %T@ %s\n' | sort)"
  [ "$before" = "$after" ]
}

@test "READ-ONLY: it never sends keys, kills or relaunches" {
  mk_task wedged; live wedged
  # any real tmux/git invocation would land here
  export CB_TMUX_BIN="$BATS_TEST_TMPDIR/trip"
  printf '#!/usr/bin/env bash\ntouch %q\nexit 0\n' "$BATS_TEST_TMPDIR/tmux-was-called" > "$CB_TMUX_BIN"
  chmod +x "$CB_TMUX_BIN"
  unset CB_PEEK_CMD                       # force the real capture-pane path
  run scripts/cerebro/cb-stuck wedged
  [ "$status" -eq 0 ]
  # capture-pane is allowed (it is a read); a send-keys/kill-session is not
  ! grep -qE 'send-keys|kill-session|kill-window' "$BATS_TEST_TMPDIR/trip"
  [[ "$output" != *"send-keys"* ]] || [[ "$output" == *"cb-send"* ]]
}

@test "the board skill carries the ladder — the gate, not the helper" {
  grep -q "escalation ladder" .claude/skills/board/SKILL.md
  grep -q "low context reading is not wedging" .claude/skills/board/SKILL.md
  grep -q "pkill-and-restart the watcher" .claude/skills/board/SKILL.md
  grep -q "not automated" .claude/skills/board/SKILL.md
  grep -q "cb-stuck" .claude/skills/board/SKILL.md
}
