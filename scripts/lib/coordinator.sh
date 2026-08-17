# lib/coordinator.sh — guarded delivery into the SHARED coordinator tmux session
# (the pane Kyle ALSO types into). R17. Two hazards a bare `send-keys` opens:
#   1. a dead/unreadable pane (the coordinator claude crashed to its login shell,
#      before cerebro.timer recreates it) — `send-keys … Enter` would EXECUTE the
#      escalation text as a shell command;
#   2. a half-typed message — an escalation landing mid-typing corrupts Kyle's input.
# So: tri-state the pane and deliver ONLY into an affirmatively-empty composer;
# defer on anything else. Fail-safe-to-defer — the worst case is a held escalation
# (its caller's ceiling / push backstop surfaces it), never a shell execution.
#
# SIGNATURES — re-seeded 2026-08-02 against Claude Code v2.1.220, from live
# `tmux capture-pane` output on np-kf1-cus across every pane then running
# (Cerebro:0.0, cb:0.0, cb:1.0, cb:2.0, cerebro-remaining-phases:0.0). Those
# captures are the test fixtures: tests/fixtures/panes/coord-*.txt. Verified end
# to end the same day — a throwaway session, `empty` before, cb_coord_send → 0,
# the line submitted as a turn and answered.
#
# What the previous seeds cost. `? for shortcuts` and `esc to interrupt` appear in
# ZERO lines of 2,000-line scrollback in any pane on this build. So pane_state
# returned `unknown` unconditionally, cb_coord_send returned 1 on every call, and
# delivery into the coordinator was impossible — DEFER-ALARMs continuous since
# 2026-07-15T13:53Z, 335 of them by 2026-08-02T13:34Z and still incrementing
# when this was written. eja-3979 is the shape of the cost: approved at review cycle 2,
# PR body written, paused at the ship gate to ask for the GO, the ask never
# delivered, the conductor classified `failed` ~3h21m later. Eight hours of
# finished work invisible. cb-send recorded the disproof on 2026-07-24 and it was
# never carried one file over.
#
# How long delivery had been broken is NOT determinable and is deliberately not
# claimed here. `beacons/digest.sent` self-prunes to still-open keys
# (cb-digest:34,37), so it is a live set and not a ledger, and the `deferred Ns`
# age printed by cb_escalate is the age of the OLDEST undelivered decision
# fleet-wide (cb-digest:43-44) — a batch-window anchor, not the age of the item
# in the message. Reading one as the other is what produced the "17.2 days"
# figure that an earlier draft of this comment carried; it was arithmetically
# impossible for a one-day-old task and it is gone.
#
# READY IS NOT A REGEX ANY MORE. The guard's contract is not "the pane looks idle"
# — it is "the composer is EMPTY", so an injection cannot land mid-typing. No
# chrome string on this build carries that meaning: the footer
# `⏵⏵ auto mode on (shift+tab to cycle) · ← for agents` renders while busy, while
# idle, and while Kyle is halfway through a sentence. So READY is answered by
# READING THE COMPOSER BOX — the version-independent test cb-send has used since
# 2026-07-24. An empty composer is `❯` followed by U+00A0, not an ASCII space;
# that NBSP normalisation is the whole test. See cb_coord_composer below.
#
# BUSY IS a regex. The rule it encodes is GRAMMATICAL, not a list of strings, and
# that is the part worth keeping when the whimsical vocabulary next rotates:
#
#   working  → a PRESENT PARTICIPLE and a trailing ellipsis
#              `✻ Considering…`  ·  `✢ Gitifying… (4s · thinking with high effort)`
#              `● Reading 1 file, running 9 shell commands…`  ·  `Running 2 shell commands…`
#   finished → the PAST TENSE and a bare duration, no ellipsis, no parenthetical
#              `✻ Brewed for 6m 47s`  ·  `✻ Crunched for 11m 13s`  ·  `✻ Cogitated for 3s`
#
# So the alternation is: (1) the ticking timer `…(<n>[hms]`, (2) any line that is a
# capitalised gerund ending in `…`, with or without a leading spinner glyph, (3)
# `esc to interrupt` as a compat rung that matches nothing on this build.
#
# Branch (2) is the one that matters and it was missing from the first re-seed.
# The elapsed-time counter appears a few seconds INTO a turn; before it does, the
# spinner renders bare — `✻ Considering…` — so a timer-only pattern misses exactly
# the window where a pane has just started working. Two independent observations
# of the same gap: cb-guard's canary caught it on Cerebro:0.0 at ~1/45 samples,
# and a full instrumented turn read `empty` for its first 3 seconds while
# `✢ Frolicking…` was on screen. That is the R17 hazard itself — an injection
# landing mid-turn — so it is worth the width.
#
# Polarity, chosen rather than overlooked. Widening BUSY is SAFE: more panes read
# busy, more escalations defer. Widening READY is not. What must still never
# match is the finished-turn line and the status chrome — `✻ Crunched for 3m 0s`
# carries a glyph AND a duration and is DONE, and the footer truncates to
# `← for agen…`, so a bare trailing `…` would make every pane on the box read
# busy. That is the original bug wearing a different hat: always-defer.
#
# CAPTURE DEPTH (measured, since it is the first thing to suspect when BUSY looks
# wrong): through a full instrumented turn the spinner/timer line sat at depth 6-7
# from the bottom, always inside `tail -40`. The tool-activity line sat at depth
# 41 — OUTSIDE the window — so it is redundant here rather than load-bearing, and
# the depth is deliberately NOT widened: more scrollback means a stale spinner
# line from an earlier turn can read as a live one, which is the always-defer bug
# again.
#
# Drift here is silent — a pattern that matches nothing looks exactly like a quiet
# fleet — so cb-guard carries a canary that fails loudly when it does. Do not
# change these without checking cb-guard's `(e)` block.
# P4: the escalation whitelist — enumerated in lib/turnpolicy.sh, enforced below.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/turnpolicy.sh"
: "${CB_SESSION:=Cerebro}"
#   (1) ticking timer  (2) capitalised gerund line ending in `…`  (3) compat rung
#   (4) spinner glyph + capitalised gerund, ellipsis NOT required
#
# RUNG 4 ADDED 2026-08-03, from a canary capture (logs/coord-canary.capture). The
# missed form was `✻ Waiting for 1 background agent to finish` — a spinner line whose
# activity is a complete sentence, so it never ends in `…` and rung 2 could not see
# it. Measured against that capture's `tail -40` window: rungs 1-3 scored ZERO, rung
# 4 scores 2. (The one `esc to interrupt` in the file sits at depth 51 AND is inside
# a comment quoting this pattern — an artifact of the capture, not a TUI line. Do not
# be reassured by grepping the whole file; grep `tail -40`, which is what the guard
# reads.)
#
# Why the glyph prefix is load-bearing: it is what keeps this rung from matching
# prose. A bare `[A-Z][a-z]+ing` would hit any sentence starting with a gerund. The
# TUI's own completed-turn lines are PAST tense (`✻ Worked for 20m 8s`, `✻ Sautéed
# for 19m 35s`), so they do not match rung 4 — which is the property that stops a
# finished turn reading as live. Verified against all 8 live panes at seed time: rung
# 4 added a match only on the pane that was actually working, and zero on every idle
# one.
# ⭐ 2026-08-07 — `●` AND `⎿` ARE EXCLUDED FROM THE GLYPH CLASS, AND THAT IS THE
# WHOLE FIX FOR A 26-HOUR ALWAYS-DEFER OUTAGE. The glyph class was
# `[^[:alnum:][:space:]]`, i.e. *any* non-alphanumeric — which accepts `●`, the
# TUI's TRANSCRIPT BULLET. A spinner line disappears when the turn ends; a `●`
# line is persisted output that stays on screen forever. So any bulleted line
# beginning with a capitalised gerund pinned the pane to `busy` permanently, and
# every escalation to it deferred forever.
#
# Three real false positives, all measured against a live capture:
#     ● Advising using Opus 5                     (rung 4 — the 2026-08-06 canary catch)
#     ● Starting with the regex fix and reading…  (rung 4 — ASSISTANT PROSE. Any reply
#                                                  opening with a gerund arms the bug.)
#     ● Reading 1 file, running 1 shell command…  (rung 2 — a tool line; rung 2 has the
#                                                  same disease, which the 08-06
#                                                  diagnosis missed by blaming rung 4 alone)
# Cost: eja-3488-fourth-bounce — a Ph1-TL-W1 BLOCKER — sat at spec/awaiting-approval
# for 93,623s with `escalation NOT delivered` on every attempt, alongside four other
# agents. Nothing was broken except this character class.
#
# Verified after the change: `✻ Waiting for 1 background agent to finish` (rung 4's
# entire reason to exist), `✢ Frolicking…`, `✻ Considering…`, `· Befuddling… (1m 8s`
# and `esc to interrupt` ALL still read busy; every past-tense done line and the
# `← for agen…` footer still read not-busy.
#
# The exclusion is deliberately two characters rather than an allowlist of spinner
# glyphs: the polarity note above still holds — widening BUSY is safe, narrowing it
# is not — so an unrecognised spinner glyph must keep reading busy. Only the two
# markers that are known to PERSIST are removed.
CB_COORD_BUSY_RE="${CB_COORD_BUSY_RE:-\
…[[:space:]]*\([0-9]+[hms]\
|^[[:space:]]*([^[:alnum:][:space:]●⎿][[:space:]]+)?[A-Z][a-z]+ing[^…]*…[[:space:]]*$\
|esc to interrupt\
|^[[:space:]]*[^[:alnum:][:space:]●⎿][[:space:]]+[A-Z][a-z]+ing[[:space:]]}"
# R19 in-band sentinel: every daemon→coordinator injection is prefixed with this
# marker — ASCII unit separator 0x1f by default, a byte a human never types at the
# start of a message (verified to survive `tmux send-keys -l`). Contract: a
# coordinator-session message that STARTS with the marker is an internal escalation
# (stay in focus); one WITHOUT it means Kyle is back → exit focus + flush catch-up
# (cb-watch, see cb_focus_human_returned). Overridable for tests / a visible-token
# fallback if the raw byte ever fails to round-trip a real TUI capture.
#
# MEASURED 2026-08-02, and it does NOT round-trip. A cb_coord_send into a live
# v2.1.220 pane delivered correctly, but the submitted turn rendered as plain
# `❯ say exactly OK and stop` — zero lines of the capture contain 0x1f. The TUI
# eats the control byte on echo. Consequence: cb_focus_human_returned cannot tell
# our own injection from a human turn and will exit focus on either. That is R19's
# stated safe direction (a false exit self-corrects; Kyle re-enters focus) so it is
# left as-is here, but the fix is the visible-token fallback this variable already
# contemplates — CB_INJECT_MARK to something printable a human would not open with.
# That is a sentinel-design decision, not part of the 2026-08-02 signature re-seed.
CB_INJECT_MARK="${CB_INJECT_MARK-$(printf '\037')}"

