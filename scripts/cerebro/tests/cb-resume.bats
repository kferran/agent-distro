#!/usr/bin/env bats
# cb-resume — the COMPLETE resume for a reaped code task (2026-08-02).
#
# The state under test is "harness up, brief not delivered": a live tmux session
# on the right branch, a `running` beacon, a green board entry, and an agent at
# an empty composer that has never been told anything. It is indistinguishable
# from a working dispatch from the outside, which is why it survived ~20
# documentation sites and cost four code tasks a day. Every test here exists to
# stop cb-resume printing a success banner over that state.

setup() {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks"
  export CB_GUARD_CMD=:                       # R1: no real cb-guard (network probe)
  export CB_RESUME_VERIFY_SECS=0 CB_RESUME_POLL_SECS=0
  export FIXTURES="$BATS_TEST_DIRNAME/fixtures/panes"
  export STARTLOG="$BATS_TEST_TMPDIR/start.log"; : > "$STARTLOG"
  export BRIEFLOG="$BATS_TEST_TMPDIR/brief.log"; : > "$BRIEFLOG"
  export SENDLOG="$BATS_TEST_TMPDIR/send.log";  : > "$SENDLOG"

  # cb-start stand-in. The REAL one writes launch-line + the marker context.md
  # and brings a harness up; this records its args and writes the launch-line,
  # which is the only output cb-resume consumes from it.
  export CB_START_CMD="$BATS_TEST_TMPDIR/fakestart"
  cat > "$CB_START_CMD" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STARTLOG"
slug=""; for a in "$@"; do case "$prev" in --adopt) slug="$a";; esac; prev="$a"; done
printf 'Invoke the ultron:work-conductor skill to drive this work.\n' > "$CB_HOME/tasks/$slug/launch-line"
exit 0
EOF
  chmod +x "$CB_START_CMD"

  # cb-brief stand-in — writes the same TEMPLATE shape the real one writes:
  # frontmatter, empty headings, then the agent contract. The empty middle is
  # the point; splicing is what fills it.
  export CB_BRIEF_CMD="$BATS_TEST_TMPDIR/fakebrief"
  cat > "$CB_BRIEF_CMD" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$BRIEFLOG"
slug=""; wt=""; for a in "$@"; do
  case "$prev" in --code) slug="$a";; --worktree) wt="$a";; esac; prev="$a"; done
mkdir -p "$wt/.ai/specs/$slug"
cat > "$wt/.ai/specs/$slug/context.md" <<INNER
---
task: $slug
type: code
---
# Objective

# Context
<!-- dispatch skill fills from the dev item -->

# Scope
In:
Out:

# Agent contract (read before you branch or commit)
- **Worktree isolation:** run \`pwd -P\` FIRST.
INNER
exit 0
EOF
  chmod +x "$CB_BRIEF_CMD"

  export CB_SEND_CMD="$BATS_TEST_TMPDIR/fakesend"
  export SEND_RC=0
  printf '#!/usr/bin/env bash\necho "$*" >> "$SENDLOG"\nexit ${SEND_RC:-0}\n' > "$CB_SEND_CMD"
  chmod +x "$CB_SEND_CMD"

  # default pane: an agent sitting at an empty composer — THE failure state
  export CB_PANE_CMD="cat $FIXTURES/coord-idle-empty.txt"
}

# --- world-building ----------------------------------------------------------

PS_DEAD='1 0 systemd
1000 1 bash'
PS_LIVE='1 0 systemd
1000 1 claude'

harness() {   # harness <slug> <dead|live>
  export PSFILE="$BATS_TEST_TMPDIR/ps.table"
  case "$2" in dead) printf '%s\n' "$PS_DEAD";; live) printf '%s\n' "$PS_LIVE";; esac > "$PSFILE"
  export CB_SESSION_LIST_CMD="printf '$1\n'"
  export CB_SESSION_PID_CMD="printf '$1 1000\n'"
  export CB_PS_CMD="cat $PSFILE"
}

# code_task SLUG — a reaped code task: meta with a target + an existing worktree,
# harness gone. Exports WT and TD for the test body.
code_task() {
  local slug="$1"
  export TD="$CB_HOME/tasks/$slug" WT="$BATS_TEST_TMPDIR/wt/$slug"
  mkdir -p "$TD" "$WT/.ai/specs/$slug"
  printf 'kind=code\nworktree=%s\njira=EJA-1234\nsession=%s\ntarget=ultron\n' "$WT" "$slug" > "$TD/meta"
  harness "$slug" dead
}

write_brief() {   # write_brief SLUG — a real, substantive brief.md
  cat > "$CB_HOME/tasks/$1/brief.md" <<'EOF'
---
task: fix-x
type: code
clearance: standard
jira: EJA-1234
---
# Brief — the actual work

Kyle asked for the buyout XML nulling to be traced to its gatherer.

# Landing
Commit and push to the task branch.
EOF
}

marker_ctx() {    # marker_ctx SLUG — cb-start's adopted-session marker verbatim
  printf -- '---\ntask: %s\ntype: code (adopted)\njira: EJA-1234\n---\n# Adopted-session marker (cb-start --adopt)\nMarks this session start so resolve_run scopes classification to the current run.\n' \
    "$1" > "$WT/.ai/specs/$1/context.md"
}

real_ctx() {      # real_ctx SLUG — a good context.md nobody should clobber
  printf -- '---\ntask: %s\ntype: code\n---\n# Objective\nFix the thing properly.\n\n# Agent contract (read before you branch or commit)\n- isolation\n' \
    "$1" > "$WT/.ai/specs/$1/context.md"
}

sent()    { [ -s "$SENDLOG" ]; }
adopted() { [ -s "$STARTLOG" ]; }

# ============================================================================
# THE STATE THIS COMMAND EXISTS FOR
# ============================================================================
# Everything upstream succeeded — adopt returned 0, the brief was written, and
# cb-send exited 0 without printing anything (measured 2026-08-02: it does
# exactly that on a send that worked, so its exit status carries no delivery
# signal in the success direction). The pane still shows an empty composer and
# no manifest was ever written. That is an unbriefed agent, and it must NOT be
# reported as a resume.

@test "harness up, brief NOT delivered → exit 7, no success banner" {
  code_task fix-x; write_brief fix-x; marker_ctx fix-x
  run scripts/cerebro/cb-resume fix-x
  [ "$status" -eq 7 ]
  [[ "$output" == *"HARNESS UP, BRIEF NOT DELIVERED"* ]]
  [[ "$output" != *"resumed fix-x — agent working"* ]]
  sent                                            # the send WAS attempted
}

@test "the same failure names the session so a human can look at it" {
  code_task fix-x; write_brief fix-x; marker_ctx fix-x
  run scripts/cerebro/cb-resume fix-x
  [ "$status" -eq 7 ]
  [[ "$output" == *"tmux attach -t fix-x"* ]]
}

# an empty composer is NOT evidence of delivery on its own — it is exactly what
# a never-briefed agent shows. Only an emptied composer that demonstrably HELD
# the launch line counts, and this pane never did.
@test "an empty composer alone is not accepted as delivery" {
  code_task fix-x; write_brief fix-x; marker_ctx fix-x
  export CB_PANE_CMD="cat $FIXTURES/composer-empty.txt"
  run scripts/cerebro/cb-resume fix-x
  [ "$status" -eq 7 ]
}

# ============================================================================
# the positives
# ============================================================================

@test "a BUSY pane is accepted — the agent started working" {
  code_task fix-x; write_brief fix-x; marker_ctx fix-x
  export CB_PANE_CMD="cat $FIXTURES/coord-busy.txt"
  run scripts/cerebro/cb-resume fix-x
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent working"* ]]
  [[ "$output" == *"observed: busy"* ]]
}

# The conductor writing a manifest AFTER our context.md is independent proof it
# read the brief. The freshness floor matters: an adopted worktree is full of
# prior-cycle manifests, and a stale one must not read as this session's work.
@test "a manifest written after context.md is accepted" {
  code_task fix-x; write_brief fix-x; marker_ctx fix-x
  export CB_RESUME_VERIFY_SECS=5 CB_RESUME_POLL_SECS=0
  # the fake send stands in for a conductor that boots and writes its manifest
  cat > "$CB_SEND_CMD" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$SENDLOG"
sleep 0.2
printf -- '---\nname: fix-x\ncurrent_phase: spec\n---\n' > "$WT/.ai/specs/fix-x/manifest.md"
exit 0
EOF
  chmod +x "$CB_SEND_CMD"
  run scripts/cerebro/cb-resume fix-x
  [ "$status" -eq 0 ]
  [[ "$output" == *"observed: manifest"* ]]
}

@test "a PRIOR-cycle manifest predating context.md is NOT accepted" {
  code_task fix-x; write_brief fix-x; marker_ctx fix-x
  printf -- '---\nname: fix-x\ncurrent_phase: ship\n---\n' > "$WT/.ai/specs/fix-x/manifest.md"
  sleep 0.01
  run scripts/cerebro/cb-resume fix-x
  [ "$status" -eq 7 ]                             # stale artifact, not this run
}

# ============================================================================
# re-brief decision — do not clobber a good context.md, do not send an empty one
# ============================================================================

@test "a good context.md is kept, not clobbered" {
  code_task fix-x; write_brief fix-x; real_ctx fix-x
  touch -d '-1 hour' "$CB_HOME/tasks/fix-x/brief.md"
  export CB_PANE_CMD="cat $FIXTURES/coord-busy.txt"
  run scripts/cerebro/cb-resume fix-x
  [ "$status" -eq 0 ]
  [[ "$output" == *"not clobbering a good brief"* ]]
  [ ! -s "$BRIEFLOG" ]                            # cb-brief never ran
  grep -q "Fix the thing properly" "$WT/.ai/specs/fix-x/context.md"
}

@test "cb-start's adopted-session MARKER is detected as no brief at all" {
  code_task fix-x; write_brief fix-x; marker_ctx fix-x
  export CB_PANE_CMD="cat $FIXTURES/coord-busy.txt"
  run scripts/cerebro/cb-resume fix-x
  [ "$status" -eq 0 ]
  [[ "$output" == *"adopted-session marker"* ]]
  [ -s "$BRIEFLOG" ]
}

# Keyed on the marker's TEXT, not its ~206-byte length: the byte count moves with
# the slug and the jira key, so a size test is a coin flip on long slugs.
@test "the marker is detected on a long slug too (not a byte-size heuristic)" {
  code_task eja-3881-net-worth-justification-not-on-summary-doc
  write_brief eja-3881-net-worth-justification-not-on-summary-doc
  marker_ctx eja-3881-net-worth-justification-not-on-summary-doc
  export CB_PANE_CMD="cat $FIXTURES/coord-busy.txt"
  run scripts/cerebro/cb-resume eja-3881-net-worth-justification-not-on-summary-doc
  [ "$status" -eq 0 ]
  [[ "$output" == *"adopted-session marker"* ]]
}

@test "a context.md older than brief.md is re-briefed" {
  code_task fix-x; real_ctx fix-x; sleep 0.01; write_brief fix-x
  export CB_PANE_CMD="cat $FIXTURES/coord-busy.txt"
  run scripts/cerebro/cb-resume fix-x
  [ "$status" -eq 0 ]
  [[ "$output" == *"newer than context.md"* ]]
}

# ORDERING. cb-start --adopt writes the marker context.md ITSELF (cb-start:213),
# so a resume that inspects context.md AFTER adopting always sees a file newer
# than brief.md and the staleness branch can never fire. State has to be captured
# before anything mutates. This fake cb-start touches context.md to prove it.
@test "context.md state is read BEFORE the adopt mutates it" {
  code_task fix-x; real_ctx fix-x; sleep 0.01; write_brief fix-x
  cat > "$CB_START_CMD" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STARTLOG"
touch "$WT/.ai/specs/fix-x/context.md"          # adopt refreshes it — as cb-start does
printf 'Invoke the ultron:work-conductor skill to drive this work.\n' > "$CB_HOME/tasks/fix-x/launch-line"
EOF
  chmod +x "$CB_START_CMD"
  export CB_PANE_CMD="cat $FIXTURES/coord-busy.txt"
  run scripts/cerebro/cb-resume fix-x
  [ "$status" -eq 0 ]
  [[ "$output" == *"newer than context.md"* ]]    # still detected
  [ -s "$BRIEFLOG" ]
}

# THE SAME DEFECT WEARING A DIFFERENT MASK. cb-brief writes empty `# Objective` /
# `# Context` / `# Scope` headings by design. Briefing from that template and
# sending anyway produces an agent that starts, reads three blank headings, and
# has no work — which looks exactly as healthy as never briefing it.
@test "nothing to brief with → refuse, and spawn NOTHING" {
  code_task fix-x; marker_ctx fix-x                # no brief.md
  run scripts/cerebro/cb-resume fix-x
  [ "$status" -eq 3 ]
  [[ "$output" == *"no brief to rebuild it from"* ]]
  ! adopted
  ! sent
}

