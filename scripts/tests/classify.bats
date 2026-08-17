setup() { load ../lib/classify.sh; TD="$BATS_TEST_TMPDIR/task"; mkdir -p "$TD"; }

# --- terminal report wins regardless of window state ---
@test "complete report → ready-for-review" {
  printf -- '---\nstatus: complete\n---\n' > "$TD/report.md"; printf running > "$TD/status"
  run classify_research "$TD"; [ "$output" = "ready-for-review" ]
}
@test "complete with trailing space → ready-for-review" {
  printf -- '---\nstatus: complete \n---\n' > "$TD/report.md"; printf running > "$TD/status"
  run classify_research "$TD"; [ "$output" = "ready-for-review" ]
}
@test "complete with CRLF → ready-for-review" {
  printf -- '---\r\nstatus: complete\r\n---\r\n' > "$TD/report.md"; printf running > "$TD/status"
  run classify_research "$TD"; [ "$output" = "ready-for-review" ]
}
# MOVED failed → needs-input, 2026-08-16 (Kyle: option (a)). `status:` below the
# closing `---` is not frontmatter, so _fm_status finds nothing and the report is
# non-terminal — that part is unchanged and is what this test exists to pin. What
# moved is where a non-terminal report LANDS: 47078ba6 routed the gone/unavailable
# arms to needs-input, so the fall-through no longer reaches `failed`. Nothing in
# the R13 spec covers a malformed report; this is a side-effect of Finding 1, and
# accepting it is R13's own principle — a botched frontmatter is not positive
# evidence the agent died, and `failed` is the state cb-reap acts on destructively.
@test "status in body only → non-terminal, so needs-input (never ready-for-review)" {
  printf -- '---\n---\nstatus: complete\n' > "$TD/report.md"; touch -d '2 hours ago' "$TD/report.md"
  run classify_research "$TD"
  [ "$output" = "needs-input" ]
  [ "$output" != "ready-for-review" ]   # the point: body text must not read as terminal
}
@test "terminal report wins even when the window is alive" {
  printf -- '---\nstatus: complete\n---\n' > "$TD/report.md"; printf running > "$TD/status"
  CB_WINDOW_LIST_CMD="printf 'task\n'" run classify_research "$TD"
  [ "$output" = "ready-for-review" ]
}
@test "terminal failed report wins even when the window is alive" {
  printf -- '---\nstatus: failed\n---\n' > "$TD/report.md"; printf running > "$TD/status"
  CB_WINDOW_LIST_CMD="printf 'task\n'" run classify_research "$TD"
  [ "$output" = "failed" ]
}

# --- R13 polarity: window alive absorbs (running) ONLY on positive proof ---
# (a fresh beacon line under CB_STALE_ESCALATE_SECS). A live window with a
# STALE beacon is no longer trusted — silence must be earned, ambiguity
# surfaces. This inverts the pre-R13 "window alive → running, no evidence".
@test "R13: window alive, stale beacon (2h), no report → blocked (surface on ambiguity)" {
  printf 'running: fetching sources\n' > "$TD/status"; touch -d '2 hours ago' "$TD/status"
  CB_WINDOW_LIST_CMD="printf 'task\n'" run classify_research "$TD"
  [ "$output" = "blocked" ]
}

# --- window gone: crash detection, with a short launch-race grace ---
@test "window gone, beacon just written (within grace) → running" {
  printf running > "$TD/status"
  CB_WINDOW_LIST_CMD="printf ''" run classify_research "$TD"
  [ "$output" = "running" ]
}
# R13 polarity, 2026-08-14: this asserted `failed` until the spec
# (99 Meta/specs/2026-08-13-classify-r13-polarity-design, Finding 1) established
# that a closed research window is NOT positive evidence of a crash — research
# X-Men are windows in the shared `cb` session, and a window closes when the
# agent FINISHES too. `failed` is the only state cb-reap destroys (cb-reap:178),
# so an ambiguity must never reach it.
@test "window gone, beacon older than grace → needs-input, NEVER failed (R13: absence is not evidence)" {
  printf running > "$TD/status"; touch -d '60 seconds ago' "$TD/status"  # > 30s grace, << 1800s stall
  CB_WINDOW_LIST_CMD="printf ''" run classify_research "$TD"
  [ "$output" = "needs-input" ]
  [ "$output" != "failed" ]
}
@test "window gone, no beacon at all, task dir past pre-spawn grace → failed (crashed before first beacon)" {
  touch -d '10 minutes ago' "$TD"   # > CB_PRESPAWN_GRACE_SECS (300): not a launch race
  CB_WINDOW_LIST_CMD="printf ''" run classify_research "$TD"
  [ "$output" = "failed" ]
}

# --- window-list unavailable: fall back to the old beacon-mtime rule ---
# CB_WINDOW_LIST_CMD="exit 127" is the deterministic "can't tell" signal
# (mirrors what a genuinely missing tmux binary produces: bash's own
# "command not found" exit code) — used instead of hiding the real tmux
# binary from PATH, which isn't reliably controllable inside a test.
@test "fallback: unavailable + fresh beacon (2min, under escalate) → running (degrade: trust fresh proof)" {
  printf running > "$TD/status"; touch -d '2 minutes ago' "$TD/status"  # > 30s grace, < 240s escalate
  CB_WINDOW_LIST_CMD="exit 127" run classify_research "$TD"
  [ "$output" = "running" ]
}
# R13 polarity, 2026-08-14. `unavailable` is the sharpest case in the spec's
# table: it is what cb_window_alive returns when it COULD NOT DETERMINE
# liveness. A stale beacon on top of that is two absences stacked, not evidence.
@test "fallback: unavailable + stale beacon (2h) → needs-input, NEVER failed (R13)" {
  printf running > "$TD/status"; touch -d '2 hours ago' "$TD/status"
  CB_WINDOW_LIST_CMD="exit 127" run classify_research "$TD"
  [ "$output" = "needs-input" ]
  [ "$output" != "failed" ]
}
@test "fallback: unavailable + no beacon, task dir past pre-spawn grace → failed" {
  touch -d '10 minutes ago' "$TD"   # past the pre-spawn grace: not a launch race
  CB_WINDOW_LIST_CMD="exit 127" run classify_research "$TD"
  [ "$output" = "failed" ]
}

# --- (d) scope-add #2: pre-spawn / launch-race grace. cb-brief creates the task
# dir + brief.md; cb-start writes the FIRST beacon only after the window
# launches. In the ~30-90s brief→launch gap there's no beacon, no report, no
# window yet — the classifier must NOT read `failed` (all five research spawns
# false-failed here today). A FRESH such dir → running (grace); past the grace
# it's a crash (above). Gated on no-report so a malformed report still → failed.
@test "(d) fresh task dir, brief written, no beacon/report/window yet → running (pre-spawn grace)" {
  printf '# brief\n' > "$TD/brief.md"    # cb-brief ran; cb-start not yet
  CB_WINDOW_LIST_CMD="printf ''" run classify_research "$TD"
  [ "$output" = "running" ]
}
@test "(d) pre-spawn grace keys on brief.md mtime — an aged brief with no beacon → failed" {
  printf '# brief\n' > "$TD/brief.md"; touch -d '10 minutes ago' "$TD/brief.md"
  CB_WINDOW_LIST_CMD="printf ''" run classify_research "$TD"
  [ "$output" = "failed" ]
}
# MOVED failed → needs-input, 2026-08-16 (Kyle: option (a)) — same side-effect as
# "status in body only" above. (d)'s intent is intact and is what the second
# assertion pins: the pre-spawn grace must NOT rescue a malformed report into
# `running`. It doesn't; it just lands on needs-input rather than failed now.
@test "(d) does NOT rescue a malformed (non-terminal) report — needs-input, never running" {
  printf -- '---\n---\nstatus: complete\n' > "$TD/report.md"   # status in body, fresh dir
  CB_WINDOW_LIST_CMD="printf ''" run classify_research "$TD"
  [ "$output" = "needs-input" ]
  [ "$output" != "running" ]            # the grace must not rescue it — (d)'s whole point
}

# --- (c) scope-add #2: a stale beacon is a wedge-SUSPECT, but a turn actively in
# progress (a 5-8 min advisor/architect call) is positive proof of work, not a
# stall. Consult the cb-window pane before escalating a stale beacon to blocked.
FIXPANES_C() { echo "$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/panes"; }
@test "(c) window alive + stale beacon + pane busy (esc to interrupt) → running (not a stall)" {
  printf 'running: consulting advisor\n' > "$TD/status"; touch -d '2 hours ago' "$TD/status"
  CB_WINDOW_LIST_CMD="printf 'task\n'" CB_PANE_CMD="cat '$(FIXPANES_C)/research-busy.txt'" \
    run classify_research "$TD"
  [ "$output" = "running" ]
}
@test "(c) window alive + stale beacon + pane idle (no turn in progress) → blocked (unchanged)" {
  printf 'running: fetching sources\n' > "$TD/status"; touch -d '2 hours ago' "$TD/status"
  CB_WINDOW_LIST_CMD="printf 'task\n'" CB_PANE_CMD="cat '$(FIXPANES_C)/research-idle.txt'" \
    run classify_research "$TD"
  [ "$output" = "blocked" ]
}

# =====================================================================
# R9 (sparse status beacon + stall detection) + R6 (paused, two clocks)
# + R13 (surface-on-ambiguity). The beacon is append-only: agents append
# `{state}: {one line}` on material phase changes; the classifier reads the
# last line for state and the file mtime for staleness.
# =====================================================================

# --- R9: the beacon's LAST line drives state (append-only, tolerant of the
#     bare `running` launch word cb-start writes) ---
@test "beacon parser: appended running line, fresh → running (last-line state)" {
  printf 'running\nrunning: verifying claims\n' > "$TD/status"; touch -d '1 minute ago' "$TD/status"
  CB_WINDOW_LIST_CMD="printf 'task\n'" run classify_research "$TD"
  [ "$output" = "running" ]
}
@test "beacon parser: agent-declared blocked on the last line → blocked" {
  printf 'running: started\nblocked: upstream API returning 500s\n' > "$TD/status"
  CB_WINDOW_LIST_CMD="printf 'task\n'" run classify_research "$TD"
  [ "$output" = "blocked" ]
}