# --- canary helpers (cb-guard `(e)`) ------------------------------------------
# The signatures above are read against the COORDINATOR pane only, but drift is a
# property of the BUILD, so the canary samples every pane on the box. Both are
# mockable the same way cb_coord_pane_tail is, so cb-guard's canary is testable
# without a tmux server.

# cb_coord_pane_list — every live pane target, one per line.
cb_coord_pane_list() {
  eval "${CB_COORD_PANES_CMD:-${CB_TMUX_BIN:-tmux} list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null}" 2>/dev/null || true
}

# cb_coord_capture PANE — that pane's tail. Unreadable degrades to empty output.
cb_coord_capture() {
  local pane="$1"
  eval "${CB_COORD_CAP_CMD:-${CB_TMUX_BIN:-tmux} capture-pane -p -t \"\$pane\" 2>/dev/null | tail -40}" 2>/dev/null || true
}

# cb_coord_pane_tail — last lines of the coordinator pane. CB_COORD_PANE_CMD-
# mockable (point it at a fixture); failure/absence degrades to empty output.
cb_coord_pane_tail() {
  local cmd
  cmd="${CB_COORD_PANE_CMD:-${CB_TMUX_BIN:-tmux} capture-pane -p -t \"$CB_SESSION\" 2>/dev/null | tail -40}"
  eval "$cmd" 2>/dev/null || true
}