@test "missing context.md and no brief.md → refuse, spawn NOTHING" {
  code_task fix-x                                  # neither file
  run scripts/cerebro/cb-resume fix-x
  [ "$status" -eq 3 ]
  ! adopted
  ! sent
}

@test "a brief.md with frontmatter but no body → exit 5, nothing sent" {
  code_task fix-x; marker_ctx fix-x
  printf -- '---\ntask: fix-x\ntype: code\n---\n\n' > "$CB_HOME/tasks/fix-x/brief.md"
  run scripts/cerebro/cb-resume fix-x
  [ "$status" -eq 5 ]
  [[ "$output" == *"nothing to splice"* ]]
  ! sent
}

# ============================================================================
# the splice
# ============================================================================

@test "the brief body lands BETWEEN the frontmatter and the agent contract" {
  code_task fix-x; write_brief fix-x; marker_ctx fix-x
  export CB_PANE_CMD="cat $FIXTURES/coord-busy.txt"
  run scripts/cerebro/cb-resume fix-x
  [ "$status" -eq 0 ]
  local ctx="$WT/.ai/specs/fix-x/context.md"
  grep -q "buyout XML nulling" "$ctx"                       # the content arrived
  local fm body contract
  fm=$(grep -n '^---$' "$ctx" | sed -n 2p | cut -d: -f1)
  body=$(grep -n 'buyout XML nulling' "$ctx" | cut -d: -f1)
  contract=$(grep -n '^# Agent contract' "$ctx" | cut -d: -f1)
  [ "$fm" -lt "$body" ]
  [ "$body" -lt "$contract" ]
}