# --- R9 + R13: staleness with surface-on-positive-proof polarity ---
@test "R13: window alive, FRESH running beacon (<escalate) → running (proof of progress)" {
  printf 'running: fetching sources\n' > "$TD/status"; touch -d '2 minutes ago' "$TD/status"  # < 240s
  CB_WINDOW_LIST_CMD="printf 'task\n'" run classify_research "$TD"
  [ "$output" = "running" ]
}
# the literal finding-#1 case: an agent that wrote only the bare `running`
# launch word, then crashed to an idle prompt / spend-wedged and never appended.
# Pre-R9 this classified `running` forever; now the launch-word mtime goes stale.
@test "R9: bare launch beacon, window alive, aged past escalate → blocked (no 'running forever')" {
  printf 'running' > "$TD/status"; touch -d '10 minutes ago' "$TD/status"   # bare word, ≥ 240s, no newline
  CB_WINDOW_LIST_CMD="printf 'task\n'" run classify_research "$TD"
  [ "$output" = "blocked" ]
}
@test "R9/R13: window alive, STALE running beacon (≥escalate), no report → blocked (stall)" {
  printf 'running: fetching sources\n' > "$TD/status"; touch -d '5 minutes ago' "$TD/status"  # ≥ 240s
  CB_WINDOW_LIST_CMD="printf 'task\n'" run classify_research "$TD"
  [ "$output" = "blocked" ]
}

# --- R6: paused, two clocks — never escalated as a wedge, but must resurface ---
@test "R6: fresh paused beacon → paused (declared external wait, not a wedge)" {
  printf 'paused: rate-limited, retry at :30\n' > "$TD/status"
  CB_WINDOW_LIST_CMD="printf 'task\n'" run classify_research "$TD"
  [ "$output" = "paused" ]
}
@test "R6: paused aged past the wedge clock but under resurface → still paused (two clocks)" {
  # 5min > CB_STALE_ESCALATE_SECS (240) but << CB_PAUSE_RESURFACE_SECS (3600):
  # a bare stall clock would wrongly flip this to blocked/failed.
  printf 'paused: rate-limited\n' > "$TD/status"; touch -d '5 minutes ago' "$TD/status"
  CB_WINDOW_LIST_CMD="printf 'task\n'" run classify_research "$TD"
  [ "$output" = "paused" ]
}
@test "R6: paused past the resurface clock → resurfaces as needs-input (can't rot invisibly)" {
  printf 'paused: rate-limited\n' > "$TD/status"; touch -d '90 minutes ago' "$TD/status"  # > 3600s
  CB_WINDOW_LIST_CMD="printf 'task\n'" run classify_research "$TD"
  [ "$output" = "needs-input" ]
}
@test "R6: a paused beacon is not escalated as a wedge even with a dead window" {
  printf 'paused: waiting on upstream release\n' > "$TD/status"; touch -d '5 minutes ago' "$TD/status"
  CB_WINDOW_LIST_CMD="printf ''" run classify_research "$TD"
  [ "$output" = "paused" ]
}

# --- literal slug match, not regex (metacharacters in slug must not false-match) ---
@test "cb_window_alive: slug with regex metachar does not false-match a similar window name" {
  CB_WINDOW_LIST_CMD="printf 'eja-3537\n'" run cb_window_alive "eja.3537"
  [ "$output" = "gone" ]
}

# =====================================================================
# classify_code (T18) — code tasks in per-slug tmux SESSIONS (ratified
# 2026-07-12), sentinel = manifest current_task */awaiting-approval.
# =====================================================================

setup_code_task() { # creates $CTD (task dir) + $CWT (worktree with a run dir)
  CTD="$BATS_TEST_TMPDIR/tasks/code-slug"; mkdir -p "$CTD"
  CWT="$BATS_TEST_TMPDIR/worktree"; mkdir -p "$CWT/.ai/specs/code-slug"
  printf 'kind=code\nworktree=%s\njira=EJA-99\nsession=code-slug\n' "$CWT" > "$CTD/meta"
}
write_manifest() { # write_manifest <current_task> [age]
  printf -- '---\nname: code-slug\njira: EJA-99\ncurrent_task: %s\n---\n' "$1" \
    > "$CWT/.ai/specs/code-slug/manifest.md"
  [ -n "${2:-}" ] && touch -d "$2" "$CWT/.ai/specs/code-slug/manifest.md" || true
}

@test "cb_session_alive: alive / gone / unavailable" {
  CB_SESSION_LIST_CMD="printf 'code-slug\nCerebro\n'" run cb_session_alive code-slug
  [ "$output" = "alive" ]
  CB_SESSION_LIST_CMD="printf 'Cerebro\n'" run cb_session_alive code-slug
  [ "$output" = "gone" ]
  CB_SESSION_LIST_CMD="exit 127" run cb_session_alive code-slug
  [ "$output" = "unavailable" ]
}

@test "sentinel + live session → needs-input" {
  setup_code_task; write_manifest "build/awaiting-approval" '2 hours ago'
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" run classify_code "$CTD"
  [ "$output" = "needs-input" ]
}

@test "sentinel + dead session → failed (sentinel is a positive signal only)" {
  setup_code_task; write_manifest "build/awaiting-approval" '2 hours ago'
  CB_SESSION_LIST_CMD="printf ''" run classify_code "$CTD"
  [ "$output" = "failed" ]
}

# Fixture updated 2026-08-16: since 47078ba6 (Finding 3, Kyle-pinned option (a)) the
# terminal shortcut requires `pr` ALONGSIDE summary.md. summary.md alone rested on an
# ordering guarantee nothing enforced — on 2026-08-13 it held only because summary.md
# was written 20 ms after `pr`. The assertion is unchanged; a shipped task is still
# ready-for-review over a live session. The summary-without-pr case is pinned below.
@test "summary.md + pr → ready-for-review beats running" {
  setup_code_task; write_manifest "build/3-implement"
  touch "$CTD/summary.md" "$CTD/pr"
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" run classify_code "$CTD"
  [ "$output" = "ready-for-review" ]
}

@test "summary.md WITHOUT pr does not short-circuit — a summary is not a shipped PR" {
  setup_code_task; write_manifest "build/3-implement"
  touch "$CTD/summary.md"
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" run classify_code "$CTD"
  [ "$output" != "ready-for-review" ]   # Finding 3: unshipped work must not read shipped
  [ "$output" = "running" ]             # live session, fresh manifest — falls through correctly
}

@test "merged pr.state → done beats everything" {
  setup_code_task; write_manifest "build/awaiting-approval"
  touch "$CTD/summary.md"; printf 'MERGED' > "$CTD/pr.state"
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" run classify_code "$CTD"
  [ "$output" = "done" ]
}

@test "no sentinel, live session, fresh manifest → running (safe pre-sentinel interim)" {
  setup_code_task; write_manifest "build/3-implement" '10 minutes ago'
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" run classify_code "$CTD"
  [ "$output" = "running" ]
}

@test "no sentinel, LIVE session, stale manifest → needs-input, never failed" {
  # This test used to assert `failed`, which encoded the defect: cb-reap:178
  # kills a `failed` session outright without checking unpushed commits, and
  # this branch reached `failed` on an ABSENCE of evidence, not terminal
  # evidence. Cost two conductors the week of 07-27, one with 3 unpushed commits.
  setup_code_task; write_manifest "build/3-implement" '3 hours ago'
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" run classify_code "$CTD"
  [ "$output" = "needs-input" ]
  [ "$output" != "failed" ]
}

# --- gate-vocabulary canary --------------------------------------------------
# The corpus below is every distinct `current_task` value across the 1,600 live
# conductor manifests, harvested 2026-08-02. `*/awaiting-approval` — the old
# sentinel — matched exactly ONE of them. A gate predicate that never fires is
# indistinguishable from "no conductor is at a gate", which is why it rotted
# unnoticed. These tests are the canary: they fail loudly when it stops matching.

KNOWN_GATES="spec/awaiting-approval
ship/awaiting-commit-approval
ship/gate-paused
ship/3-gate
ship/await-go-then-cb-pr-check
ship/followup-relocation-pending-approval
ship/push-blocked-no-credentials"

KNOWN_PROGRESS="ship/complete
review/complete
work/complete
spec/complete
cycle2/complete
ship/3-pull-request
ship/1-knowledge-capture
ship/4-jira-writeback
ship/1-commit-and-pr
ship/1-pull-request
work/2-trust-and-entity-refactor-parallel
review/1-feedback
review/2-cycle-02
spec/1-knowledge-search
spec/2-investigate
spec/3-brainstorm
spec/4-scope-decision
work/1-life-policy-types"

@test "canary: every known gate literal from the live corpus classifies as a gate" {
  while read -r v; do
    [ -n "$v" ] || continue
    run cb_gate_vocab_class "$v"
    [ "$output" = "gate" ] || { echo "MISSED GATE: $v -> $output"; return 1; }
  done <<< "$KNOWN_GATES"
}

@test "canary: no known progress/terminal literal is mistaken for a gate" {
  while read -r v; do
    [ -n "$v" ] || continue
    run cb_gate_vocab_class "$v"
    [ "$output" != "gate" ] || { echo "FALSE GATE: $v"; return 1; }
  done <<< "$KNOWN_PROGRESS"
}

@test "canary HAS TEETH: break the pattern and the gate assertion must fail" {
  # A canary that only ever passes is what let */awaiting-approval rot. Prove it
  # fires by deliberately reverting CB_GATE_PATTERN to the old sentinel.
  CB_GATE_PATTERN='awaiting-approval$'
  missed=0
  while read -r v; do
    [ -n "$v" ] || continue
    [ "$(cb_gate_vocab_class "$v")" = "gate" ] || missed=$((missed + 1))
  done <<< "$KNOWN_GATES"
  [ "$missed" -eq 6 ]      # the old sentinel catches 1 of the 7 known gates
}

@test "vocab: a BARE 'complete' is progress, not unknown" {
  # Measured 2026-08-14 on the live conductor inbox-consolidation-drain-loop, which
  # was parked at a human gate carrying exactly `current_task: complete`. The old
  # `/complete$` required a phase prefix, so the un-prefixed form fell through to the
  # pane heuristics — the shape the gate canary exists to warn about.
  [ "$(cb_gate_vocab_class 'complete')" = "progress" ]
  [ "$(cb_gate_vocab_class 'work/complete')" = "progress" ]
  [ "$(cb_gate_vocab_class 'ship/complete')" = "progress" ]
}

@test "vocab: a trailing # comment does not defeat the end-anchored patterns" {
  # `work/complete` classified progress while the same value with an annotation
  # classified unknown — the comment alone was the difference, because every
  # alternative in CB_PROGRESS_PATTERN is end-anchored.
  [ "$(cb_gate_vocab_class 'work/complete   # work/extract-queue-methods done 2026-08-05')" = "progress" ]
  # And stripping must not swallow a gate that carries an annotation.
  [ "$(cb_gate_vocab_class 'ship/awaiting-approval # blocked on Kyle')" = "gate" ]
}

@test "vocab: widening progress never masks a gate — gate is tested first" {
  # The safety property behind the widening: a value matching BOTH reads gate.
  [ "$(cb_gate_vocab_class 'hold/complete')" = "gate" ]
  [ "$(cb_gate_vocab_class 'paused/2-review')" = "gate" ]
}