# cb_coord_composer [PANE_TEXT] — the coordinator composer's current contents,
# whitespace-squeezed. Returns 1 (UNREADABLE: no Claude composer at all — a login
# shell, a spend-wedge screen, a harness still booting) when the capture is empty
# or carries no `❯` prompt. Prints the empty string when the composer is present
# and empty. Takes the pane text as an argument so a caller can read the pane ONCE
# and ask both questions of the same bytes; captures it itself if not given.
#
# PORTED FROM cb-send's _cb_composer (cb-send:~34-36 carries the reasoning: why the
# composer box and not the TUI chrome, and why the U+00A0 empty case is the thing
# that makes it work). Ported, not improved — that copy is battle-tested. It is a
# DUPLICATE: Kyle chose this stopgap over the lib/compose.sh chokepoint on
# 2026-08-02, so until compose.sh lands the two copies must be changed together.
cb_coord_composer() {
  local pane ln body out="" first=1 l
  if [ "$#" -gt 0 ]; then pane="$1"; else pane="$(cb_coord_pane_tail)"; fi
  [ -n "$pane" ] || return 1
  ln="$(printf '%s\n' "$pane" | grep -n '^[[:space:]]*❯' | tail -1 | cut -d: -f1)"
  [ -n "$ln" ] || return 1
  body="$(printf '%s\n' "$pane" | tail -n +"$ln")"
  while IFS= read -r l; do
    if [ "$first" = 1 ]; then
      first=0
      l="$(printf '%s' "$l" | sed 's/^[[:space:]]*❯//')"
    else
      # a wrapped message continues on the following lines; the closing rule ends it
      printf '%s' "$l" | grep -q '^[[:space:]]*─' && break
    fi
    out="$out $l"
  done <<< "$body"
  # U+00A0 → space (an empty composer is `❯` + NBSP), then squeeze and trim
  printf '%s' "$out" | sed $'s/\302\240/ /g' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'
}

