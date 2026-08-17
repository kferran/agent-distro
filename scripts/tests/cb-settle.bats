#!/usr/bin/env bats
# cb-settle — cross-task settlement. `open_decisions_live` used to consult only
# the ASKING task's own terminal evidence, so a question asked by task A and
# answered by shipping task B never closed. comms-lookback-distillation asked
# "build ns-comms-sweep standalone, fold, or hold?"; Kyle answered "standalone";
# the work shipped under build-ns-comms-sweep; the asking task had no terminal
# evidence of its own, so the digest kept asking until a human closed it by hand.

setup() {
  load ../lib/classify.sh
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"
  ASK="$CB_HOME/tasks/comms-lookback-distillation"
  BY="$CB_HOME/tasks/build-ns-comms-sweep"
  mkdir -p "$ASK" "$BY"
  Q="build ns-comms-sweep standalone, fold, or hold?"
  K="$(_decision_key needs-input "$Q")"
  _decision_declare "$ASK" "$K" needs-input "$Q"
}

@test "settles the named key — the question drops off the board once B ships" {
  run scripts/cerebro/cb-settle comms-lookback-distillation --by build-ns-comms-sweep --key "$K"
  [ "$status" -eq 0 ]
  [[ "$output" == *"closes when build-ns-comms-sweep ships"* ]]
  run open_decisions_live "$ASK"; [[ "$output" == *"standalone, fold, or hold"* ]]
  touch "$BY/done"                                    # B ships
  run open_decisions_live "$ASK"; [ -z "$output" ]
}

@test "--all settles every open decision on the asking task" {
  k2="$(_decision_key needs-input "a second question")"
  _decision_declare "$ASK" "$k2" needs-input "a second question"
  touch "$BY/done"
  run scripts/cerebro/cb-settle comms-lookback-distillation --by build-ns-comms-sweep --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 decision(s)"* ]]
  [[ "$output" == *"already shipped"* ]]
  run open_decisions_live "$ASK"; [ -z "$output" ]
}

# The :116 contract — cb-watch and cb-send must keep seeing every open key, or a
# later human answer writes no `resolved` and that answer leaves no audit record.
@test "a settled decision is still visible to the RAW fold" {
  touch "$BY/done"
  run scripts/cerebro/cb-settle comms-lookback-distillation --by build-ns-comms-sweep --key "$K"
  run open_decisions "$ASK"; [[ "$output" == *"$K"* ]]
  run _is_open "$ASK" "$K"; [ "$status" -eq 0 ]
}

# _task_terminal returns `soft` for a terminal report.md, and classify.sh:171 is
# explicit that a finished report is the NORMAL companion of an unanswered
# question — so it must not settle one.
@test "a settler that only wrote a report (soft) settles nothing" {
  printf -- '---\nstatus: complete\n---\n' > "$BY/report.md"
  run scripts/cerebro/cb-settle comms-lookback-distillation --by build-ns-comms-sweep --key "$K"
  [ "$status" -eq 0 ]
  [[ "$output" == *"closes when"* ]]                  # not "already shipped"
  run open_decisions_live "$ASK"; [[ "$output" == *"standalone, fold, or hold"* ]]
}

@test "a merged PR on the settler is hard evidence too" {
  printf 'MERGED\n' > "$BY/pr.state"
  run scripts/cerebro/cb-settle comms-lookback-distillation --by build-ns-comms-sweep --key "$K"
  [[ "$output" == *"already shipped"* ]]
  run open_decisions_live "$ASK"; [ -z "$output" ]
}

@test "a key that is not open refuses" {
  _decision_resolve "$ASK" "$K"
  run scripts/cerebro/cb-settle comms-lookback-distillation --by build-ns-comms-sweep --key "$K"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not open"* ]]
}

@test "--all on a task with no open decisions is a clean no-op" {
  _decision_resolve "$ASK" "$K"
  run scripts/cerebro/cb-settle comms-lookback-distillation --by build-ns-comms-sweep --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"no open decisions"* ]]
}

# A typo'd settler slug would sit there settling nothing forever, and would look
# exactly like a task that simply has not shipped yet.
@test "an unknown settling slug refuses rather than pointing at nothing" {
  run scripts/cerebro/cb-settle comms-lookback-distillation --by no-such-task --key "$K"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no task dir for settling slug"* ]]
}

@test "an unknown asking slug refuses" {
  run scripts/cerebro/cb-settle no-such-asker --by build-ns-comms-sweep --all
  [ "$status" -eq 1 ]
  [[ "$output" == *"no task dir for asking slug"* ]]
}

@test "a task cannot settle its own decision" {
  run scripts/cerebro/cb-settle comms-lookback-distillation --by comms-lookback-distillation --all
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot settle its own"* ]]
}

@test "--by is required" {
  run scripts/cerebro/cb-settle comms-lookback-distillation --all
  [ "$status" -eq 2 ]
}

@test "one of --key or --all is required" {
  run scripts/cerebro/cb-settle comms-lookback-distillation --by build-ns-comms-sweep
  [ "$status" -eq 2 ]
  [[ "$output" == *"--key"* ]]
}

@test "--key and --all are mutually exclusive" {
  run scripts/cerebro/cb-settle comms-lookback-distillation --by build-ns-comms-sweep --key "$K" --all
  [ "$status" -eq 2 ]
  [[ "$output" == *"mutually exclusive"* ]]
}

@test "a slug with shell metacharacters is refused" {
  run scripts/cerebro/cb-settle 'bad;rm -rf /' --by build-ns-comms-sweep --all
  [ "$status" -eq 2 ]
}

@test "a non-numeric key is refused" {
  run scripts/cerebro/cb-settle comms-lookback-distillation --by build-ns-comms-sweep --key "not-a-key"
  [ "$status" -eq 2 ]
}

@test "an unknown flag is a usage error" {
  run scripts/cerebro/cb-settle comms-lookback-distillation --by build-ns-comms-sweep --nope
  [ "$status" -eq 2 ]
}

# The settlement pointer must never be mistaken for an answer Kyle gave. It is a
# claim about causation; the shipping evidence is what retires the question.
@test "settlement does not write a resolved line" {
  touch "$BY/done"
  run scripts/cerebro/cb-settle comms-lookback-distillation --by build-ns-comms-sweep --key "$K"
  ! grep -q ' resolved ' "$ASK/decisions"
  grep -q ' settled-by ' "$ASK/decisions"
}

# The decisions log is a channel models hand-append to — that is the entire
# verb-audit rationale — so the fold validates the settler slug rather than
# trusting cb-settle to be its only writer.
@test "a hand-written settled-by with a path-traversal slug is ignored by the fold" {
  esc="$BATS_TEST_TMPDIR/escape"; mkdir -p "$esc"; touch "$esc/done"
  printf '%s settled-by %s ../../../../../../..%s\n' "$(_decision_ts)" "$K" "$esc" >> "$ASK/decisions"
  run open_decisions_live "$ASK"; [[ "$output" == *"standalone, fold, or hold"* ]]
}

@test "a hand-written settled-by with an uppercase or spaced slug is ignored" {
  printf '%s settled-by %s BUILD-NS-COMMS-SWEEP\n' "$(_decision_ts)" "$K" >> "$ASK/decisions"
  touch "$BY/done"
  run open_decisions_live "$ASK"; [[ "$output" == *"standalone, fold, or hold"* ]]
}