@test "canary: unrecognised vocabulary reports 'unknown', it does not guess" {
  run cb_gate_vocab_class "ship/some-phase-nobody-has-written-yet"
  [ "$output" = "unknown" ]
  run cb_gate_vocab_class ""
  [ "$output" = "unknown" ]
}

@test "a live conductor at a widened gate reads needs-input immediately, not after the stall window" {
  setup_code_task; write_manifest "ship/3-gate" '5 minutes ago'   # FRESH manifest
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" run classify_code "$CTD"
  [ "$output" = "needs-input" ]                                    # was `running` for an hour
  write_manifest "ship/await-go-then-cb-pr-check" '5 minutes ago'
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" run classify_code "$CTD"
  [ "$output" = "needs-input" ]
}

@test "prefix-widening was rejected: ship/complete and ship/3-pull-request stay non-gates" {
  setup_code_task; write_manifest "ship/complete" '5 minutes ago'
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" run classify_code "$CTD"
  [ "$output" = "running" ]      # 791 of 1,600 live values — not a decision for Kyle
}

# --- the DECLARED gate field (conductor-gate-signal) -------------------------
# Everything above infers the gate from current_task. These cover the conductor
# declaring it instead: three distinguishable waits, a question that reaches the
# board, and the inference still standing for anything that declares nothing.
write_gated_manifest() { # write_gated_manifest <current_task> <gate> [question] [age] [gate_since]
  {
    printf -- '---\nname: code-slug\njira: EJA-99\ncurrent_task: %s\n' "$1"
    printf 'gate: %s\n' "$2"
    [ -n "${5:-}" ] && printf 'gate_since: %s\n' "$5"
    [ -n "${3:-}" ] && printf 'gate_question: %s\ngate_options: ["a", "b"]\n' "$3"
    printf -- '---\n'
  } > "$CWT/.ai/specs/code-slug/manifest.md"
  [ -n "${4:-}" ] && touch -d "$4" "$CWT/.ai/specs/code-slug/manifest.md" || true
}

@test "gate: needs-input + live session → needs-input" {
  setup_code_task; write_gated_manifest "ship/3-pull-request" needs-input "One PR or split?" '2 hours ago'
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" run classify_code "$CTD"
  [ "$output" = "needs-input" ]
}

@test "gate: needs-input + DEAD session → failed (the sentinel stays positive-only)" {
  setup_code_task; write_gated_manifest "ship/3-pull-request" needs-input "One PR or split?" '2 hours ago'
  CB_SESSION_LIST_CMD="printf ''" run classify_code "$CTD"
  [ "$output" = "failed" ]
}

@test "gate: needs-input on a PROGRESS current_task — the declaration beats the inference" {
  # ship/3-pull-request classifies as `progress`, so the heuristic would call this
  # running. This is the case the vocab widening structurally cannot reach: the
  # conductor is at a gate and its current_task correctly names the next step.
  setup_code_task; write_gated_manifest "ship/3-pull-request" needs-input "One PR or split?" '5 minutes ago'
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" run classify_code "$CTD"
  [ "$output" = "needs-input" ]
  [ "$(cb_gate_vocab_class ship/3-pull-request)" = "progress" ]
}

@test "gate: paused fresh → paused, regardless of liveness" {
  setup_code_task; write_gated_manifest "spec/2-investigate" paused "waiting on the form-tool mapping" '5 minutes ago'
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" run classify_code "$CTD"
  [ "$output" = "paused" ]
  CB_SESSION_LIST_CMD="printf ''" run classify_code "$CTD"
  [ "$output" = "paused" ]
}

@test "gate: paused aged past CB_PAUSE_RESURFACE_SECS → needs-input (the anti-rot clock)" {
  setup_code_task; write_gated_manifest "spec/2-investigate" paused "waiting on the form-tool mapping" '3 hours ago'
  CB_PAUSE_RESURFACE_SECS=3600 CB_SESSION_LIST_CMD="printf 'code-slug\n'" run classify_code "$CTD"
  [ "$output" = "needs-input" ]      # a forgotten pause must not be invisible forever
}

@test "the pause clock runs from gate_since, so rewriting the manifest cannot reset it" {
  # The rot this exists to kill. cb-brief tells agents that asking is not
  # finishing, so a conductor waiting on an external clear keeps working and keeps
  # advancing current_task — and Session End writes the manifest with the gate
  # deliberately left in place. On an mtime clock every one of those writes resets
  # the timer and the pause never resurfaces. gate_since is stamped once.
  setup_code_task
  write_gated_manifest "spec/2-investigate" paused "waiting on the form-tool mapping" '' \
    "$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%S+00:00)"
  # manifest mtime is NOW (just written) — only gate_since knows the real age
  CB_PAUSE_RESURFACE_SECS=3600 CB_SESSION_LIST_CMD="printf 'code-slug\n'" run classify_code "$CTD"
  [ "$output" = "needs-input" ]
  # and a genuinely fresh pause still holds
  write_gated_manifest "spec/2-investigate" paused "" '' \
    "$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%S+00:00)"
  CB_PAUSE_RESURFACE_SECS=3600 CB_SESSION_LIST_CMD="printf 'code-slug\n'" run classify_code "$CTD"
  [ "$output" = "paused" ]
}

@test "a malformed gate_since falls back to the manifest mtime, it does not crash or rot" {
  setup_code_task
  write_gated_manifest "spec/2-investigate" paused "" '3 hours ago' "not-a-timestamp"
  CB_PAUSE_RESURFACE_SECS=3600 CB_SESSION_LIST_CMD="printf 'code-slug\n'" run classify_code "$CTD"
  [ "$output" = "needs-input" ]
}

@test "gate: blocked under the remediation cap → blocked; at the cap → needs-relaunch" {
  setup_code_task; write_gated_manifest "ship/1-commit-and-pr" blocked "no push credentials" '2 hours ago'
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" run classify_code "$CTD"
  [ "$output" = "blocked" ]
  printf '2' > "$CTD/remediation-count"
  CB_REMEDIATE_CAP=2 CB_SESSION_LIST_CMD="printf 'code-slug\n'" run classify_code "$CTD"
  [ "$output" = "needs-relaunch" ]
}

# Fixture updated 2026-08-16 — `pr` added for the same Finding 3 reason as above.
# The assertion is unchanged and is the real subject: a SHIPPED task never re-opens
# a decision, so terminal still beats a declared gate.
@test "summary.md + pr + gate: set → still ready-for-review (terminal beats gate)" {
  setup_code_task; write_gated_manifest "ship/3-pull-request" needs-input "One PR or split?" '5 minutes ago'
  touch "$CTD/summary.md" "$CTD/pr"
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" run classify_code "$CTD"
  [ "$output" = "ready-for-review" ]
}

@test "merged pr.state + gate: set → still done (a shipped task never re-opens a decision)" {
  setup_code_task; write_gated_manifest "ship/3-pull-request" needs-input "One PR or split?" '5 minutes ago'
  printf 'MERGED' > "$CTD/pr.state"
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" run classify_code "$CTD"
  [ "$output" = "done" ]
}

@test "no gate: field + a gate-vocabulary current_task → still needs-input (fallback intact)" {
  setup_code_task; write_manifest "ship/awaiting-approval" '2 hours ago'
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" run classify_code "$CTD"
  [ "$output" = "needs-input" ]
}

@test "an unrecognised gate: value falls through to the inference, it does not guess" {
  # Same discipline as the vocab canary's `unknown`: a value the case arm has no
  # arm for must not be invented into a state. current_task decides.
  setup_code_task; write_gated_manifest "ship/complete" awaiting-kyle "" '5 minutes ago'
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" run classify_code "$CTD"
  [ "$output" = "running" ]
}

@test "task_gate returns gate_question when declared, current_task otherwise" {
  setup_code_task
  write_gated_manifest "ship/3-pull-request" needs-input "One PR or split the schema change out?" '5 minutes ago'
  run task_gate "$CTD"
  [ "$output" = "One PR or split the schema change out?" ]
  write_manifest "ship/3-pull-request" '5 minutes ago'
  run task_gate "$CTD"
  [ "$output" = "ship/3-pull-request" ]
}

@test "gate: alone (no gate_question) leaves task_gate on current_task" {
  setup_code_task; write_gated_manifest "ship/3-gate" needs-input "" '5 minutes ago'
  run task_gate "$CTD"
  [ "$output" = "ship/3-gate" ]
}

# =====================================================================
# THE PROJECTION PREDICATE — _decision_for / _has_gate_signal (2026-08-04)
# A resume pointer is not a question. `current_task` naming a finished phase
# (`ship/complete`) is a fixed string, so _decision_key hashed it into a decision
# whose source text will never change: every `resolved` was re-opened on the next
# tick and nothing could close it. cb-brief:66 already forbids conductors from
# recording a gate there; the projector must not read one there either.
# =====================================================================
@test "projection: a manifest with current_task and NO gate produces no decision" {
  setup_code_task; write_manifest "ship/complete" '2 hours ago'
  run _decision_for "$CTD" needs-input
  [ "$status" -eq 0 ]; [ -z "$output" ]
  run _has_gate_signal "$CTD"; [ "$status" -eq 1 ]
}
@test "projection: neither does the OTHER live phantom (a numbered ship step)" {
  setup_code_task; write_manifest "ship/1-land-and-followup-item" '2 hours ago'
  run _decision_for "$CTD" needs-input
  [ -z "$output" ]
}
# THE TRAP THIS AVOIDS. Emptying task_gate's current_task fallback looks like the
# same fix and is not: _decision_for falls through to _beacon_state_gate, so the
# phantom just re-sources itself from the status beacon. Measured 2026-08-04 —
# cksum("blocked|running") was open on 7 tasks for exactly that reason.
@test "projection: a code task with a status beacon still projects NOTHING" {
  setup_code_task; write_manifest "ship/complete" '2 hours ago'
  printf 'running: still going\n' > "$CTD/status"
  run _decision_for "$CTD" needs-input
  [ -z "$output" ]        # NOT keyed on "still going" either
}
@test "projection: a declared gate: DOES project (the sanctioned path)" {
  setup_code_task; write_gated_manifest "ship/3-gate" needs-input "" '5 minutes ago'
  run _decision_for "$CTD" needs-input
  [[ "$output" == *"ship/3-gate"* ]]
  run _has_gate_signal "$CTD"; [ "$status" -eq 0 ]
}
@test "projection: gate_question is what gets keyed when it is declared" {
  setup_code_task
  write_gated_manifest "ship/3-pull-request" needs-input "One PR or split the schema change out?" '5 minutes ago'
  run _decision_for "$CTD" needs-input
  [[ "$output" == *"One PR or split the schema change out?"* ]]
}
# The awaiting-approval sentinel is what the work-conductor skill shipping in the
# fleet (porch-skills ultron 1.1.0) actually prescribes — it does not mention
# `gate:` anywhere — so it stays a projecting gate signal. Dropping it would have
# silenced every approval pause the current conductor skill produces.
@test "projection: the awaiting-approval sentinel still projects (conductor protocol)" {
  setup_code_task; write_manifest "build/awaiting-approval" '2 hours ago'
  run _decision_for "$CTD" needs-input
  [[ "$output" == *"build/awaiting-approval"* ]]
  run _has_gate_signal "$CTD"; [ "$status" -eq 0 ]
}
@test "projection: UNKNOWN current_task vocabulary does not project (canary, not a guess)" {
  setup_code_task; write_manifest "thinking about it" '2 hours ago'
  run _decision_for "$CTD" needs-input
  [ -z "$output" ]
}
# Research is untouched: its gate is the beacon descriptor, which the worker
# writes deliberately (`blocked:` / `paused:`), not a resume pointer.
@test "projection: a RESEARCH task still projects from its beacon" {
  rtd="$BATS_TEST_TMPDIR/rtask"; mkdir -p "$rtd"
  printf 'blocked: upstream API 500s\n' > "$rtd/status"
  run _decision_for "$rtd" blocked
  [[ "$output" == *"upstream API 500s"* ]]
}