# cb_coord_pane_state — empty | busy | unknown, from ONE capture:
#   unreadable capture                                  → unknown
#   a live work timer on screen                         → busy
#   no `❯` composer box (login shell, wedge, booting)   → unknown  [the R17 hazard]
#   composer present and holding text (Kyle mid-sentence,
#     or one of our own typed-but-unsubmitted strands)  → unknown
#   composer present and empty                          → empty
# Fail-safe: `empty` is the only affirmative answer, and everything that is not
# affirmatively empty defers. BUSY is tested before the composer read on purpose —
# a working pane whose composer happens to be clear must still defer, and a false
# busy costs a deferral, never a send.
cb_coord_pane_state() {
  local pane composer pane2
  pane="$(cb_coord_pane_tail)"
  [ -n "$pane" ] || { echo unknown; return; }
  # ⚠️ DROP THE PERSISTING BACKGROUND-AGENT LINE BEFORE THE BUSY TEST.
  # `✻ Waiting for 1 background agent to finish` matches the `<glyph> Xxxing ` rung —
  # ✻ is not alnum/space/●/⎿, then a space, then `Waiting`. But unlike a spinner it
  # STAYS on screen after the agent finishes, so a pane that has merely once waited
  # on a subagent reads busy FOREVER and every escalation to it defers forever. That
  # is the always-defer failure that cost a Ph1-TL-W1 Blocker 26 hours on 2026-08-07,
  # arriving through a different door. Caught on `deterministic-report-landing:0.0`
  # 2026-08-15 00:37 by cb-guard's own canary: transcript static, composer empty, and
  # this the only matching line — on a pane whose agent had in fact died on a 529
  # two and a half hours earlier.
  #
  # ✻ is NOT excluded as a glyph — it is a real spinner glyph elsewhere, and the
  # header's polarity rule (widening BUSY is safe, narrowing it is not) still binds.
  # Only this one PERSISTING phrase is dropped, the same treatment ● and ⎿ already get.
  #
  # SAFE BECAUSE RUNG 5 IS THE REAL LIVENESS SIGNAL, not this regex. When a background
  # agent is genuinely running the transcript advances between the two samples below
  # (`CB_COORD_ADVANCE_SECS`, default 1.2, on unless explicitly zeroed) and the pane
  # reads busy on that evidence — which is precisely the evidence cb-guard's canary
  # used to call this one idle. If RUNG 5 is ever disabled, restore this line first.
  printf '%s\n' "$pane" | grep -vE '[Ww]aiting for [0-9]+ background agent' \
    | grep -qE "$CB_COORD_BUSY_RE" && { echo busy; return; }
  composer="$(cb_coord_composer "$pane")" || { echo unknown; return; }
  [ -n "$composer" ] && { echo unknown; return; }
  # RUNG 5 — TRANSCRIPT ADVANCE. The last gate before we call a pane sendable.
  #
  # WHY THIS EXISTS AND WHY IT IS NOT A WIDER REGEX (2026-08-05). cb-guard's canary
  # caught Cerebro:0.0 working while every rung of CB_COORD_BUSY_RE read not-busy,
  # and told us to re-seed the regex from the capture. **The capture contains no
  # busy form to seed from.** Compared against a known-idle pane in the same second,
  # the busy tail and the idle tail are structurally IDENTICAL: composer `❯`, the
  # horizontal rules, and the status bar. The TUI renders a spinner during some
  # phases and none at all while it is streaming output, so during a stream there is
  # simply nothing on screen that says "working".
  #
  # Widening the regex to match anything present in that frame would therefore match
  # the idle frame too — every pane would read busy forever and no escalation would
  # ever be delivered. That is strictly worse than the miss it fixes. The signal is
  # not IN a frame; it is BETWEEN two frames, which is exactly what cb-guard itself
  # used to detect the problem.
  #
  # Measured before wiring (both at 2026-08-05 21:4x MT): an idle pane's 12-line tail
  # was byte-identical across a 1.5s gap; a working X-Man's changed. So a change is a
  # sound busy signal and a still pane is a sound empty one.
  #
  # Fail-safe direction is preserved and is the whole point of the ordering: a pane
  # that changed for ANY reason — streaming output, or Kyle starting to type — returns
  # busy and the caller defers. A false busy costs a deferral; a false empty costs an
  # injection into a live turn. Cost is one sleep, paid ONLY on the path that was
  # about to send. Set CB_COORD_ADVANCE_SECS=0 to disable (tests, or a fixture pane).
  local adv="${CB_COORD_ADVANCE_SECS:-1.2}"
  if [ "$adv" != "0" ]; then
    sleep "$adv"
    pane2="$(cb_coord_pane_tail)"
    [ -n "$pane2" ] || { echo unknown; return; }
    [ "$pane" != "$pane2" ] && { echo busy; return; }
  fi
  echo empty
}