@test "the splice drops brief.md's own frontmatter (no stray --- mid-file)" {
  code_task fix-x; write_brief fix-x; marker_ctx fix-x
  export CB_PANE_CMD="cat $FIXTURES/coord-busy.txt"
  run scripts/cerebro/cb-resume fix-x
  [ "$status" -eq 0 ]
  # exactly the two fences of context.md's own frontmatter
  [ "$(grep -c '^---$' "$WT/.ai/specs/fix-x/context.md")" -eq 2 ]
  ! grep -q 'clearance: standard' "$WT/.ai/specs/fix-x/context.md"
}

@test "the Landing section survives the splice" {
  code_task fix-x; write_brief fix-x; marker_ctx fix-x
  export CB_PANE_CMD="cat $FIXTURES/coord-busy.txt"
  run scripts/cerebro/cb-resume fix-x
  grep -q '^# Landing' "$WT/.ai/specs/fix-x/context.md"
}

@test "an unrecognisable context.md shape is refused rather than spliced blindly" {
  code_task fix-x; write_brief fix-x; marker_ctx fix-x
  printf '#!/usr/bin/env bash\necho "$*" >> "$BRIEFLOG"\nprintf "just some text\\n" > "$WT/.ai/specs/fix-x/context.md"\n' > "$CB_BRIEF_CMD"
  chmod +x "$CB_BRIEF_CMD"
  run scripts/cerebro/cb-resume fix-x
  [ "$status" -eq 5 ]
  [[ "$output" == *"shape I do not recognise"* ]]
  ! sent
}