@test "live session, no manifest yet (conductor still booting) → running" {
  setup_code_task
  rm -rf "$CWT/.ai/specs/code-slug"
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" run classify_code "$CTD"
  [ "$output" = "running" ]
}

@test "dead session, no terminal artifact → failed" {
  setup_code_task; write_manifest "build/3-implement" '10 minutes ago'
  CB_SESSION_LIST_CMD="printf ''" run classify_code "$CTD"
  [ "$output" = "failed" ]
}

# MOVED failed → needs-input, 2026-08-16. This is row 2 of the Finding-1 table in
# 99 Meta/specs/2026-08-13-classify-r13-polarity-design, landed at 47078ba6 and
# approved kyle-2026-08-14-proceed. `unavailable` is what cb_session_alive returns
# when it COULD NOT DETERMINE liveness; a stale manifest on top of that is two
# absences stacked, not evidence the task died. cb-reap kills `failed` outright,
# skipping the unpushed-commit arithmetic, so the old expectation is the inversion
# R13 exists to stop. The fresh-manifest half is unchanged.
@test "session liveness unavailable degrades to the manifest-mtime rule (R13: never failed)" {
  setup_code_task; write_manifest "build/3-implement" '10 minutes ago'
  CB_SESSION_LIST_CMD="exit 127" run classify_code "$CTD"
  [ "$output" = "running" ]
  write_manifest "build/3-implement" '3 hours ago'
  CB_SESSION_LIST_CMD="exit 127" run classify_code "$CTD"
  [ "$output" = "needs-input" ]
  [ "$output" != "failed" ]             # R13: "I don't know" is never the destructive state
}

# --- blocked (T29/M6): live session + STALE manifest + spend-wedge pane ---

FIXPANES() { echo "$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/panes"; }

@test "wedge pane + stale manifest + live session → blocked" {
  setup_code_task; write_manifest "build/3-implement" '3 hours ago'
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" CB_PANE_CMD="cat '$(FIXPANES)/spend-wedge.txt'" \
    run classify_code "$CTD"
  [ "$output" = "blocked" ]
}

@test "wedge pane but sentinel present → needs-input beats blocked" {
  setup_code_task; write_manifest "build/awaiting-approval" '3 hours ago'
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" CB_PANE_CMD="cat '$(FIXPANES)/spend-wedge.txt'" \
    run classify_code "$CTD"
  [ "$output" = "needs-input" ]
}

@test "working pane + stale manifest + live session → needs-input (blocked needs the pattern)" {
  setup_code_task; write_manifest "build/3-implement" '3 hours ago'
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" CB_PANE_CMD="cat '$(FIXPANES)/working.txt'" \
    run classify_code "$CTD"
  [ "$output" != "blocked" ]      # still needs a genuine spend banner
  [ "$output" = "needs-input" ]   # but a LIVE session is never reaped on absent evidence
}

@test "wedge pane + FRESH manifest → running (pane only consulted when stale)" {
  setup_code_task; write_manifest "build/3-implement" '10 minutes ago'
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" CB_PANE_CMD="cat '$(FIXPANES)/spend-wedge.txt'" \
    run classify_code "$CTD"
  [ "$output" = "running" ]
}

@test "wedge pane + dead session → failed (blocked requires a live session)" {
  setup_code_task; write_manifest "build/3-implement" '3 hours ago'
  CB_SESSION_LIST_CMD="printf ''" CB_PANE_CMD="cat '$(FIXPANES)/spend-wedge.txt'" \
    run classify_code "$CTD"
  [ "$output" = "failed" ]
}

# --- narrowing (Kyle-approved 2026-07-16): classify_code's wedge trigger is now
# a GENUINE spend banner (CB_SPEND_PATTERN), not the idle chrome that
# CB_WEDGE_PATTERN also matched. Idle-chrome-only → failed (not blocked/
# needs-relaunch); a turn in progress → running (code parallel of (c)). This is
# what actually closes eja-3600's false needs-relaunch (cb-remediate (b) never
# runs on the needs-relaunch path).
#
# 2026-08-02: the terminal state on these two moved failed → needs-input. The
# eja-3600 property they exist to hold is "NOT blocked, NOT needs-relaunch", and
# both still assert it. `failed` was the wrong resting place because cb-reap:178
# kills a failed session without checking unpushed commits. ---
@test "narrow: idle-chrome pane (no spend banner) + stale + alive → needs-input (NOT blocked)" {
  setup_code_task; write_manifest "build/3-implement" '3 hours ago'
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" CB_PANE_CMD="cat '$(FIXPANES)/research-idle.txt'" \
    run classify_code "$CTD"
  [ "$output" != "blocked" ]
  [ "$output" = "needs-input" ]
}
@test "narrow: idle-chrome pane at cap (count>=2) → needs-input (NOT needs-relaunch — closes eja-3600)" {
  TD_C="$BATS_TEST_TMPDIR/idle-cap"; mkdir -p "$TD_C"
  CWT="$BATS_TEST_TMPDIR/wt-idle"; mkdir -p "$CWT/.ai/specs/idle-cap"
  printf 'kind=code\nworktree=%s\njira=EJA-9\nsession=idle-cap\ntarget=ultron\n' "$CWT" > "$TD_C/meta"
  printf -- '---\ncurrent_task: build/3-implement\n---\n' > "$CWT/.ai/specs/idle-cap/manifest.md"
  touch -d '3 hours ago' "$CWT/.ai/specs/idle-cap/manifest.md"
  printf '2' > "$TD_C/remediation-count"
  local fp; fp="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/panes"
  CB_SESSION_LIST_CMD="printf 'idle-cap\n'" CB_PANE_CMD="cat '$fp/research-idle.txt'" \
    run classify_code "$TD_C"
  [ "$output" != "needs-relaunch" ]
  [ "$output" = "needs-input" ]
}
@test "narrow: busy pane (esc to interrupt) + stale + alive → running (turn in progress, not a stall)" {
  setup_code_task; write_manifest "build/3-implement" '3 hours ago'
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" CB_PANE_CMD="cat '$(FIXPANES)/research-busy.txt'" \
    run classify_code "$CTD"
  [ "$output" = "running" ]
}
@test "narrow: genuine spend banner still → blocked (M6 wedge path intact)" {
  setup_code_task; write_manifest "build/3-implement" '3 hours ago'
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" CB_PANE_CMD="cat '$(FIXPANES)/spend-wedge.txt'" \
    run classify_code "$CTD"
  [ "$output" = "blocked" ]
}

# --- kind dispatch: one entry point for cb-watch / cb-board ---
@test "classify dispatches on meta kind=code" {
  setup_code_task; write_manifest "build/awaiting-approval"
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" run classify "$CTD"
  [ "$output" = "needs-input" ]
}

@test "classify without a meta file falls back to research" {
  printf -- '---\nstatus: complete\n---\n' > "$TD/report.md"; printf running > "$TD/status"
  run classify "$TD"
  [ "$output" = "ready-for-review" ]
}

# ops board-agent lane (2026-07-17): kind=ops is NOT code, so classify routes
# it through classify_research — same beacon + report.md contract. Locks the
# dispatch so a future change to classify() can't silently break the ops lane.
@test "classify routes kind=ops through the research path (terminal report → ready-for-review)" {
  printf 'kind=ops\nworkdir=/x\nsession=ops-slug\n' > "$TD/meta"
  printf -- '---\nstatus: complete\n---\n' > "$TD/report.md"; printf running > "$TD/status"
  run classify "$TD"
  [ "$output" = "ready-for-review" ]
}
@test "classify kind=ops with a fresh beacon + live window → running (research liveness)" {
  printf 'kind=ops\nworkdir=/x\nsession=ops-live\n' > "$TD/meta"
  printf running > "$TD/status"
  CB_WINDOW_LIST_CMD="printf '$(basename "$TD")\n'" run classify "$TD"
  [ "$output" = "running" ]
}