# cb_coord_send MESSAGE — deliver one line into the coordinator composer.
# Returns 0 if delivered, 1 if deferred (pane not affirmatively empty). TYPE ONCE
# then submit with a SEPARATE Enter (the 7/13 paste-detection hotfix: an Enter in
# the same burst reads as a newline). Never retypes — a swallowed Enter leaves the
# text in the composer, which the next cb_coord_pane_state reads as non-empty →
# defer, so two payloads can't concatenate into one corrupted turn.
cb_coord_send() {
  local msg="$1" tmux="${CB_TMUX_BIN:-tmux}"
  [ "$(cb_coord_pane_state)" = "empty" ] || return 1
  # R19: prefix the sentinel and send it LITERALLY (-l) so the raw marker byte
  # transmits intact. TYPE ONCE then a SEPARATE Enter (7/13 paste-detection hotfix).
  "$tmux" send-keys -t "$CB_SESSION" -l "${CB_INJECT_MARK}$msg" || return 1
  sleep "${CB_SEND_DELAY:-0.3}"
  "$tmux" send-keys -t "$CB_SESSION" Enter || return 1
  return 0
}

# cb_escalate MSG DEFER_AGE ALARM_MARKER ALARM_KEY CODE — the shared coordinator
# escalation path (single-sourced so cb-notify's per-item page and cb-digest's
# coalesced flush can't drift). Delivers MSG into the coordinator via cb_coord_send
# (R17 composer guard + R19 sentinel), respecting focus mode. Returns 0 if
# DELIVERED (caller owns any delivered-dedup), 1 if held/deferred. On a defer past
# CB_MAX_DEFER_SECS the R16 out-of-band alarm fires ONCE per ALARM_KEY (dedup via
# ALARM_MARKER), so a held escalation never rots invisibly. Requires the caller to
# have sourced push.sh + paths.sh (cb_push / atomic_write / CB_HOME).
cb_escalate() {
  local msg="$1" defer_age="$2" alarm_marker="$3" alarm_key="$4" code="${5:-}" reason=""
  : "${CB_MAX_DEFER_SECS:=300}"
  # P4 turn-policy gate. Escalating is not a judgement call: every escalation
  # carries an enumerated reason (policy/turn-policy.md → escalation whitelist),
  # and anything else is refused HERE — before delivery and before the R16
  # ceiling. Refusing before the ceiling is deliberate: a non-escalation is not a
  # HELD escalation, so it must not fire an out-of-band alarm either. Fail-closed
  # on a missing code so a new caller cannot escalate by forgetting.
  if ! cb_escalation_allowed "$code"; then
    mkdir -p "$CB_HOME/logs"
    printf '%s POLICY-REFUSED escalation code=%s msg=%s\n' \
      "$(date -Is)" "${code:-<none>}" "$msg" >> "$CB_HOME/logs/events"
    return 1
  fi
  # DURABLE FIRST, DELIVER SECOND (2026-08-13). Record the escalation to the
  # file-backed inbox BEFORE attempting any delivery, so a question survives
  # every channel failing at once. Both channels did, on 2026-08-13: cb_coord_send
  # requires cb_coord_pane_state = "empty" and this TUI's busy and idle frames are
  # structurally identical (see :237-248), so it defers whenever the coordinator is
  # working; cb_push needs CB_PUSH_URL, never set on this box. A conductor's
  # needs-input went undelivered, and 70 minutes later it promoted itself to
  # ready-for-review on the same unanswered gate and exited. Delivery is now
  # best-effort on top of durable state instead of being the only state.
  # Drained by whoever actually puts it in front of Kyle: cb-escalations --drain.
  local _esc_bin
  _esc_bin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/cb-escalations"
  if [ -x "$_esc_bin" ]; then
    "$_esc_bin" --record "${CB_SLUG:-unknown}" "${code:-none}" "$msg" >/dev/null 2>&1 || true
  fi
  if [ "$(cat "$CB_HOME/mode" 2>/dev/null)" = "focus" ]; then
    reason="focus held"
  elif cb_coord_send "$msg"; then
    rm -f "$alarm_marker" 2>/dev/null || true   # delivered → re-arm the ceiling
    return 0
  else
    reason="coordinator pane not deliverable"
  fi
  # held (focus) or deferred (pane): R16 ceiling — surface out-of-band past the ceiling
  if [ "$defer_age" -ge "$CB_MAX_DEFER_SECS" ] && [ "$(cat "$alarm_marker" 2>/dev/null)" != "$alarm_key" ]; then
    local amsg="$msg deferred ${defer_age}s ($reason) past ${CB_MAX_DEFER_SECS}s ceiling; escalation NOT delivered"
    mkdir -p "$CB_HOME/logs"
    printf '%s DEFER-ALARM %s\n' "$(date -Is)" "$amsg" >> "$CB_HOME/logs/events"
    # exit 1 = no channel, 2 = a channel is set but unusable (bad
    # CB_PUSH_FORMAT / slack without jq). Telling Kyle to "set CB_PUSH_URL"
    # when he already set it sends him looking in the wrong place.
    cb_push "$amsg" || case $? in
      2) echo "cb-escalate: $amsg (push channel MISCONFIGURED — see the cb_push line above)" >&2 ;;
      *) echo "cb-escalate: $amsg (no push channel configured — set CB_PUSH_URL)" >&2 ;;
    esac
    printf '%s' "$alarm_key" | atomic_write "$alarm_marker"
  fi
  return 1
}