# ============================================================================
# refusals that spawn nothing
# ============================================================================

@test "a LIVE session is refused — a resume into a working agent corrupts its turn" {
  code_task fix-x; write_brief fix-x; harness fix-x live
  run scripts/cerebro/cb-resume fix-x
  [ "$status" -eq 3 ]
  [[ "$output" == *"not gone"* ]]
  ! adopted
  ! sent
}

# `unavailable` means we cannot tell. Same asymmetry rule cb-start --adopt uses:
# only a positive `gone` proceeds.
@test "unreadable liveness is refused, not assumed dead" {
  code_task fix-x; write_brief fix-x
  export CB_SESSION_LIST_CMD="exit 127"
  run scripts/cerebro/cb-resume fix-x
  [ "$status" -eq 3 ]
  ! adopted
}

@test "no target in meta and none passed → refuse" {
  code_task fix-x; write_brief fix-x
  printf 'kind=code\nworktree=%s\nsession=fix-x\n' "$WT" > "$TD/meta"
  run scripts/cerebro/cb-resume fix-x
  [ "$status" -eq 3 ]
  [[ "$output" == *"no target"* ]]
  ! adopted
}

@test "--target supplies what the meta lacks" {
  code_task fix-x; write_brief fix-x; real_ctx fix-x
  printf 'kind=code\nworktree=%s\nsession=fix-x\n' "$WT" > "$TD/meta"
  export CB_PANE_CMD="cat $FIXTURES/coord-busy.txt"
  run scripts/cerebro/cb-resume fix-x --target ultron
  [ "$status" -eq 0 ]
  grep -q -- "--target ultron" "$STARTLOG"
}

@test "a worktree that does not exist → refuse (resume attaches to an EXISTING one)" {
  code_task fix-x; write_brief fix-x
  printf 'kind=code\nworktree=%s\nsession=fix-x\ntarget=ultron\n' "$BATS_TEST_TMPDIR/nope" > "$TD/meta"
  run scripts/cerebro/cb-resume fix-x
  [ "$status" -eq 3 ]
  [[ "$output" == *"does not exist"* ]]
  ! adopted
}

@test "a slug with shell metacharacters is refused before anything runs" {
  run scripts/cerebro/cb-resume 'x;touch /tmp/cb-resume-pwn'
  [ "$status" -eq 2 ]
  [ ! -e /tmp/cb-resume-pwn ]
}

@test "no slug → usage" {
  run scripts/cerebro/cb-resume
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage"* ]]
}

# ============================================================================
# failures of the individual steps, each with its own exit code so an unattended
# caller (magneto's remediation class) can branch on WHICH half failed
# ============================================================================

@test "adopt failure → exit 4, nothing briefed or sent" {
  code_task fix-x; write_brief fix-x; marker_ctx fix-x
  export CB_START_CMD="$BATS_TEST_TMPDIR/failstart"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$CB_START_CMD"; chmod +x "$CB_START_CMD"
  run scripts/cerebro/cb-resume fix-x
  [ "$status" -eq 4 ]
  [[ "$output" == *"adopt failed"* ]]
  [ ! -s "$BRIEFLOG" ]
  ! sent
}