# =====================================================================
# R12 (step 12) — open-decision set: per-task append-only `decisions` log,
# folded to the open keyed set. Watcher-derived open, coordinator-marked
# resolve; a bare terminal flip never closes (anti-masking — see cb-watch.bats).
# =====================================================================
@test "R12: open then fold surfaces the open decision" {
  td="$BATS_TEST_TMPDIR/d1"; mkdir -p "$td"
  k=$(_decision_key needs-input "fsd semantics")
  _decision_open "$td" "$k" needs-input "fsd semantics"
  run open_decisions "$td"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fsd semantics"* ]]
}
@test "R12: resolve closes the decision (drops from fold)" {
  td="$BATS_TEST_TMPDIR/d2"; mkdir -p "$td"
  k=$(_decision_key needs-input "gate A")
  _decision_open "$td" "$k" needs-input "gate A"; _decision_resolve "$td" "$k"
  run open_decisions "$td"
  [ -z "$output" ]
}
@test "R12: same decision re-opened is idempotent (content key, no double-open)" {
  td="$BATS_TEST_TMPDIR/d3"; mkdir -p "$td"
  k=$(_decision_key needs-input "gate A")
  _decision_open "$td" "$k" needs-input "gate A"; _decision_open "$td" "$k" needs-input "gate A"
  run bash -c "grep -c ' open ' '$td/decisions'"
  [ "$output" -eq 1 ]
}
@test "R12: a genuinely different decision opens a second key" {
  td="$BATS_TEST_TMPDIR/d4"; mkdir -p "$td"
  _decision_open "$td" "$(_decision_key needs-input 'gate A')" needs-input "gate A"
  _decision_open "$td" "$(_decision_key blocked 'gate B')" blocked "gate B"
  run open_decisions "$td"
  [[ "$output" == *"gate A"* ]] && [[ "$output" == *"gate B"* ]]
}
# SUPERSEDED 2026-08-04. This used to assert the opposite — that re-opening a
# resolved content key opens it again — and that IS the bug: the watcher re-derives
# its key from source text (a manifest gate, a beacon descriptor) that may never
# change, so a resolve at 17:50 was re-opened at 17:51, on merged work, forever.
# A projected key with a `resolved` is now SEALED. Append-only is untouched:
# nothing is rewritten, and the seal is why there is no third line to rewrite.
@test "R12: resolve then re-open a PROJECTED content key stays closed (sealed)" {
  td="$BATS_TEST_TMPDIR/d5"; mkdir -p "$td"
  k=$(_decision_key needs-input "gate A")
  _decision_open "$td" "$k" needs-input "gate A"; _decision_resolve "$td" "$k"; _decision_open "$td" "$k" needs-input "gate A"
  run open_decisions "$td"; [ -z "$output" ]                     # STAYS closed
  # and the re-open was REFUSED at the writer, so the log does not grow two dead
  # lines per tick (~2,800/day at the 30s cadence) behind a fold that ignores them
  run bash -c "grep -c ' open \| resolved ' '$td/decisions'"; [ "$output" -eq 2 ]
  run bash -c "tail -1 '$td/decisions'"; [[ "$output" == *" resolved $k"* ]]
}
@test "R12 seal: a sealed key stays closed across many watch cycles" {
  td="$BATS_TEST_TMPDIR/d5b"; mkdir -p "$td"
  k=$(_decision_key needs-input "ship/complete")
  _decision_open "$td" "$k" needs-input "ship/complete"; _decision_resolve "$td" "$k"
  for _ in 1 2 3 4 5; do _decision_open "$td" "$k" needs-input "ship/complete"; done
  run open_decisions "$td"; [ -z "$output" ]
  run bash -c "wc -l < '$td/decisions'"; [ "$output" -eq 2 ]
  run _decision_sealed "$td" "$k"; [ "$status" -eq 0 ]
}
@test "R12 seal: a CHANGED gate text re-keys and DOES open (the seal is per-key)" {
  td="$BATS_TEST_TMPDIR/d5c"; mkdir -p "$td"
  k=$(_decision_key needs-input "gate A")
  _decision_open "$td" "$k" needs-input "gate A"; _decision_resolve "$td" "$k"
  _decision_open "$td" "$(_decision_key needs-input 'gate B')" needs-input "gate B"
  run open_decisions "$td"; [[ "$output" == *"gate B"* ]]; [[ "$output" != *"gate A"* ]]
}
# ANTI-MASKING (cb-board:20-32) — the seal is scoped to PROJECTED keys. A question
# a human typed via cb-ask must survive, and re-declaring is how a worker re-raises
# one after an answer. Sealing `declared` would trade the phantom for a real
# question silently vanishing, which is the worse bug.
@test "R12 seal: a DECLARED key re-declared after a resolve DOES re-open" {
  td="$BATS_TEST_TMPDIR/d5d"; mkdir -p "$td"
  k=$(_decision_key needs-input "which approach?")
  _decision_declare "$td" "$k" needs-input "which approach?"
  _decision_resolve "$td" "$k"
  run open_decisions "$td"; [ -z "$output" ]                     # answered
  _decision_declare "$td" "$k" needs-input "which approach?"     # asked again
  run open_decisions "$td"; [[ "$output" == *"which approach?"* ]]
  run _decision_sealed "$td" "$k"; [ "$status" -eq 1 ]           # never sealed
}
@test "R12 seal: a declared-then-resolved key is not sealed against the watcher either" {
  td="$BATS_TEST_TMPDIR/d5e"; mkdir -p "$td"
  k=$(_decision_key needs-input "same text")
  _decision_declare "$td" "$k" needs-input "same text"; _decision_resolve "$td" "$k"
  _decision_open "$td" "$k" needs-input "same text"              # the watcher's derived key collides
  run open_decisions "$td"; [[ "$output" == *"same text"* ]]
}
@test "R12: open_decisions on a task with no log is silent (no error)" {
  td="$BATS_TEST_TMPDIR/d6"; mkdir -p "$td"
  run open_decisions "$td"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

# --- M6: an at-cap, still-wedged task is needs-relaunch, not blocked ---
@test "M6: code task wedged with remediation-count >= cap → needs-relaunch" {
  TD_C="$BATS_TEST_TMPDIR/relaunch"; mkdir -p "$TD_C"
  CWT="$BATS_TEST_TMPDIR/wt"; mkdir -p "$CWT/.ai/specs/relaunch"
  printf 'kind=code\nworktree=%s\njira=EJA-9\nsession=relaunch\ntarget=ultron\n' "$CWT" > "$TD_C/meta"
  printf -- '---\ncurrent_task: build/3-implement\n---\n' > "$CWT/.ai/specs/relaunch/manifest.md"
  touch -d '3 hours ago' "$CWT/.ai/specs/relaunch/manifest.md"
  printf '2' > "$TD_C/remediation-count"
  local fixpanes; fixpanes="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/panes"
  CB_SESSION_LIST_CMD="printf 'relaunch\n'" CB_PANE_CMD="cat '$fixpanes/spend-wedge.txt'" \
    run classify_code "$TD_C"
  [ "$output" = "needs-relaunch" ]
}

@test "M6: same wedge under cap → still blocked" {
  TD_C="$BATS_TEST_TMPDIR/underCap"; mkdir -p "$TD_C"
  CWT="$BATS_TEST_TMPDIR/wt2"; mkdir -p "$CWT/.ai/specs/underCap"
  printf 'kind=code\nworktree=%s\njira=EJA-9\nsession=underCap\ntarget=ultron\n' "$CWT" > "$TD_C/meta"
  printf -- '---\ncurrent_task: build/3-implement\n---\n' > "$CWT/.ai/specs/underCap/manifest.md"
  touch -d '3 hours ago' "$CWT/.ai/specs/underCap/manifest.md"
  printf '1' > "$TD_C/remediation-count"
  local fixpanes; fixpanes="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/panes"
  CB_SESSION_LIST_CMD="printf 'underCap\n'" CB_PANE_CMD="cat '$fixpanes/spend-wedge.txt'" \
    run classify_code "$TD_C"
  [ "$output" = "blocked" ]
}

@test "M6: a malformed remediation-count is treated as 0 (→ blocked, no crash)" {
  TD_C="$BATS_TEST_TMPDIR/malformed"; mkdir -p "$TD_C"
  CWT="$BATS_TEST_TMPDIR/wtm"; mkdir -p "$CWT/.ai/specs/malformed"
  printf 'kind=code\nworktree=%s\njira=EJA-9\nsession=malformed\ntarget=ultron\n' "$CWT" > "$TD_C/meta"
  printf -- '---\ncurrent_task: build/3-implement\n---\n' > "$CWT/.ai/specs/malformed/manifest.md"
  touch -d '3 hours ago' "$CWT/.ai/specs/malformed/manifest.md"
  printf 'garbage\n' > "$TD_C/remediation-count"
  local fixpanes; fixpanes="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/panes"
  CB_SESSION_LIST_CMD="printf 'malformed\n'" CB_PANE_CMD="cat '$fixpanes/spend-wedge.txt'" \
    run classify_code "$TD_C"
  [ "$output" = "blocked" ]
}

# =====================================================================
# P1 — the `declared` verb (cb-ask's high-fidelity path). Folds exactly
# like `open` everywhere, but is distinguishable so the watcher can stand
# its heuristic key down instead of double-surfacing the same task.
# =====================================================================
@test "P1: a declared decision folds into the open set like an open one" {
  td="$BATS_TEST_TMPDIR/p1a"; mkdir -p "$td"
  k=$(_decision_key needs-input "which carrier first? [PRU|LFG]")
  _decision_declare "$td" "$k" needs-input "which carrier first? [PRU|LFG]"
  run open_decisions "$td"
  [ "$status" -eq 0 ]
  [[ "$output" == *"which carrier first? [PRU|LFG]"* ]]
  [[ "$output" == *"needs-input"* ]]
}
@test "P1: a declared decision is resolvable (resolve drops it from the fold)" {
  td="$BATS_TEST_TMPDIR/p1b"; mkdir -p "$td"
  k=$(_decision_key needs-input "gate D")
  _decision_declare "$td" "$k" needs-input "gate D"
  _decision_resolve "$td" "$k"
  run open_decisions "$td"
  [ -z "$output" ]
  run bash -c "grep -c ' resolved ' '$td/decisions'"
  [ "$output" -eq 1 ]
}
@test "P1: a declared decision appears in the AGED fold (cb-digest's only source)" {
  td="$BATS_TEST_TMPDIR/p1c"; mkdir -p "$td"
  k=$(_decision_key needs-input "gate D")
  _decision_declare "$td" "$k" needs-input "gate D"
  run _open_decisions_aged "$td"
  [[ "$output" == *"gate D"* ]]
  [[ "$output" == *"$k"* ]]
}
# --- unknown-verb audit ------------------------------------------------------
# Fixture is the literal DTCC pair from ~/.cerebro/tasks/dtcc-reject-transition-
# stranding/decisions. Kyle answered a live 8/10 go-live question in 48 minutes
# with the verb `answered`; the fold reads only open|declared|resolved, so the
# question sat on board.md as unanswered for four days with the answer two lines
# below it. By 2026-08-02 there were three such lines across the task set.
dtcc_fixture() {
  mkdir -p "$1"
  cat > "$1/decisions" <<'EOF'
2026-07-28T15:15:18+00:00 declared 1311205649 needs-input LIVE: 68 DTCC-rejected cases
2026-07-28T16:03:52+00:00 answered 1311205649 VERIFY-DEPLOY-SOURCE-FIRST (Kyle 2026-07-28): hold both actions. Do NOT repoint, do NOT touch the 68 DtccCase rows
EOF
}

@test "verb audit: the DTCC 'answered' line is surfaced, not silently skipped" {
  export CB_HOME="$BATS_TEST_TMPDIR/cbhome"; mkdir -p "$CB_HOME/beacons" "$CB_HOME/logs"
  td="$BATS_TEST_TMPDIR/dtcc"; dtcc_fixture "$td"
  run open_decisions "$td"
  [[ "$output" == *"unknown decision verb"* ]]
  [[ "$output" == *"answered"* ]]
  [[ "$output" == *"dtcc/decisions"* ]]
  grep -q 'cb-verb-audit' "$CB_HOME/logs/events"
}

@test "verb audit: WARNS but still computes — the declared key stays visible" {
  export CB_HOME="$BATS_TEST_TMPDIR/cbhome2"; mkdir -p "$CB_HOME/beacons" "$CB_HOME/logs"
  td="$BATS_TEST_TMPDIR/dtcc2"; dtcc_fixture "$td"
  # refusing to compute would blank the one surface carrying the real questions
  run bash -c "source scripts/cerebro/lib/paths.sh; source scripts/cerebro/lib/classify.sh; open_decisions '$td' 2>/dev/null"
  [[ "$output" == *"1311205649"* ]]
}

@test "verb audit: a clean log is silent and costs one grep" {
  export CB_HOME="$BATS_TEST_TMPDIR/cbhome3"; mkdir -p "$CB_HOME/beacons" "$CB_HOME/logs"
  td="$BATS_TEST_TMPDIR/clean"; mkdir -p "$td"
  k=$(_decision_key needs-input "gate Z")
  _decision_declare "$td" "$k" needs-input "gate Z"
  _decision_resolve "$td" "$k"                      # resolved ends at the key — no trailing space
  run open_decisions "$td"
  [[ "$output" != *"unknown decision verb"* ]]
  [ ! -f "$CB_HOME/logs/events" ]
}

@test "verb audit: dedups across reads, and re-warns when a NEW bad line lands" {
  export CB_HOME="$BATS_TEST_TMPDIR/cbhome4"; mkdir -p "$CB_HOME/beacons" "$CB_HOME/logs"
  td="$BATS_TEST_TMPDIR/dtcc4"; dtcc_fixture "$td"
  run bash -c "source scripts/cerebro/lib/paths.sh; source scripts/cerebro/lib/classify.sh
    open_decisions '$td' >/dev/null 2>&1; open_decisions '$td' >/dev/null 2>&1
    grep -c cb-verb-audit '$CB_HOME/logs/events'"
  [ "$output" -eq 1 ]                                # a standing bad line warns once
  printf '2026-08-02T02:22:10+00:00 answered 489131747 HOLD #2590\n' >> "$td/decisions"
  run bash -c "source scripts/cerebro/lib/paths.sh; source scripts/cerebro/lib/classify.sh
    open_decisions '$td' >/dev/null 2>&1
    grep -c cb-verb-audit '$CB_HOME/logs/events'"
  [ "$output" -eq 2 ]                                # a NEW one is not swallowed by the dedup
}

@test "verb audit: the aged fold (cb-digest's source) surfaces it too" {
  export CB_HOME="$BATS_TEST_TMPDIR/cbhome5"; mkdir -p "$CB_HOME/beacons" "$CB_HOME/logs"
  td="$BATS_TEST_TMPDIR/dtcc5"; dtcc_fixture "$td"
  run _open_decisions_aged "$td"
  [[ "$output" == *"unknown decision verb"* ]]
}

@test "verb audit: a shipped task still gets audited (terminal short-circuit)" {
  export CB_HOME="$BATS_TEST_TMPDIR/cbhome6"; mkdir -p "$CB_HOME/beacons" "$CB_HOME/logs"
  td="$BATS_TEST_TMPDIR/dtcc6"; dtcc_fixture "$td"; touch "$td/done"   # hard terminal
  run open_decisions_live "$td"
  [[ "$output" == *"unknown decision verb"* ]]
}

# --- the aged fold folds the LIVE set (cb-digest's only source) --------------
# It used to fold the raw set: the digest read "Supervisor escalate (83)" where
# cb-board read ~6, so ~92% of it was settled heuristic suspicion and nobody
# read it. Measured on the live task set 2026-08-02: 85 raw -> 12 live.

@test "aged fold: a settled heuristic key is excluded, a declared one survives" {
  td="$BATS_TEST_TMPDIR/aged1"; mkdir -p "$td"
  hk=$(_decision_key blocked "watcher suspicion")
  _decision_open "$td" "$hk" blocked "watcher suspicion"
  dk=$(_decision_key needs-input "a question Kyle typed")
  _decision_declare "$td" "$dk" needs-input "a question Kyle typed"
  run _open_decisions_aged "$td"                       # no terminal yet — both open
  [[ "$output" == *"$hk"* ]]
  [[ "$output" == *"$dk"* ]]
  printf -- '---\nstatus: complete\n---\n' > "$td/report.md"   # soft terminal
  run _open_decisions_aged "$td"
  [[ "$output" != *"$hk"* ]]                           # suspicion falsified by the report
  [[ "$output" == *"$dk"* ]]                           # a typed question is not settled by one
}

@test "aged fold: a hard terminal empties it" {
  td="$BATS_TEST_TMPDIR/aged2"; mkdir -p "$td"
  dk=$(_decision_key needs-input "gate H")
  _decision_declare "$td" "$dk" needs-input "gate H"
  touch "$td/done"
  run _open_decisions_aged "$td"
  [ -z "$output" ]
}

@test "aged fold: still carries the open line's timestamp, last-open wins" {
  td="$BATS_TEST_TMPDIR/aged3"; mkdir -p "$td"
  dk=$(_decision_key needs-input "gate T")
  printf '2026-07-01T00:00:00+00:00 declared %s needs-input gate T\n' "$dk" >> "$td/decisions"
  printf '2026-07-02T00:00:00+00:00 declared %s needs-input gate T\n' "$dk" >> "$td/decisions"
  run _open_decisions_aged "$td"
  [[ "$output" == 2026-07-02* ]]
}

@test "P1: re-declaring the same content key is idempotent (R18)" {
  td="$BATS_TEST_TMPDIR/p1d"; mkdir -p "$td"
  k=$(_decision_key needs-input "gate D")
  _decision_declare "$td" "$k" needs-input "gate D"
  _decision_declare "$td" "$k" needs-input "gate D"
  run bash -c "grep -c ' declared ' '$td/decisions'"
  [ "$output" -eq 1 ]
}
@test "P1: _has_declared_open is true while declared, false once resolved, false for heuristic-only" {
  td="$BATS_TEST_TMPDIR/p1e"; mkdir -p "$td"
  run _has_declared_open "$td"; [ "$status" -ne 0 ]          # no log at all
  _decision_open "$td" "$(_decision_key needs-input 'heuristic gate')" needs-input "heuristic gate"
  run _has_declared_open "$td"; [ "$status" -ne 0 ]          # heuristic only
  k=$(_decision_key needs-input "declared gate")
  _decision_declare "$td" "$k" needs-input "declared gate"
  run _has_declared_open "$td"; [ "$status" -eq 0 ]
  _decision_resolve "$td" "$k"
  run _has_declared_open "$td"; [ "$status" -ne 0 ]
}
@test "P1: _open_heuristic_keys lists open watcher keys only, never declared ones" {
  td="$BATS_TEST_TMPDIR/p1f"; mkdir -p "$td"
  hk=$(_decision_key needs-input "manifest gate"); dk=$(_decision_key needs-input "worker question")
  _decision_open "$td" "$hk" needs-input "manifest gate"
  _decision_declare "$td" "$dk" needs-input "worker question"
  run _open_heuristic_keys "$td"
  [ "$output" = "$hk" ]
}
@test "P1: a resolved heuristic key drops out of _open_heuristic_keys" {
  td="$BATS_TEST_TMPDIR/p1g"; mkdir -p "$td"
  hk=$(_decision_key needs-input "manifest gate")
  _decision_open "$td" "$hk" needs-input "manifest gate"
  _decision_resolve "$td" "$hk"
  run _open_heuristic_keys "$td"
  [ -z "$output" ]
}
@test "P1: _open_heuristic_keys on a task with no log is silent (no error)" {
  td="$BATS_TEST_TMPDIR/p1h"; mkdir -p "$td"
  run _open_heuristic_keys "$td"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

# --- session gone + a DECLARED question: the cb-ask strand (2026-07-30) ------
# A code conductor lives in a dedicated tmux session whose only window is the
# agent, so calling cb-ask (declare, end turn, exit) destroys the session. That
# polite exit used to classify as `failed`, burying a live question. A still-open
# `declared` key is positive evidence the worker ASKED rather than crashed.

declare_decision() { # declare_decision <key> <gate>
  printf '2026-07-30T12:00:00+00:00 declared %s needs-input %s\n' "$1" "$2" >> "$CTD/decisions"
}
resolve_decision() { # resolve_decision <key>
  printf '2026-07-30T12:05:00+00:00 resolved %s\n' "$1" >> "$CTD/decisions"
}

@test "session gone + open DECLARED decision → needs-input (not failed)" {
  setup_code_task; write_manifest "spec/2-investigate" '2 hours ago'
  declare_decision 4242 "Descope the seam or keep it?"
  CB_SESSION_LIST_CMD="printf ''" run classify_code "$CTD"
  [ "$output" = "needs-input" ]
}

@test "session gone + declared decision already RESOLVED → failed" {
  setup_code_task; write_manifest "spec/2-investigate" '2 hours ago'
  declare_decision 4242 "Descope the seam or keep it?"
  resolve_decision 4242
  CB_SESSION_LIST_CMD="printf ''" run classify_code "$CTD"
  [ "$output" = "failed" ]
}

@test "session gone + only a HEURISTIC open (no cb-ask) → failed" {
  setup_code_task; write_manifest "spec/2-investigate" '2 hours ago'
  printf '2026-07-30T12:00:00+00:00 open 7777 blocked watcher-derived\n' >> "$CTD/decisions"
  CB_SESSION_LIST_CMD="printf ''" run classify_code "$CTD"
  [ "$output" = "failed" ]
}

@test "session gone, no decisions log at all → failed (crash path unchanged)" {
  setup_code_task; write_manifest "spec/2-investigate" '2 hours ago'
  CB_SESSION_LIST_CMD="printf ''" run classify_code "$CTD"
  [ "$output" = "failed" ]
}

# --- finding-18 (spec item 18): an interactive Claude Code menu is the agent
# asking the HUMAN directly — NOT a conductor phase gate (current_task is not
# */awaiting-approval), so it must never fall through to the wedge/failed
# heuristics. A live session parked at a menu → needs-input, ALWAYS. Placed at
# the top of the alive branch so it beats wedge/oom AND _relaunch_or_blocked
# (the M6 needs-relaunch mislabel: a human-gated-idle task is not a dead wedge).
@test "finding-18: menu footer + live session + STALE manifest → needs-input (not failed/blocked)" {
  setup_code_task; write_manifest "build/3-implement" '3 hours ago'
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" CB_PANE_CMD="cat '$(FIXPANES)/menu.txt'" \
    run classify_code "$CTD"
  [ "$output" = "needs-input" ]
}

@test "finding-18: menu footer + live session + FRESH manifest → needs-input (whenever alive, not running)" {
  setup_code_task; write_manifest "build/3-implement" '10 minutes ago'
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" CB_PANE_CMD="cat '$(FIXPANES)/menu.txt'" \
    run classify_code "$CTD"
  [ "$output" = "needs-input" ]
}

@test "finding-18: ❯ option list alone (no footer) also → needs-input" {
  setup_code_task; write_manifest "build/3-implement" '3 hours ago'
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" CB_PANE_CMD="cat '$(FIXPANES)/menu-options.txt'" \
    run classify_code "$CTD"
  [ "$output" = "needs-input" ]
}

# The other side of finding-18: Claude Code's OWN prompts render as `❯ N.` lists and
# are not the agent asking anything. Measured 2026-08-14 22:01 MT on the live
# `deterministic-report-landing` conductor — classified needs-input while its pane read
# "Waiting for 1 background agent to finish" and a subagent had run 16 minutes. Only the
# harness's "Set up auto mode" prompt matched. Chrome is stripped before the menu test,
# so a REAL agent menu appearing alongside it still fires (next test).
@test "finding-18: harness auto-mode prompt is NOT a gate → running, not needs-input" {
  setup_code_task; write_manifest "work/3-land-trigger" '10 minutes ago'
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" CB_PANE_CMD="cat '$(FIXPANES)/menu-harness-chrome.txt'" \
    run classify_code "$CTD"
  [ "$output" != "needs-input" ]
}

@test "finding-18: a REAL menu alongside harness chrome still → needs-input" {
  setup_code_task; write_manifest "build/3-implement" '3 hours ago'
  cat "$(FIXPANES)/menu-harness-chrome.txt" "$(FIXPANES)/menu.txt" > "$BATS_TEST_TMPDIR/both.txt"
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" CB_PANE_CMD="cat '$BATS_TEST_TMPDIR/both.txt'" \
    run classify_code "$CTD"
  [ "$output" = "needs-input" ]
}

@test "finding-18: menu + exhausted remediation-count → needs-input (NOT needs-relaunch)" {
  TD_C="$BATS_TEST_TMPDIR/menu-atcap"; mkdir -p "$TD_C"
  CWT="$BATS_TEST_TMPDIR/wt-menu"; mkdir -p "$CWT/.ai/specs/menu-atcap"
  printf 'kind=code\nworktree=%s\njira=EJA-9\nsession=menu-atcap\ntarget=ultron\n' "$CWT" > "$TD_C/meta"
  printf -- '---\ncurrent_task: build/3-implement\n---\n' > "$CWT/.ai/specs/menu-atcap/manifest.md"
  touch -d '3 hours ago' "$CWT/.ai/specs/menu-atcap/manifest.md"
  printf '2' > "$TD_C/remediation-count"
  local fixpanes; fixpanes="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/panes"
  CB_SESSION_LIST_CMD="printf 'menu-atcap\n'" CB_PANE_CMD="cat '$fixpanes/menu.txt'" \
    run classify_code "$TD_C"
  [ "$output" = "needs-input" ]
}

@test "finding-18: menu + DEAD session → failed (menu is a live-session signal only)" {
  setup_code_task; write_manifest "build/3-implement" '3 hours ago'
  CB_SESSION_LIST_CMD="printf ''" CB_PANE_CMD="cat '$(FIXPANES)/menu.txt'" \
    run classify_code "$CTD"
  [ "$output" = "failed" ]
}

# =============================================================================
# Supersession — the forward-only defect (2026-08-03)
# =============================================================================
# Supersession was recorded on the SUCCESSOR and never on the predecessor.
# Agents wrote "SUPERSEDES 1493386392" into the decision text; nothing read it,
# so both keys stayed open and Kyle was handed the same decision three times in
# one evening (eja-3881, 2026-08-02). Two verbs fix it: `supersedes` (intra-task,
# a real close) and `settled-by` (cross-task, board membership only).

SUP_TD() { printf '%s' "$BATS_TEST_TMPDIR/sup"; }
sup_setup() { export CB_HOME="$BATS_TEST_TMPDIR/cbh-sup"; mkdir -p "$CB_HOME/tasks" "$(SUP_TD)"; }

# --- supersede-in-place: a real close, visible to EVERY fold -----------------

@test "supersession: the successor closes the predecessor with no hand-written resolved line" {
  sup_setup; td="$(SUP_TD)"
  old=$(_decision_key needs-input "first framing"); _decision_declare "$td" "$old" needs-input "first framing"
  new=$(_decision_key needs-input "sharper framing"); _decision_declare "$td" "$new" needs-input "sharper framing"
  _decision_supersede "$td" "$new" "$old"
  ! grep -q ' resolved ' "$td/decisions"          # the DoD: no hand-written resolved
  run _is_open "$td" "$old"; [ "$status" -ne 0 ]
  run _is_open "$td" "$new"; [ "$status" -eq 0 ]
}

# The split-brain guard. Five folds used to compute openness independently; a
# verb taught to some but not all renders a key closed on the board while cb-ask
# refuses to re-declare it and _decision_resolve keeps appending dead lines.
@test "supersession: the closed key is gone from EVERY fold, not just the board" {
  sup_setup; td="$(SUP_TD)"
  old=$(_decision_key needs-input "old q"); _decision_declare "$td" "$old" needs-input "old q"
  new=$(_decision_key needs-input "new q"); _decision_declare "$td" "$new" needs-input "new q"
  _decision_supersede "$td" "$new" "$old"
  run open_decisions "$td";       [[ "$output" != *"$old"* ]]; [[ "$output" == *"$new"* ]]
  run open_decisions_live "$td";  [[ "$output" != *"$old"* ]]; [[ "$output" == *"$new"* ]]
  run _open_decisions_aged "$td"; [[ "$output" != *"$old"* ]]; [[ "$output" == *"$new"* ]]
  run _open_heuristic_keys "$td"; [[ "$output" != *"$old"* ]]
  run _is_open "$td" "$old";      [ "$status" -ne 0 ]
}

@test "supersession: superseding the ONLY declared key clears _has_declared_open" {
  sup_setup; td="$(SUP_TD)"
  old=$(_decision_key needs-input "only q"); _decision_declare "$td" "$old" needs-input "only q"
  run _has_declared_open "$td"; [ "$status" -eq 0 ]
  new=$(_decision_key needs-input "replacement"); _decision_declare "$td" "$new" needs-input "replacement"
  _decision_supersede "$td" "$new" "$old"
  run _has_declared_open "$td"; [ "$status" -eq 0 ]   # the replacement is still declared+open
  _decision_resolve "$td" "$new"
  run _has_declared_open "$td"; [ "$status" -ne 0 ]
}

# Applied in LOG ORDER, never in an END block: the log is append-only, so a key
# that is superseded and then genuinely re-declared must re-open.
@test "supersession: a superseded key that is later re-declared re-opens" {
  sup_setup; td="$(SUP_TD)"
  old=$(_decision_key needs-input "recurring q"); _decision_declare "$td" "$old" needs-input "recurring q"
  new=$(_decision_key needs-input "interim q"); _decision_declare "$td" "$new" needs-input "interim q"
  _decision_supersede "$td" "$new" "$old"
  run _is_open "$td" "$old"; [ "$status" -ne 0 ]
  _decision_declare "$td" "$old" needs-input "recurring q"     # asked again, for real
  run _is_open "$td" "$old"; [ "$status" -eq 0 ]
}

# --- ANTI-MASKING: the property the brief says is most likely to be broken ----
# cb-board:20-32 is deliberate — a human-authored `declared` question survives
# everything short of the work shipping. A watcher heuristic is a SUSPICION
# nobody typed, so it must never be able to retire one.

@test "anti-masking: a heuristic open line CANNOT supersede a declared question" {
  sup_setup; td="$(SUP_TD)"
  dk=$(_decision_key needs-input "a question Kyle must answer")
  _decision_declare "$td" "$dk" needs-input "a question Kyle must answer"
  hk=$(_decision_key blocked "watcher wedge guess")
  _decision_open "$td" "$hk" blocked "watcher wedge guess"
  # forge the line the writer would never emit — the FOLD must reject it
  printf '%s supersedes %s %s\n' "$(_decision_ts)" "$hk" "$dk" >> "$td/decisions"
  run _is_open "$td" "$dk"; [ "$status" -eq 0 ]                 # survives
  run open_decisions_live "$td"; [[ "$output" == *"a question Kyle must answer"* ]]
}

@test "anti-masking: a declared question CAN supersede a heuristic suspicion" {
  sup_setup; td="$(SUP_TD)"
  hk=$(_decision_key blocked "watcher wedge guess"); _decision_open "$td" "$hk" blocked "watcher wedge guess"
  dk=$(_decision_key needs-input "the real question"); _decision_declare "$td" "$dk" needs-input "the real question"
  _decision_supersede "$td" "$dk" "$hk"
  run _is_open "$td" "$hk"; [ "$status" -ne 0 ]
  run _is_open "$td" "$dk"; [ "$status" -eq 0 ]
}

# Settlement must be EVIDENCE that answers the question, never a state bucket.
# A fix that closed decisions by reading task status would pass a naive test.
@test "anti-masking: no state bucket settles a decision — only evidence does" {
  sup_setup; td="$(SUP_TD)"
  dk=$(_decision_key needs-input "still unanswered"); _decision_declare "$td" "$dk" needs-input "still unanswered"
  # every non-terminal signal a classifier might mistake for settlement
  printf 'blocked: wedged hard\n' > "$td/status"
  printf 'kind=code\nsession=nope\n' > "$td/meta"
  printf 'OPEN\n' > "$td/pr.state"
  printf '9\n' > "$td/remediation-count"
  run open_decisions_live "$td"; [[ "$output" == *"still unanswered"* ]]
  # and a SOFT terminal (a finished report) is the normal companion of an
  # unanswered question — classify.sh:171 — so it settles nothing either
  printf -- '---\nstatus: complete\n---\n' > "$td/report.md"
  run open_decisions_live "$td"; [[ "$output" == *"still unanswered"* ]]
}

# --- prose fallback: for logs already on disk, and backwards-only ------------

@test "prose fallback: the literal eja-3881 SUPERSEDES line closes its predecessor" {
  sup_setup; td="$(SUP_TD)"
  cat > "$td/decisions" <<'EOF'
2026-08-02T23:02:19+00:00 declared 1493386392 needs-input Which document must carry the 35% justification?
2026-08-02T23:11:09+00:00 declared 1004831090 needs-input SUPERSEDES 1493386392 — sharper framing after reading jira-context. Two documents were conflated and that IS the ticket.
EOF
  run _is_open "$td" 1493386392; [ "$status" -ne 0 ]
  run _is_open "$td" 1004831090; [ "$status" -eq 0 ]
  run open_decisions_live "$td"; [[ "$output" != *"Which document must carry"* ]]
}

@test "prose fallback: SUPERSEDES naming a key that does not exist is a no-op" {
  sup_setup; td="$(SUP_TD)"
  k=$(_decision_key needs-input "SUPERSEDES 12345 — a key from nowhere")
  _decision_declare "$td" "$k" needs-input "SUPERSEDES 12345 — a key from nowhere"
  run _is_open "$td" "$k"; [ "$status" -eq 0 ]
  run open_decisions "$td"; [[ "$output" == *"$k"* ]]
  run open_decisions "$td"; [[ "$output" != *"unknown decision verb"* ]]
}

@test "prose fallback: supersession reaches BACKWARDS only, never forwards" {
  sup_setup; td="$(SUP_TD)"
  later=$(_decision_key needs-input "asked afterwards")
  printf '%s declared 111 needs-input SUPERSEDES %s — cannot close the future\n' "$(_decision_ts)" "$later" >> "$td/decisions"
  _decision_declare "$td" "$later" needs-input "asked afterwards"
  run _is_open "$td" "$later"; [ "$status" -eq 0 ]
}

@test "prose fallback: a heuristic open line prose cannot close a declared key" {
  sup_setup; td="$(SUP_TD)"
  dk=$(_decision_key needs-input "human question"); _decision_declare "$td" "$dk" needs-input "human question"
  printf '%s open 222 blocked SUPERSEDES %s — watcher prose must not count\n' "$(_decision_ts)" "$dk" >> "$td/decisions"
  run _is_open "$td" "$dk"; [ "$status" -eq 0 ]
}

# --- cross-task settlement (settled-by) --------------------------------------
# comms-lookback-distillation asked "build ns-comms-sweep standalone, fold, or
# hold?"; Kyle answered "standalone"; the work shipped under build-ns-comms-sweep;
# the asking task had no terminal evidence of its OWN, so the digest kept asking.

settle_pair() {   # $1 = settler terminal: none|soft|hard
  sup_setup
  ASK="$CB_HOME/tasks/comms-lookback-distillation"; BY="$CB_HOME/tasks/build-ns-comms-sweep"
  mkdir -p "$ASK" "$BY"
  K=$(_decision_key needs-input "build ns-comms-sweep standalone, fold, or hold?")
  _decision_declare "$ASK" "$K" needs-input "build ns-comms-sweep standalone, fold, or hold?"
  case "$1" in
    soft) printf -- '---\nstatus: complete\n---\n' > "$BY/report.md";;
    hard) touch "$BY/done";;
  esac
}

