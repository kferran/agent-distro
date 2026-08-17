#!/usr/bin/env bats
# cb-ask (P1) — the declared-gate verb. An X-Man declares the exact decision it
# is waiting on: question + options + durable content key into the R12 decisions
# log, plus a `paused:` beacon line (NOT `blocked:` — cb-watch remediates blocked
# and would inject "continue" into a worker that is waiting for an answer).

setup() {
  load ../lib/classify.sh
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"
  mkdir -p "$CB_HOME/tasks/probe-x"
  printf 'running: gathering sources\n' > "$CB_HOME/tasks/probe-x/status"
}
LOG() { printf '%s/tasks/probe-x/decisions' "$CB_HOME"; }
BEACON() { printf '%s/tasks/probe-x/status' "$CB_HOME"; }

@test "declares a decision carrying the exact question text" {
  run scripts/cerebro/cb-ask probe-x "which carrier do we integrate first?"
  [ "$status" -eq 0 ]
  grep -q ' declared ' "$(LOG)"
  grep -q 'which carrier do we integrate first?' "$(LOG)"
  run open_decisions "$CB_HOME/tasks/probe-x"
  [[ "$output" == *"which carrier do we integrate first?"* ]]
  [[ "$output" == *"needs-input"* ]]
}

@test "--options are appended to the gate in bracket form" {
  run scripts/cerebro/cb-ask probe-x "which carrier first?" --options "PRU|LFG|NW"
  [ "$status" -eq 0 ]
  grep -q 'which carrier first? \[PRU|LFG|NW\]' "$(LOG)"
}

@test "appends a paused: beacon line, never blocked:" {
  run scripts/cerebro/cb-ask probe-x "which carrier first?"
  [ "$status" -eq 0 ]
  [ "$(tail -1 "$(BEACON)" | cut -d: -f1)" = "paused" ]
  ! grep -q '^blocked:' "$(BEACON)"
  grep -q 'awaiting answer' "$(BEACON)"
}

@test "appends cleanly onto the bare no-newline launch beacon cb-start writes" {
  printf 'running' > "$(BEACON)"                      # exactly what cb-start:228 writes
  run scripts/cerebro/cb-ask probe-x "which carrier first?"
  [ "$status" -eq 0 ]
  run _beacon_state "$(BEACON)"
  [ "$output" = "paused" ]                            # NOT "runningpaused"
}

@test "classify reads the asking task as paused (not blocked → never remediated)" {
  run scripts/cerebro/cb-ask probe-x "which carrier first?"
  CB_WINDOW_LIST_CMD="printf 'probe-x\n'" run classify_research "$CB_HOME/tasks/probe-x"
  [ "$output" = "paused" ]
}

@test "re-asking the same question is a no-op (one declared line, one beacon line)" {
  scripts/cerebro/cb-ask probe-x "which carrier first?"
  local before; before="$(wc -l < "$(BEACON)")"
  run scripts/cerebro/cb-ask probe-x "which carrier first?"
  [ "$status" -eq 0 ]
  [ "$(grep -c ' declared ' "$(LOG)")" -eq 1 ]
  [ "$(wc -l < "$(BEACON)")" -eq "$before" ]
}

@test "a genuinely different question declares a second key" {
  scripts/cerebro/cb-ask probe-x "which carrier first?"
  run scripts/cerebro/cb-ask probe-x "ship behind a flag?"
  [ "$status" -eq 0 ]
  [ "$(grep -c ' declared ' "$(LOG)")" -eq 2 ]
}

@test "newlines and tabs in the question are flattened (the log stays line- and tab-parseable)" {
  run scripts/cerebro/cb-ask probe-x "$(printf 'line one\nline\ttwo')"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$(LOG)")" -eq 1 ]
  ! grep -q "$(printf '\t')" "$(LOG)"
  grep -q 'line one line two' "$(LOG)"
}

@test "the flattened gate survives the tab-delimited fold intact" {
  run scripts/cerebro/cb-ask probe-x "$(printf 'a\tb')" --options "x|y"
  IFS=$'\t' read -r k st gate < <(open_decisions "$CB_HOME/tasks/probe-x")
  [ "$st" = "needs-input" ]
  [ "$gate" = "a b [x|y]" ]
}

@test "an unknown slug refuses (exit 1) and writes nothing" {
  run scripts/cerebro/cb-ask no-such-task "anything?"
  [ "$status" -eq 1 ]
  [ ! -e "$CB_HOME/tasks/no-such-task" ]
}