@test "cb-brief failure → exit 5, nothing sent" {
  code_task fix-x; write_brief fix-x; marker_ctx fix-x
  printf '#!/usr/bin/env bash\nexit 1\n' > "$CB_BRIEF_CMD"; chmod +x "$CB_BRIEF_CMD"
  run scripts/cerebro/cb-resume fix-x
  [ "$status" -eq 5 ]
  ! sent
}

@test "no launch line after adopt → exit 5, nothing sent" {
  code_task fix-x; write_brief fix-x; marker_ctx fix-x
  printf '#!/usr/bin/env bash\necho "$*" >> "$STARTLOG"\nexit 0\n' > "$CB_START_CMD"
  chmod +x "$CB_START_CMD"
  run scripts/cerebro/cb-resume fix-x
  [ "$status" -eq 5 ]
  [[ "$output" == *"no launch line"* ]]
  ! sent
}

# cb-send exit 3/4 are POSITIVE evidence of non-delivery — unlike its 0, which
# carries no signal. Take them at once instead of burning the verify window on a
# message we already know never landed.
@test "cb-send refusal (exit 3) → exit 6 without waiting out the verify window" {
  code_task fix-x; write_brief fix-x; marker_ctx fix-x
  export SEND_RC=3 CB_RESUME_VERIFY_SECS=60
  run scripts/cerebro/cb-resume fix-x
  [ "$status" -eq 6 ]
  [[ "$output" == *"did not deliver"* ]]
}

@test "cb-send non-delivery (exit 4) → exit 6" {
  code_task fix-x; write_brief fix-x; marker_ctx fix-x
  export SEND_RC=4 CB_RESUME_VERIFY_SECS=60
  run scripts/cerebro/cb-resume fix-x
  [ "$status" -eq 6 ]
}

# ============================================================================
# wiring
# ============================================================================

@test "cb-resume runs cb-guard first" {
  code_task fix-x; write_brief fix-x; real_ctx fix-x
  export CB_GUARD_CMD="$BATS_TEST_TMPDIR/guard-rec"
  printf '#!/usr/bin/env bash\ntouch %q\n' "$BATS_TEST_TMPDIR/guard-ran" > "$CB_GUARD_CMD"
  chmod +x "$CB_GUARD_CMD"
  run scripts/cerebro/cb-resume fix-x
  [ -f "$BATS_TEST_TMPDIR/guard-ran" ]
}

@test "the adopt carries the jira key through from the meta" {
  code_task fix-x; write_brief fix-x; real_ctx fix-x
  export CB_PANE_CMD="cat $FIXTURES/coord-busy.txt"
  run scripts/cerebro/cb-resume fix-x
  grep -q -- "--jira EJA-1234" "$STARTLOG"
  grep -q -- "--worktree $WT" "$STARTLOG"
}

@test "the launch line cb-start wrote is what gets sent" {
  code_task fix-x; write_brief fix-x; real_ctx fix-x
  export CB_PANE_CMD="cat $FIXTURES/coord-busy.txt"
  run scripts/cerebro/cb-resume fix-x
  grep -q "ultron:work-conductor" "$SENDLOG"
}

# The variable is EMPTY by design since the 2026-08-02 re-seed, and `grep -E ""`
# matches every line — so keying completion on it would make the success banner
# unconditional, which is the entire defect.
@test "completion never keys on CB_COORD_READY_RE" {
  ! grep -q '\$CB_COORD_READY_RE' scripts/cerebro/cb-resume
}

# ============================================================================
# THE PANE IT READS IS THE TARGET'S, NOT THE COORDINATOR'S
# ============================================================================
# The dev item's step 2 originally cited a live measurement that
# `cb_coord_pane_state` "returns busy correctly against cold --code conductor
# boots." That measurement was invalid and the correction landed 2026-08-03:
# cb_coord_pane_state takes NO argument. It calls cb_coord_pane_tail(), which is
# hardcoded to $CB_SESSION (default `Cerebro`), so passing a conductor's session
# name does nothing and every such call reads the COORDINATOR's pane.
#
# Borrowing that helper here would have been wrong in the always-succeed
# direction: any turn the coordinator happened to be taking would read as "the
# conductor started working", and cb-resume would print a success banner over an
# unbriefed agent — the exact defect it exists to prevent, now automated. So
# cb-resume runs its own per-pane probe via cb_pane_tail <slug>.
#
# These two tests discriminate by pointing the two mocks at OPPOSITE fixtures.