@test "settlement: shipping the ANSWERING task closes the asking task's decision" {
  settle_pair hard
  _decision_settled_by "$ASK" "$K" build-ns-comms-sweep
  run open_decisions_live "$ASK"; [ -z "$output" ]
}

@test "settlement: a pointer at a task that has NOT shipped keeps the question open" {
  settle_pair none
  _decision_settled_by "$ASK" "$K" build-ns-comms-sweep
  run open_decisions_live "$ASK"; [[ "$output" == *"standalone, fold, or hold"* ]]
}

# _task_terminal returns `soft` for a terminal report.md, and classify.sh:171 is
# explicit that a finished report is the NORMAL companion of an unanswered
# question. Honoring settled-by on soft would retire live questions wholesale.
@test "settlement: the settler must be HARD — a finished report settles nothing" {
  settle_pair soft
  _decision_settled_by "$ASK" "$K" build-ns-comms-sweep
  run open_decisions_live "$ASK"; [[ "$output" == *"standalone, fold, or hold"* ]]
}

# The :116 contract — the raw fold stays raw. If a settled key vanished from it,
# a later human answer via cb-send would write no `resolved` and the audit record
# of that answer would be lost.
@test "settlement: the raw fold still sees a settled key (cb-watch/cb-send must)" {
  settle_pair hard
  _decision_settled_by "$ASK" "$K" build-ns-comms-sweep
  run open_decisions "$ASK";     [[ "$output" == *"$K"* ]]
  run _is_open "$ASK" "$K";      [ "$status" -eq 0 ]
  run open_decisions_live "$ASK"; [ -z "$output" ]
}