# cb_focus_human_returned — R19 auto-exit signal: when focus mode is on, has Kyle
# come back to the coordinator pane? Returns 0 to exit focus, 1 to stay.
#
# REWRITTEN 2026-08-02 alongside the signature re-seed, because it was the third
# consumer of `CB_COORD_READY_RE` and was BROKEN OPEN by the same dead pattern.
# The old test was "last non-blank line of the capture, minus our marker, minus
# idle chrome". On this build the last non-blank line is ALWAYS the status footer
# — so it was non-blank, unmarked, and matched nothing → return 0. Measured
# against all four live captures (busy, idle, mid-typing, dead shell) it exited
# focus every time, for every pane. Focus mode has not held since the TUI changed.
#
# The signal that actually exists: a submitted turn is echoed into the transcript
# as its own `❯ <text>` line, and the LIVE composer box is the LAST such line. So
# the most recent submitted turn is the second-to-last `❯` line, and R19's whole
# question — ours or his? — is asked of that. Marker-prefixed → our own injection,
# stay. Anything else → a human turn landed, exit.
#
# Deliberately conservative, and fail-closed on every unsure branch: no composer
# box (dead shell / wedge / booting) → stay; no submitted turn inside the capture
# window → stay. That last one bites when a long turn has scrolled the submitted
# line past `tail -40`, which is why R19 auto-exit stays best-effort with manual
# focus-exit as the floor. Bias per R19: a false exit self-corrects (Kyle just
# re-enters focus), a false STAY only costs latency on the catch-up flush.
#
# The live composer's own contents are NOT used as a "Kyle is typing" signal: the
# text sitting there may be one of our own typed-but-unsubmitted strands (the
# failure cb-send's verify ladder exists for), which would read as a human turn.
cb_focus_human_returned() {
  local pane lines prev
  pane="$(cb_coord_pane_tail)"
  [ -n "$pane" ] || return 1                                  # unreadable → stay
  # every prompt line, in order; the last is the live composer box
  lines="$(printf '%s\n' "$pane" | grep '^[[:space:]]*❯')"
  [ -n "$lines" ] || return 1                                 # no Claude composer → stay
  prev="$(printf '%s\n' "$lines" | tail -2 | head -1)"
  [ "$(printf '%s\n' "$lines" | wc -l)" -ge 2 ] || return 1   # nothing submitted on screen → stay
  # strip the prompt glyph and the NBSP an empty line carries, then trim
  prev="$(printf '%s' "$prev" | sed 's/^[[:space:]]*❯//' | sed $'s/\302\240/ /g' \
          | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
  [ -n "$prev" ] || return 1                                  # blank turn → stay
  case "$prev" in "${CB_INJECT_MARK}"*) return 1;; esac       # our own injection → stay
  return 0                                                    # a human turn landed → exit focus
}