@test "a blank question is a usage error (exit 2)" {
  run scripts/cerebro/cb-ask probe-x ""
  [ "$status" -eq 2 ]
  [ ! -f "$(LOG)" ]
}

@test "a slug with shell metacharacters is refused (exit 2)" {
  run scripts/cerebro/cb-ask 'probe;rm -rf /' "anything?"
  [ "$status" -eq 2 ]
}

@test "an unknown flag is a usage error (exit 2)" {
  run scripts/cerebro/cb-ask probe-x "q?" --bogus x
  [ "$status" -eq 2 ]
  [ ! -f "$(LOG)" ]
}

# --- --supersedes: retire the question this one replaces (2026-08-03) --------
# Sharpening a question after reading more used to leave BOTH on the board — the
# newer one saying "SUPERSEDES 1493386392" in prose nothing could read — so Kyle
# was handed the same decision three times in one evening (eja-3881, 2026-08-02).

@test "--supersedes closes the predecessor and leaves only the new question" {
  run scripts/cerebro/cb-ask probe-x "first framing of the question"
  [ "$status" -eq 0 ]
  old=$(_decision_key needs-input "first framing of the question")
  run scripts/cerebro/cb-ask probe-x "sharper framing after reading jira-context" --supersedes "$old"
  [ "$status" -eq 0 ]
  grep -q " supersedes " "$(LOG)"
  ! grep -q " resolved " "$(LOG)"                       # closed by supersession, not by hand
  run open_decisions "$CB_HOME/tasks/probe-x"
  [[ "$output" == *"sharper framing"* ]]
  [[ "$output" != *"first framing"* ]]
}

# cb-ask exits early when the question is unchanged. The supersession must still
# be recorded on that path, or a retry silently drops it.
@test "--supersedes still records on the already-open retry path" {
  run scripts/cerebro/cb-ask probe-x "the old one"
  old=$(_decision_key needs-input "the old one")
  run scripts/cerebro/cb-ask probe-x "the new one"      # declared, no supersession yet
  run scripts/cerebro/cb-ask probe-x "the new one" --supersedes "$old"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]                          # the question itself was unchanged
  grep -q " supersedes " "$(LOG)"
  run _is_open "$CB_HOME/tasks/probe-x" "$old"; [ "$status" -ne 0 ]
}

# WARN, never refuse: a bad key must not cost us the question itself, or Kyle
# ends up with neither decision.
@test "--supersedes with an unknown key warns but the ask still lands" {
  run scripts/cerebro/cb-ask probe-x "a real question" --supersedes 999999999
  [ "$status" -eq 0 ]
  [[ "$output" == *"not an open decision"* ]]
  run open_decisions "$CB_HOME/tasks/probe-x"
  [[ "$output" == *"a real question"* ]]
}

@test "--supersedes with a non-numeric key is rejected, ask still lands" {
  run scripts/cerebro/cb-ask probe-x "another real question" --supersedes "not-a-key"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a decision key"* ]]
  run open_decisions "$CB_HOME/tasks/probe-x"; [[ "$output" == *"another real question"* ]]
}

@test "--supersedes naming the question's own key is ignored, not self-closing" {
  k=$(_decision_key needs-input "self referential [a|b]")
  run scripts/cerebro/cb-ask probe-x "self referential" --options "a|b" --supersedes "$k"
  [ "$status" -eq 0 ]
  [[ "$output" == *"same decision"* ]]
  run _is_open "$CB_HOME/tasks/probe-x" "$k"; [ "$status" -eq 0 ]
}

@test "--supersedes requires an argument" {
  run scripts/cerebro/cb-ask probe-x "q" --supersedes
  [ "$status" -eq 2 ]
}

# --- flag-in-the-question-slot guard (regression, 2026-08-05) ----------------
# prsync-c carried an open decision whose ENTIRE question text was `--clear`,
# and it rode along in three consecutive supervisor batches before anyone asked
# why. A decision with no question in it can never be answered, so it escalates
# to Kyle forever and only a hand-written `resolved` line clears it.

@test "cb-ask REFUSES a question that is only a flag-shaped token" {
  run scripts/cerebro/cb-ask probe-x "--clear"
  [ "$status" -eq 2 ]
  [[ "$output" == *"is a flag, not a question"* ]]
  [ ! -f "$(LOG)" ]
}

@test "cb-ask still accepts a real question that merely starts with a flag" {
  run scripts/cerebro/cb-ask probe-x "--force was passed, should we keep it?" --options "yes|no"
  [ "$status" -eq 0 ]
  [ -f "$(LOG)" ]
}