@test "settlement: a pointer at a slug with no task dir at all settles nothing" {
  settle_pair none
  _decision_settled_by "$ASK" "$K" a-task-that-never-existed
  run open_decisions_live "$ASK"; [[ "$output" == *"standalone, fold, or hold"* ]]
}

@test "settlement: cb-digest's aged fold honors settlement too" {
  settle_pair hard
  _decision_settled_by "$ASK" "$K" build-ns-comms-sweep
  run _open_decisions_aged "$ASK"; [ -z "$output" ]
}

# --- the verb audit must not call the new verbs unreadable -------------------

@test "verb audit: supersedes and settled-by are READABLE, not flagged" {
  sup_setup; export CB_HOME="$BATS_TEST_TMPDIR/cbh-audit"; mkdir -p "$CB_HOME/beacons" "$CB_HOME/logs" "$CB_HOME/tasks"
  td="$BATS_TEST_TMPDIR/audit-td"; mkdir -p "$td"
  a=$(_decision_key needs-input "q one"); _decision_declare "$td" "$a" needs-input "q one"
  b=$(_decision_key needs-input "q two"); _decision_declare "$td" "$b" needs-input "q two"
  _decision_supersede "$td" "$b" "$a"
  _decision_settled_by "$td" "$b" some-other-task
  run open_decisions "$td"
  [[ "$output" != *"unknown decision verb"* ]]
  [ ! -f "$CB_HOME/logs/events" ]
}