@test "a BUSY coordinator pane does NOT make an idle target read as started" {
  code_task fix-x; write_brief fix-x; marker_ctx fix-x
  export CB_COORD_PANE_CMD="cat $FIXTURES/coord-busy.txt"        # coordinator: working
  export CB_PANE_CMD="cat $FIXTURES/coord-idle-empty.txt"        # the target: idle
  run scripts/cerebro/cb-resume fix-x
  [ "$status" -eq 7 ]                                            # reads the TARGET
  [[ "$output" == *"HARNESS UP, BRIEF NOT DELIVERED"* ]]
}

@test "a BUSY target is accepted even while the coordinator sits idle" {
  code_task fix-x; write_brief fix-x; marker_ctx fix-x
  export CB_COORD_PANE_CMD="cat $FIXTURES/coord-idle-empty.txt"  # coordinator: idle
  export CB_PANE_CMD="cat $FIXTURES/coord-busy.txt"              # the target: working
  run scripts/cerebro/cb-resume fix-x
  [ "$status" -eq 0 ]
  [[ "$output" == *"observed: busy"* ]]
}

# BUSY rung 4 (added 2026-08-03): spinner glyph + capitalised gerund with NO
# trailing ellipsis. A canary caught `✻ Waiting for 1 background agent to finish`
# reading not-busy on a working pane. cb-resume SOURCES the pattern from
# lib/coordinator.sh rather than carrying a copy, so a re-seed reaches it — this
# test is what proves that plumbing works end to end.
@test "BUSY rung 4 (gerund, no ellipsis) is honoured through the sourced pattern" {
  code_task fix-x; write_brief fix-x; marker_ctx fix-x
  export CB_PANE_CMD="cat $FIXTURES/conductor-busy-rung4.txt"
  run scripts/cerebro/cb-resume fix-x
  [ "$status" -eq 0 ]
  [[ "$output" == *"observed: busy"* ]]
}

# Sourced, never copied. A literal copy is how the retired READY pattern went on
# living in three places after its re-seed; the next BUSY re-seed must reach here
# for free.
@test "the BUSY pattern is sourced from lib/coordinator.sh, not copied inline" {
  grep -q 'source .*lib/coordinator.sh' scripts/cerebro/cb-resume
  grep -q '\$CB_COORD_BUSY_RE' scripts/cerebro/cb-resume
  ! grep -q 'esc to interrupt' scripts/cerebro/cb-resume     # no inlined alternation
  ! grep -q 'ing\[\^…\]' scripts/cerebro/cb-resume
}

# --- the resume names the SAME X-Man the spawn did (2026-08-05) ---------------
@test "a successful resume prints the persisted X-Man name" {
  code_task fix-x; write_brief fix-x; marker_ctx fix-x
  printf 'Nightcrawler\n' > "$CB_HOME/tasks/fix-x/xman"
  export CB_PANE_CMD="cat $FIXTURES/coord-busy.txt"
  run scripts/cerebro/cb-resume fix-x
  [ "$status" -eq 0 ]
  [[ "$output" == *"xman=Nightcrawler"* ]]
}
@test "a resume of a task with no persisted name says nothing about an X-Man" {
  code_task fix-x; write_brief fix-x; marker_ctx fix-x
  export CB_PANE_CMD="cat $FIXTURES/coord-busy.txt"
  run scripts/cerebro/cb-resume fix-x
  [ "$status" -eq 0 ]
  [[ "$output" != *"xman="* ]]   # no invented name; the real cb-start would have persisted one
}