# --- research/ops lane: DECLARED-only decisions (regression, 2026-08-06) ------
# A research task has NO meta file at all (cb-start --research writes brief.md,
# launch.sh, status, xman — no meta), so the `kind = code` suppression in
# _decision_for never fired for it. Combined with classify_research INFERRING
# `blocked` from a stale beacon + quiet pane, a task that was merely working
# quietly had its PROGRESS LINE opened as a decision. Live instance:
# outstanding-from-2026-08-05, key 3650643150, question text
# "orienting — reading daily notes, meetings, hot.md, unlanded reports".
setup_research_task() { # $RTD, deliberately WITHOUT a meta file
  RTD="$BATS_TEST_TMPDIR/tasks/research-slug"; mkdir -p "$RTD"
  printf -- '---\ntask: research-slug\ntype: research\n---\n# Objective\n' > "$RTD/brief.md"
}

@test "research: a running beacon projects NO decision (the 2026-08-06 phantom)" {
  setup_research_task
  printf 'running\nrunning: orienting — reading daily notes, meetings, hot.md\n' > "$RTD/status"
  run _decision_for "$RTD" blocked
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "research: no meta file — the kind=code guard cannot be what suppresses it" {
  setup_research_task
  printf 'running: still working\n' > "$RTD/status"
  [ ! -f "$RTD/meta" ]
  run _meta_field "$RTD" kind
  [ -z "$output" ]
  run _decision_for "$RTD" blocked
  [ -z "$output" ]
}

@test "research: a WORKER-DECLARED blocked beacon still projects a decision" {
  setup_research_task
  printf 'running: orienting\nblocked: which domain does rca-ARCH-5 belong to?\n' > "$RTD/status"
  run _decision_for "$RTD" blocked
  [ -n "$output" ]
  [[ "$output" == *"which domain does rca-ARCH-5 belong to?"* ]]
}

@test "research: a declared paused beacon still projects (resurface path intact)" {
  setup_research_task
  printf 'paused: waiting on the 16:37 monitor window\n' > "$RTD/status"
  run _decision_for "$RTD" needs-input
  [ -n "$output" ]
}

@test "research: an absent beacon projects nothing rather than an empty question" {
  setup_research_task
  run _decision_for "$RTD" blocked
  [ -z "$output" ]
}

# =====================================================================
# R13 polarity — the three absence-of-evidence sites + Findings 2 and 3.
# Spec: 99 Meta/specs/2026-08-13-classify-r13-polarity-design (Kyle, 2026-08-14).
#
# The invariant these pin: `failed` is the ONE state cb-reap acts on
# destructively (cb-reap:178 kills the session outright, skipping the
# unpushed-commit arithmetic, because it assumes `failed` means positive
# terminal evidence). So no branch may reach it from an ABSENCE of evidence.
# Each test below asserts != failed explicitly, so a future refactor that
# reintroduces the inversion fails loudly rather than quietly.
# =====================================================================

@test "R13/code: unavailable liveness + stale manifest → needs-input, NEVER failed" {
  setup_code_task; write_manifest "build/2" '2 hours ago'
  CB_SESSION_LIST_CMD="exit 127" run classify_code "$CTD"
  [ "$output" = "needs-input" ]
  [ "$output" != "failed" ]
}

@test "R13/code: unavailable liveness + FRESH manifest → running (unchanged)" {
  setup_code_task; write_manifest "build/2"
  CB_SESSION_LIST_CMD="exit 127" run classify_code "$CTD"
  [ "$output" = "running" ]
}

@test "R13: positive evidence still reaches failed — DECLINED PR" {
  setup_code_task; printf 'DECLINED' > "$CTD/pr.state"
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" run classify_code "$CTD"
  [ "$output" = "failed" ]
}

@test "R13: positive evidence still reaches failed — report.md status: failed" {
  printf -- '---\nstatus: failed\n---\n' > "$TD/report.md"
  CB_WINDOW_LIST_CMD="printf 'task\n'" run classify_research "$TD"
  [ "$output" = "failed" ]
}

# --- Finding 2: agent-declared `blocked` gets the resurface clock `paused` has ---

@test "F2: declared blocked, beacon fresh, pane quiet → blocked (declaration still wins)" {
  printf blocked > "$TD/status"; touch -d '5 minutes ago' "$TD/status"
  CB_PANE_CMD="printf ''" run classify_research "$TD"
  [ "$output" = "blocked" ]
}

@test "F2: declared blocked, beacon past resurface threshold → needs-input" {
  printf blocked > "$TD/status"; touch -d '2 hours ago' "$TD/status"   # > CB_PAUSE_RESURFACE_SECS (3600)
  CB_PANE_CMD="printf ''" run classify_research "$TD"
  [ "$output" = "needs-input" ]
}

@test "F2: declared blocked but the pane is demonstrably busy → needs-input (the 08-13 case)" {
  # uat-cancellation-fund-release-backfill read `blocked` while its pane showed
  # "Crafting… (7m 39s)" over a live Kusto join. A stale declaration must not
  # outrank visible work.
  printf blocked > "$TD/status"; touch -d '5 minutes ago' "$TD/status"
  CB_PANE_CMD="printf 'Crafting… (7m 39s · esc to interrupt)\n'" run classify_research "$TD"
  [ "$output" = "needs-input" ]
}

# --- Finding 3: summary.md alone no longer short-circuits to ready-for-review ---

@test "F3: summary.md WITH pr → ready-for-review (unchanged happy path)" {
  setup_code_task; printf 'x' > "$CTD/summary.md"; printf 'x' > "$CTD/pr"
  CB_SESSION_LIST_CMD="printf ''" run classify_code "$CTD"
  [ "$output" = "ready-for-review" ]
}

@test "F3: summary.md WITHOUT pr does NOT claim ready-for-review — unshipped work must fall through" {
  setup_code_task; write_manifest "build/2" '2 hours ago'; printf 'x' > "$CTD/summary.md"
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" run classify_code "$CTD"
  [ "$output" != "ready-for-review" ]
}
