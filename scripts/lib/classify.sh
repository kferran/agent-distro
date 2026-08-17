# R6/R9 two-clock model (audit amendment to R6): a wedge-suspicion clock and a
# much longer, repeating declared-pause recheck clock. A fresh beacon line
# under STALE_ESCALATE is positive proof of progress (R13); a `paused:` beacon
# is rechecked on the long PAUSE_RESURFACE cadence and never escalated as a
# wedge, but MUST resurface once it ages past it so a forgotten pause can't rot.
# NB: with pane-hashing deferred, staleness is beacon-mtime only — STALE_ESCALATE
# is the one tunable here; the agent contract (cb-brief) instructs a beacon
# append at each MATERIAL phase change + `paused:` for waits to keep well-behaved
# agents under the wire.
: "${CB_STALE_ESCALATE_SECS:=240}"
: "${CB_PAUSE_RESURFACE_SECS:=3600}"
: "${CB_LAUNCH_GRACE_SECS:=30}"
: "${CB_PRESPAWN_GRACE_SECS:=300}"   # (d) brief→launch gap: no-beacon+no-report task dir this fresh reads pre-spawn (running), not failed
: "${CB_CODE_STALL_SECS:=3600}"   # conductor builds are long — 1h before a silent manifest reads as stalled
: "${CB_REMEDIATE_CAP:=2}"   # mirror cb-remediate's cap so classify can promote an exhausted wedge
: "${CB_DECISION_AGE_WARN_SECS:=259200}"   # 3d — board age marker on a logged-open decision (see cb_decision_markers)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/conductor.sh"
# paths.sh for cb_task_dir: open_decisions_live resolves a `settled-by` pointer to
# ANOTHER task's dir, so classify.sh now genuinely depends on it rather than on
# every caller happening to source it first (tests/classify.bats does not).
# Idempotent — CB_HOME is a `:=` default and the rest are function definitions.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/paths.sh"
# Defensive: the verb audit below degrades to a once-per-process stderr warning
# if dedup.sh is absent, rather than breaking the fold the live watcher runs.
[ -f "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dedup.sh" ] && \
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dedup.sh"
_fm_status() {
  awk '/^---[[:space:]]*$/{n++; next} n==1 && /^status:/{sub(/^status:[[:space:]]*/,""); sub(/[[:space:]]*$/,""); sub(/\r$/,""); print; exit}' "$1" 2>/dev/null
}
# _beacon_state FILE — the sparse status beacon's current state (R9). The beacon
# is append-only: agents append `{state}: {one line}` on material phase changes.
# The LAST non-empty line drives state; the leading token before the first ':'
# is the state (lowercased, trimmed). Tolerant of the bare `running` launch word
# cb-start writes (no colon → the whole token). Empty output = no/empty beacon.
_beacon_state() {
  awk 'NF{last=$0} END{ if(last==""){exit}; sub(/:.*/,"",last); gsub(/^[[:space:]]+|[[:space:]]+$/,"",last); print tolower(last) }' "$1" 2>/dev/null
}
# _beacon_state_gate TD — the gate one-line for a RESEARCH decision: the status
# beacon's last non-blank line minus its leading `state: ` token (whole line if
# no colon). Code tasks take their gate from task_gate (the manifest); this is
# the research/beacon side of the same "what it's waiting on" descriptor.
_beacon_state_gate() {
  local last; last="$(grep -v '^[[:space:]]*$' "$1/status" 2>/dev/null | tail -1)"
  case "$last" in *:*) printf '%s' "${last#*: }";; *) printf '%s' "$last";; esac
}
# --- R12 open-decision set (append-only per-task `decisions` log) ------------
# The board's "needs you" is the OPEN-DECISION SET, not last-state-wins: a
# needs-input/blocked stays open until an explicit `resolved` keyed to it, so a
# later terminal-state flip can never silently mask a still-open decision. The
# log is append-only (a `resolved` is a new line, never an in-place edit) so
# history stays auditable; the open set is the FOLD of the log.
#   <iso-ts> open     <key> <gate one-line>
#   <iso-ts> resolved <key>
_decision_ts() { date -u +%Y-%m-%dT%H:%M:%S+00:00; }
_decision_log() { printf '%s/decisions' "$1"; }
# --- unknown-verb audit (detect-at-read) -------------------------------------
# The fold reads exactly three verbs. Anything else it skipped in silence, which
# made an append-only log into a data-loss channel: on 2026-07-28 Kyle answered
# a live 8/10 go-live question and the answer was appended with the verb
# `answered`. Nothing recognised it, so the decision read as unanswered on
# board.md and in every escalation digest for four days. By 2026-08-02 there
# were three such lines, all real go/no-go calls, all reading as open.
#
# DETECT-AT-READ, not reject-at-write. Every observed bad line was hand-appended
# by a model that never called `_decision_open`/`_decision_declare` — a
# write-side validator is structurally blind to the writer that actually caused
# this. The reader is the only place that sees every line.
#
# WARN, don't refuse to compute. Refusing would blank the decision set for the
# task, and that set is the one surface carrying the real open questions —
# fail-closed on a delivery gate is the disease, not the cure. Same
# fail-safe-to-escalate polarity as R13.
#
# _decision_verb_audit TD — surface any line the fold cannot read. Deduped on
# content (lib/dedup.sh) so a standing bad line warns once, while a NEW one
# changes the message (the count is in it) and warns again.
_decision_verb_audit() {
  local log; log="$(_decision_log "$1")"; [ -f "$log" ] || return 0
  # Fast path, and it is the whole cost on a healthy log: one grep. A `resolved`
  # line ends at its key, so the verb may be followed by a space OR end-of-line.
  grep -qvE '^[[:space:]]*$|^[^ ]+ (open|declared|resolved|supersedes|settled-by)([[:space:]]|$)' "$log" || return 0
  local slug verbs n msg
  slug="$(basename "$1")"
  verbs="$(awk '!/^[[:space:]]*$/ && $2!="open" && $2!="declared" && $2!="resolved" && $2!="supersedes" && $2!="settled-by" {print $2}' "$log" | sort -u | tr '\n' ' ')"
  n="$(awk '!/^[[:space:]]*$/ && $2!="open" && $2!="declared" && $2!="resolved" && $2!="supersedes" && $2!="settled-by" {c++} END{print c+0}' "$log")"
  msg="unknown decision verb(s) [${verbs% }] x$n in $slug/decisions — those lines are INVISIBLE to the fold, so the decision still reads as open. Readable verbs are open|declared|resolved|supersedes|settled-by; close a decision with cb-send, not a hand-appended line."
  local home="${CB_HOME:-}"
  if [ -n "$home" ] && declare -F cb_dedup_new >/dev/null 2>&1 && declare -F atomic_write >/dev/null 2>&1; then
    [ -n "$(cb_dedup_new "$home/beacons/verb-audit.$slug" "$msg")" ] || return 0
  else
    # no dedup channel available — warn once per process rather than per read
    case " ${_CB_VERB_WARNED:-} " in *" $slug "*) return 0;; esac
    _CB_VERB_WARNED="${_CB_VERB_WARNED:-} $slug"
  fi
  if [ -n "$home" ]; then
    mkdir -p "$home/logs" 2>/dev/null || true
    printf '%s cb-verb-audit %s\n' "$(date -Is)" "$msg" >> "$home/logs/events" 2>/dev/null || true
  fi
  printf 'cerebro: %s\n' "$msg" >&2
}
# _decision_key STATE GATE — stable CONTENT key (this IS R18: the dedup key is
# the decision content, not a timestamp). Same decision across ticks → same key
# → idempotent; a genuinely different decision → new key → surfaces separately.
_decision_key() { printf '%s|%s' "$1" "$2" | cksum | cut -d' ' -f1; }
# --- the ONE openness fold ----------------------------------------------------
# Every consumer below concatenates its own END block onto _CB_FOLD_BODY instead
# of writing its own open-minus-resolved pass. There used to be five independent
# copies of that predicate (_is_open, _has_declared_open, _open_heuristic_keys,
# open_decisions, open_decisions_live), and adding a verb to some but not all of
# them is split-brain, not a partial fix: the board renders a key closed while
# cb-ask refuses to re-declare it ("already open") and _decision_resolve keeps
# appending `resolved` lines for a key nothing reads. That state passes a
# board-level test.
#
# Arrays it leaves for the END block:
#   opn[k]  1 open / 0 closed      dec[k]  1 iff the key's ORIGIN verb was `declared`
#   st[k]   needs-input|blocked    gate[k] the decision's one-line text
#   setl[k] the slug named by a `settled-by` pointer (cross-task; see below)
#   res[k]  1 iff a `resolved` has been seen — with !dec[k] this SEALS the key
#           against re-projection (see the `open` arm)
#
# SUPERSESSION IS APPLIED IN LOG ORDER, never in the END block. The log is
# append-only, so a key that is superseded and then genuinely re-declared later
# must re-open — an END-block pass would see only the final state of `sup` and
# close it wrongly.
#
# THE AUTHORITY GUARD (`$3 in dec`) IS LOAD-BEARING. A `supersedes` line only
# takes effect when the SUPERSEDING key is itself `declared` — a human-authored
# question. Without it, the watcher's heuristic `open` (a suspicion derived from
# a stale beacon, which nobody typed) could close a question Kyle asked. That is
# the anti-masking rule in its local form: cb-board:20-32 is deliberate that a
# `declared` question survives everything short of the work shipping, so a
# lower-authority line must never be able to retire one.
#
# PROSE IS A FALLBACK, NOT THE MECHANISM. Agents were already writing
# "SUPERSEDES 1493386392" into the decision text where nothing could read it, so
# the fold parses it — but only for logs already on disk, and only when the
# extracted number names a key that ALREADY EXISTS in this same log. A stray
# `SUPERSEDES 12345` in free prose is then a no-op rather than a silent close,
# and prose can only reach backwards, exactly like the verb.
_CB_FOLD_BODY='
  /^[[:space:]]*$/ { next }
  $2=="declared" {
    dec[$3]=1; opn[$3]=1; st[$3]=$4
    g=$0; sub(/^[^ ]+ declared [0-9]+ [^ ]+ /,"",g); gate[$3]=g
    if (match(toupper(g), /SUPERSEDES[[:space:]]+[0-9]+/)) {
      p=substr(toupper(g),RSTART,RLENGTH); sub(/^SUPERSEDES[[:space:]]+/,"",p)
      if (p in opn) opn[p]=0
    }
    next }
  $2=="open" {
    # SEALED: a PROJECTED key that has already been resolved does not re-open.
    # The watcher re-derives its key from source text (the manifest gate, the
    # beacon descriptor) that may never change again, so the identical key was
    # re-appended every tick and no `resolved` could ever win — a resolve at
    # 17:50 was re-opened at 17:51, twice, on merged work. Measured across the
    # task set on 2026-08-04: 17 keys folding open behind a resolve, every one
    # of them projected, the oldest three weeks old.
    #
    # SCOPED TO NON-`declared` KEYS, which is what keeps the anti-masking rule
    # (cb-board:20-32) intact: a question a human TYPED via cb-ask still
    # re-opens, and re-declaring after an answer is how a worker re-raises one.
    # The origin verb is already the discriminator everywhere else here.
    #
    # The trade: a projected gate that is resolved and later re-projected with
    # byte-identical text stays closed. That is the intent — identical text is
    # the same decision — and both escape hatches are live: any change to the
    # gate text re-keys, and cb-ask writes `declared`.
    if (($3 in res) && !($3 in dec)) next
    opn[$3]=1; st[$3]=$4
    g=$0; sub(/^[^ ]+ open [0-9]+ [^ ]+ /,"",g); gate[$3]=g
    next }
  $2=="resolved"   { opn[$3]=0; res[$3]=1; next }
  $2=="supersedes" { if ($3 in dec) opn[$4]=0; next }
  # The settler slug is resolved to a task DIR, and this log is a channel models
  # hand-append to (that is the whole verb-audit rationale) — so validate it here
  # rather than trusting cb-settle to be the only writer. A hand-written
  # `settled-by <key> ../../somewhere-with-a-done-file` would otherwise close a
  # decision by pointing outside the task set. Same grammar as cb_require_slug.
  $2=="settled-by" { if ($4 ~ /^[a-z0-9][a-z0-9._-]*$/) setl[$3]=$4; next }
'
# _is_open TD KEY — 0 iff KEY has an `open` OR `declared` with no later `resolved`
# and no later `supersedes`. Both verbs are openers; `declared` (cb-ask, P1) is
# the high-fidelity one. This is what makes `_decision_resolve` able to close a
# declared decision — without it a cb-ask'd gate would be permanently unresolvable.
_is_open() {
  local log; log="$(_decision_log "$1")"; [ -f "$log" ] || return 1
  awk -v k="$2" "$_CB_FOLD_BODY"' END{ exit ((k in opn) && opn[k]) ? 0 : 1 }' "$log"
}
# _decision_sealed TD KEY — 0 iff KEY is a PROJECTED key with a `resolved`
# already in the log, i.e. the fold's `open` arm will ignore any further open
# line for it. Two callers need this as a predicate rather than as fold state:
# `_decision_open`, so a sealed key stops accruing dead lines, and the tests.
_decision_sealed() {
  local log; log="$(_decision_log "$1")"; [ -f "$log" ] || return 1
  awk -v k="$2" "$_CB_FOLD_BODY"' END{ exit ((k in res) && !(k in dec)) ? 0 : 1 }' "$log"
}
# _decision_open TD KEY STATE GATE — append an open line iff KEY not already
# open. STATE (needs-input|blocked) is recorded so the board can cost-order + label.
#
# The sealed check is not redundant with `_is_open`: a sealed key folds CLOSED,
# so _is_open alone would append an `open` line the fold then ignores — two dead
# lines per task every tick, ~2,800 a day at the 30s cadence. Refusing the write
# is also what makes the seal legible in the log: the last line stays the
# `resolved`, instead of a growing tail of opens that read as unanswered.
_decision_open() {
  _is_open "$1" "$2" && return 0
  _decision_sealed "$1" "$2" && return 0
  printf '%s open %s %s %s\n' "$(_decision_ts)" "$2" "$3" "$4" >> "$(_decision_log "$1")"
}
# _decision_resolve TD KEY — append a resolved line iff KEY currently open.
_decision_resolve() {
  _is_open "$1" "$2" || return 0
  printf '%s resolved %s\n' "$(_decision_ts)" "$2" >> "$(_decision_log "$1")"
}
# _decision_declare TD KEY STATE GATE — the cb-ask (P1) opener. Same shape and
# same content key as `_decision_open`, distinct verb: the watcher reads the verb
# to know a HUMAN-AUTHORED question is already on the board for this task and
# stands its own heuristic key down (see cb-watch). STATE must be needs-input —
# cb-board's `_bucket_decision` has no default arm for anything else.
_decision_declare() {
  _is_open "$1" "$2" && return 0
  printf '%s declared %s %s %s\n' "$(_decision_ts)" "$2" "$3" "$4" >> "$(_decision_log "$1")"
}
# _decision_supersede TD NEW-KEY OLD-KEY — the forward-only fix. Records that
# NEW-KEY replaces OLD-KEY, which closes OLD-KEY (see _CB_FOLD_BODY's authority
# guard: NEW-KEY must itself be `declared`).
#
# A tool-written `resolved` would have satisfied the literal requirement and is
# deliberately NOT what this does. `resolved` already means "a human answered
# this" — cb-send writes it on delivery — and reusing it for "a sharper
# restatement replaced this" erases the distinction in the one log that exists to
# make "which of these is current" answerable from the data.
_decision_supersede() {
  _is_open "$1" "$3" || return 0
  printf '%s supersedes %s %s\n' "$(_decision_ts)" "$2" "$3" >> "$(_decision_log "$1")"
}
# _decision_settled_by TD KEY SLUG — cross-task settlement POINTER. Deliberately
# not a close: it names the task whose shipping answers this question, and only
# open_decisions_live acts on it. `open_decisions` stays raw (see :116) because
# cb-watch and cb-send must keep seeing every open key — if a settled key
# vanished from the raw fold, a later human answer via cb-send would write no
# `resolved` at all and the audit record of that answer would be lost.
#
# THE SEAL DOES NOT VIOLATE THAT CONTRACT, and the distinction is the reason the
# rule is worded as an audit requirement. A SETTLED key has no `resolved` line,
# which is exactly why it has to stay in the raw fold: the answer, when it comes,
# is the first one recorded. A SEALED key already carries its `resolved` — the
# answer is on disk — so cb-send:490 skipping it loses nothing. What the seal
# drops is a re-derived duplicate of an answered question, never the answer.
_decision_settled_by() {
  _is_open "$1" "$2" || return 0
  printf '%s settled-by %s %s\n' "$(_decision_ts)" "$2" "$3" >> "$(_decision_log "$1")"
}
# _has_declared_open TD — 0 iff at least one `declared` key is still open. The
# watcher's suppression test: a declared gate supersedes the derived one.
_has_declared_open() {
  local log; log="$(_decision_log "$1")"; [ -f "$log" ] || return 1
  awk "$_CB_FOLD_BODY"' END{ for (k in opn) if (opn[k] && dec[k]) exit 0; exit 1 }' "$log"
}
# _open_heuristic_keys TD — still-open keys whose ORIGINATING verb was the
# watcher's heuristic `open` and never `declared`. One per line. Used to
# supersede a lower-fidelity duplicate once the worker declares the real gate.
_open_heuristic_keys() {
  local log; log="$(_decision_log "$1")"; [ -f "$log" ] || return 0
  awk "$_CB_FOLD_BODY"' END{ for (k in opn) if (opn[k] && !dec[k]) print k }' "$log"
}
# _decision_for TD STATE — the derived decision tuple "<key>\t<state>\t<gate>"
# for a task the watcher classifies as STATE (needs-input|blocked). Gate is the
# code manifest gate (task_gate) or the research beacon descriptor. Single-sourced
# so the watcher (which OPENS it) and the board (which may project a live one not
# yet logged) compute the identical key.
#
# A CODE TASK WITH NO GATE SIGNAL PROJECTS NOTHING (2026-08-04). `task_gate`
# falls back to `current_task`, which is the RESUME POINTER — cb-brief:66 forbids
# conductors from recording a gate there, and the projector must not read as a
# question what conductors are told is not one. A conductor that finishes
# correctly leaves `current_task` naming its last phase (`ship/complete`), and
# because `_decision_key` hashes the gate TEXT, that produced a decision whose
# source string will never change again: every `resolved` was re-opened on the
# next tick, forever. Two finished-and-merged tasks polluted the supervisor
# digest for a day that way, and no settlement path could win — cb-settle refuses
# ("a task cannot settle its own decision") and cb-reap keeps needs-input by
# design.
#
# THE SUPPRESSION LIVES HERE, NOT IN `task_gate`. Emptying task_gate looks like
# the same fix and is not: this function falls through to `_beacon_state_gate`,
# so the phantom would just re-source itself from the status beacon. Measured on
# the two target tasks — one beacon reads `running`, the other a 160-char
# progress line — and cksum("blocked|running") is open on 7 other tasks for
# exactly that reason. task_gate keeps its fallback, so cb-watch's events
# annotation and cb-stuck's display still show the position; only the DECISION
# stops being manufactured.
#
# ⚠️ THIS COMMENT USED TO READ "Research tasks are unaffected: their gate is the
# beacon descriptor, which the worker writes deliberately (`blocked:` /
# `paused:`), not a resume pointer." That was wrong on both halves, and it cost
# a real escalation on 2026-08-06.
#
#   1. The `kind = code` test never fires for a research task, because a research
#      task has NO `meta` FILE AT ALL — `cb-start --research` writes brief.md,
#      launch.sh, status and xman, but no meta. `_meta_field` returns empty, the
#      guard falls through, and the decision is manufactured.
#   2. `blocked` is NOT always worker-declared. `classify_research` also INFERS
#      it: beacon older than CB_STALE_ESCALATE_SECS + a pane not matching
#      CB_BUSY_PATTERN = wedge-suspect -> blocked (see the `alive)` branch). The
#      worker said nothing.
#
# Measured: `outstanding-from-2026-08-05` was reading files quietly, its last
# beacon line was `running: orienting — reading daily notes, meetings, hot.md,
# unlanded reports`, and that PROGRESS LINE was opened as decision 3650643150
# with state `blocked`. Nothing can answer a status line, so per cb-ask's own
# note it would escalate to Kyle every batch forever until a hand-written
# `resolved` cleared it — the exact permanent-noise class cb-ask refuses to
# create at the front door, arriving through the back.
#
# So the rule is DECLARED-ONLY for every non-code lane: a decision needs the
# worker to have said it is stopped (`blocked:` / `paused:` in the beacon).
# Inference still classifies and still displays — `task_gate` keeps its fallback
# so cb-watch and cb-stuck show the position — only the DECISION stops being
# manufactured. Same shape as the code-lane suppression above, same reason.
_decision_for() {
  local dgate
  if [ "$(_meta_field "$1" kind)" = "code" ]; then
    _has_gate_signal "$1" || return 0
  else
    case "$(_beacon_state "$1/status")" in blocked|paused) : ;; *) return 0;; esac
  fi
  dgate="$(task_gate "$1" 2>/dev/null)"; [ -n "$dgate" ] || dgate="$(_beacon_state_gate "$1")"
  printf '%s\t%s\t%s' "$(_decision_key "$2" "$dgate")" "$2" "$dgate"
}
# _has_gate_signal TD — 0 iff a CODE task has POSITIVE evidence that its
# conductor is waiting on a human. The projection predicate for _decision_for:
# the question is not "is this task needs-input" (classify_code answers that from
# several kinds of evidence) but "did the conductor SAY it is waiting". Three
# accepted sources, and they are exactly the two classify_code itself trusts:
#
#   1. `gate:`            — the declared field. Counts on its own, even with no
#      `gate_question`, because it is the conductor saying "I am stopped" in the
#      field built for saying it; the step slug is then the only text available to
#      describe it, which is why task_gate keeps its fallback (classify.bats:464).
#   2. `gate_question:`   — the declared question.
#   3. `current_task` whose vocabulary cb_gate_vocab_class calls `gate` — the
#      `awaiting-approval` sentinel and its relatives.
#
# WHY (3) IS HERE, against the dev item's narrower wording. The dev item asked for
# the declared field ONLY, judging the loss of the sentinel path "arguably
# correct". It is not: the work-conductor skill shipping in the fleet today
# (porch-skills ultron 1.1.0) prescribes `current_task: {phase}/awaiting-approval`
# as THE approval-pause protocol and does not mention `gate:` anywhere. Requiring
# the field would have silenced every approval pause the current conductor skill
# produces — no decision, no digest page — which trades this bug for a worse one.
# Four R12/R15 wiring tests encode that same sentinel as the canonical
# needs-input code fixture, which is the same evidence from the other side.
#
# It is NOT a widened heuristic. cb_gate_vocab_class is reused as-is, and
# classify.sh:625 is right that widening its regex fixes yesterday's wording —
# so `unknown` vocabulary deliberately does NOT project, matching classify_code,
# which also only infers needs-input on `gate`.
#
# WHAT THIS EXCLUDES is the whole failure: `progress` vocabulary (`ship/complete`,
# `ship/1-land-and-followup-item`, `review/2-cycle-02`) and `unknown`. A task
# there reached needs-input from the R13 arm at classify.sh:800 — a live session,
# a manifest that has not moved, a quiet pane — which is a state nobody can
# establish, not a question anyone can answer. Those render on cb-board's
# "❓ No declared gate" line instead.
#
# The durable fix is to teach the conductor skill `gate:`, at which point (3) can
# go. Until then it is load-bearing, exactly as classify.sh:742 says.
_has_gate_signal() {
  local wt run
  wt="$(_meta_field "$1" worktree)"; [ -n "$wt" ] || return 1
  run="$(resolve_run "$wt" "$(basename "$1")" "$(_meta_field "$1" jira)" 2>/dev/null)" || return 1
  [ -n "$(manifest_field "$run" gate)" ] && return 0
  [ -n "$(manifest_field "$run" gate_question)" ] && return 0
  [ "$(cb_gate_vocab_class "$(manifest_field "$run" current_task)")" = gate ] && return 0
  return 1
}
# open_decisions TD — fold the log; one "<key>\t<state>\t<gate>" per still-open key.
open_decisions() {
  local log; log="$(_decision_log "$1")"; [ -f "$log" ] || return 0
  _decision_verb_audit "$1"
  awk "$_CB_FOLD_BODY"' END{ for (k in opn) if (opn[k]) printf "%s\t%s\t%s\n", k, st[k], gate[k] }' "$log"
}
# --- decision settlement (board membership) ----------------------------------
# A folded-open decision can outlive the question it asked: the task ships,
# finishes, or gets answered somewhere off-Cerebro, and nothing ever writes the
# matching `resolved` line. `open_decisions` is the raw fold and STAYS raw —
# cb-watch and cb-send own resolution and must see every open key, or they lose
# the ability to close one. The narrower question, which only the board asks, is
# "is this still a decision Kyle has to make?"
#
# The discriminator is the originating VERB, because the two carry different
# authority:
#   `declared` (cb-ask) — a human-authored question. A terminal report.md does
#     NOT settle it: the cb-ask lifecycle for a research/ops X-Man is ask →
#     write report → exit, so a finished report is the NORMAL companion of an
#     unanswered question, not evidence against it. Only hard shipping evidence
#     settles it, where the work provably moved on without the answer.
#   `open` (the watcher's heuristic) — a SUSPICION derived from a stale beacon
#     or a manifest gate, never a question anyone typed. Any terminal evidence
#     falsifies it: the task did not wedge, it finished.
# _task_terminal TD — hard | soft | none.
#   hard = the work shipped (cb-cleanup's done marker, or a merged PR).
#   soft = the task finished and reported (terminal report.md, or the conductor's
#          summary.md), which proves progress but settles no question.
_task_terminal() {
  [ -f "$1/done" ] && { echo hard; return; }
  [ "$(cat "$1/pr.state" 2>/dev/null)" = MERGED ] && { echo hard; return; }
  if [ -f "$1/report.md" ]; then
    case "$(_fm_status "$1/report.md")" in complete|partial|failed) echo soft; return;; esac
  fi
  [ -f "$1/summary.md" ] && { echo soft; return; }
  echo none
}
# open_decisions_live TD — open_decisions minus the settled ones; same tab shape.
# Two settlement tests, in this order:
#
#   1. THE ASKING TASK'S OWN terminal evidence, as before. hard → nothing
#      outstanding. soft → only `declared` survives. none → everything survives.
#   2. CROSS-TASK, new: a `settled-by` pointer at a task that has HARD shipped.
#      `open_decisions_live` used to consult only (1), so a question asked by task
#      A and answered by shipping task B never closed — comms-lookback-distillation
#      asked "build ns-comms-sweep standalone, fold, or hold?", Kyle answered
#      "standalone", the work shipped under build-ns-comms-sweep, and the asking
#      task had no terminal evidence of its OWN, so the digest kept asking.
#
# THE SETTLER MUST BE `hard`, NEVER `soft`. _task_terminal returns soft for a
# terminal report.md, and :171 is explicit that a finished report is the NORMAL
# companion of an unanswered question — honoring a settled-by pointer on soft
# would retire live questions on a task merely having written something down.
# `hard` is the work provably shipping, which is evidence that answers.
#
# Still not a state bucket, in either test: both read terminal EVIDENCE, and the
# anti-masking rule (cb-board:20-32) holds — a `declared` question survives its
# own task's soft terminal, and can only be dropped by shipping.
open_decisions_live() {
  local td="$1" log term key verb settler state gate
  log="$(_decision_log "$td")"; [ -f "$log" ] || return 0
  _decision_verb_audit "$td"   # before the terminal short-circuits — a shipped task can still hold an unread line
  term="$(_task_terminal "$td")"
  [ "$term" = hard ] && return 0
  # `-` stands in for "no settled-by pointer": IFS=$'\t' read collapses runs of
  # tabs (tab is IFS whitespace), so an empty field would shift every column left.
  while IFS=$'\t' read -r key verb settler state gate; do
    [ -n "$key" ] || continue
    if [ "$term" = soft ] && [ "$verb" != declared ]; then continue; fi
    if [ "$settler" != "-" ] && [ "$(_task_terminal "$(cb_task_dir "$settler")")" = hard ]; then continue; fi
    printf '%s\t%s\t%s\n' "$key" "$state" "$gate"
  done < <(awk "$_CB_FOLD_BODY"' END{ for (k in opn) if (opn[k])
             printf "%s\t%s\t%s\t%s\t%s\n", k, (dec[k]?"declared":"open"), ((k in setl)?setl[k]:"-"), st[k], gate[k] }' "$log")
}
# _open_decisions_aged TD — open_decisions_LIVE prefixed with the open line's ISO
# timestamp: "<open-iso-ts>\t<key>\t<state>\t<gate>" per key. Feeds cb-digest's
# oldest-item batch window, and cb-digest is its only caller.
#
# It used to fold the RAW set, which is why the digest reported "Supervisor
# escalate (83)" while cb-board — reading open_decisions_live — showed the real
# count of about 6. ~92% of the digest was settled heuristic suspicion by
# construction, so the handful of genuine questions were buried and nobody read
# it. Fixed HERE rather than in open_decisions, because the :116 contract is
# explicit that the raw fold stays raw: cb-watch and cb-send own resolution and
# must keep seeing every open key. The aged view carries no such obligation —
# its consumer is a human digest, which is exactly the "is this still a decision
# Kyle has to make?" question open_decisions_live answers.
#
# Unread verbs do not vanish in either direction: _decision_verb_audit fires on
# this path too (and again inside open_decisions_live, where the content dedup
# collapses the pair to one warning).
_open_decisions_aged() {
  local log; log="$(_decision_log "$1")"; [ -f "$log" ] || return 0
  _decision_verb_audit "$1"
  local key state gate ts
  while IFS=$'\t' read -r key state gate; do
    [ -n "$key" ] || continue
    # last open/declared line for the key — same age semantics as the old fold
    ts="$(awk -v k="$key" '($2=="open"||$2=="declared")&&$3==k{t=$1} END{print t}' "$log")"
    printf '%s\t%s\t%s\t%s\n' "$ts" "$key" "$state" "$gate"
  done < <(open_decisions_live "$1")
}
# --- R22 harness-process liveness probe --------------------------------------
# tmux name presence proves a WINDOW/SESSION exists, not that the harness inside
# it is running: a crashed claude leaves a live-named pane sitting at a shell,
# which the name-only check reads as `alive` forever. R22 adds a second probe.
#
# ASYMMETRY RULE (hard): "unknown" is NEVER acted on. This probe may only ever
# turn `alive` into `gone`, and only on POSITIVE evidence — the pane's root
# process is a shell AND no harness process exists anywhere in its subtree.
# Absent pid, unreadable `ps`, or an unrecognized command all return `unknown`,
# and every caller maps `unknown` to today's answer.
#
# The subtree walk (not just the foreground command) is load-bearing: a HEALTHY
# claude running a Bash tool shows `bash` as its pane command for the duration of
# that call. Foreground-command-only would call a busy worker dead.
: "${CB_PS_CMD:=ps -eo pid=,ppid=,comm=}"
: "${CB_HARNESS_PATTERN:=^(claude|node)$}"
: "${CB_DEAD_SHELL_PATTERN:=^(-?(ba|z|k|da|fi)?sh|login)$}"
# cb_ps_table — "pid ppid comm" lines. CB_PS_CMD-mockable; failure degrades to
# empty output (which every consumer reads as "cannot tell"), never an error.
_cb_ps_table_uncached() { eval "$CB_PS_CMD" 2>/dev/null || true; }
# _proc_comm PID [TABLE] — that pid's command name, empty if it is not in the
# table. TABLE is the optional pre-read `cb_ps_table` output; passing it keeps
# a single classify pass from spawning `ps` twice per pane (the tick runs across
# every task every 30s — Cerebro-spec §7 advertises it as "a few stats + one
# tmux list", and that claim is worth keeping close to true).
_proc_comm() {
  local tbl="${2-}"; [ -n "$tbl" ] || tbl="$(cb_ps_table)"
  printf '%s\n' "$tbl" | awk -v p="$1" '$1==p{print $3; exit}'
}
# _proc_subtree_has PID PATTERN [TABLE] — 0 if any process in PID's subtree
# (including PID itself) has a comm matching PATTERN; 1 if none; 2 if we CANNOT
# TELL (PID is not in the table at all, e.g. an unreadable ps).
_proc_subtree_has() {
  local tbl="${3-}"; [ -n "$tbl" ] || tbl="$(cb_ps_table)"
  printf '%s\n' "$tbl" | awk -v root="$1" -v pat="$2" '
    { ppid[$1]=$2; comm[$1]=$3 }
    END{
      if (!(root in comm)) exit 2               # cannot tell — never act
      want[root]=1
      do { added=0
        for (p in ppid) if (!(p in want) && (ppid[p] in want)) { want[p]=1; added=1 }
      } while (added)
      for (p in want) if (comm[p] ~ pat) exit 0
      exit 1
    }'
}
# cb_pane_proc_state PANE-PID — harness | dead | unknown. Reads the process
# table ONCE and passes it to both lookups.
cb_pane_proc_state() {
  local pid="${1:-}" tbl rc
  case "$pid" in ''|*[!0-9]*) echo unknown; return;; esac
  tbl="$(cb_ps_table)"
  # `|| rc=$?`, never `cmd; rc=$?` — callers run under `set -e` (cb-watch), and a
  # bare failing command would abort the tick on the not-found path, which is
  # precisely the dead-shell case this function exists to detect.
  rc=0; _proc_subtree_has "$pid" "$CB_HARNESS_PATTERN" "$tbl" || rc=$?
  [ "$rc" -eq 0 ] && { echo harness; return; }
  [ "$rc" -eq 2 ] && { echo unknown; return; }
  if printf '%s' "$(_proc_comm "$pid" "$tbl")" | grep -qE "$CB_DEAD_SHELL_PATTERN"; then
    echo dead
  else
    echo unknown                                 # some other process — not ours to judge
  fi
}
# cb_window_alive SLUG — tmux-window liveness signal for a research task.
# Echoes one of: alive | gone | unavailable.
#   - Honors CB_WINDOW_LIST_CMD exactly like cb-start/cb-adopt do: eval-ed,
#     defaulting to `tmux list-windows -t cb -F '#{window_name}'` (bare
#     slugs, one per line, from the dedicated "cb" tmux session).
#   - Exit 127 from the eval ("command not found") signals UNAVAILABLE — the
#     natural result when the tmux binary itself is missing. This is also
#     the deterministic mechanism tests use to force the fallback path
#     without needing to actually uninstall tmux: point CB_WINDOW_LIST_CMD
#     at a command that exits 127 (e.g. `CB_WINDOW_LIST_CMD="exit 127"`).
#   - Any other exit / output is authoritative: the slug's window is either
#     in the list (alive) or not (gone) — e.g. a real tmux reporting "can't
#     find session cb" is a legitimate GONE, not "can't tell".
#   - R22: name presence is necessary but NOT sufficient — a pane whose root is a
#     shell with no harness process beneath it is `gone`. Every other probe
#     outcome (harness found, pid unknown, ps unreadable) keeps `alive`.
# cb_window_pane_pid SLUG — the pane root pid of the slug's window in the cb
# session. CB_WINDOW_PID_CMD-mockable; literal name match (slugs carry `.`/`-`).
cb_window_pane_pid() {
  local cmd; cmd="${CB_WINDOW_PID_CMD:-tmux list-windows -t cb -F '#{window_name} #{pane_pid}' 2>/dev/null}"
  eval "$cmd" 2>/dev/null | awk -v s="$1" '$1==s{print $2; exit}'
}
_cb_window_alive_uncached() {
  local slug="$1" cmd out rc
  cmd="${CB_WINDOW_LIST_CMD:-tmux list-windows -t cb -F '#{window_name}' 2>/dev/null}"
  out="$(eval "$cmd" 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 127 ]; then echo unavailable; return; fi
  printf '%s\n' "$out" | grep -Fqx "$slug" || { echo gone; return; }
  # R22: the name is present — now demand the harness. `gone` only on positive
  # evidence of a dead shell; anything else keeps the pre-R22 answer (`alive`).
  if [ "$(cb_pane_proc_state "$(cb_window_pane_pid "$slug")")" = "dead" ]; then echo gone; else echo alive; fi
}
# classify_research TASK-DIR — ready-for-review / running / paused / blocked /
# needs-input / failed. Surface-on-ambiguity (R13): silence (running) is earned
# ONLY by a fresh beacon line; anything ambiguous surfaces.
# Priority order:
#   1. report.md terminal frontmatter status wins outright (complete|partial ->
#      ready-for-review, failed -> failed), regardless of window/beacon.
#   2. Beacon last-line state = `paused` (R6): a declared external wait. Two
#      clocks — under CB_PAUSE_RESURFACE_SECS -> `paused` (board-only, never
#      escalated as a wedge); past it -> `needs-input`, resurfacing once so a
#      forgotten pause can't rot invisibly. (Stateless classify resurfaces at
#      the threshold, not on a repeating cadence — cb-watch owns no per-task
#      clock; one resurface satisfies "must not rot".)
#   3. Beacon last-line state = `blocked`: agent declared itself stuck -> blocked.
#   4. Otherwise a working/launch beacon — R9 stall + R13 polarity, keyed on
#      window liveness:
#      - alive: fresh beacon (< CB_STALE_ESCALATE_SECS) -> running (proof);
#        stale/absent -> blocked (live window, no progress signal = wedge-suspect).
#      - gone: launch-race grace only (beacon < CB_LAUNCH_GRACE_SECS -> running);
#        else failed (crashed).
#      - unavailable (can't tell): trust a fresh beacon -> running; else failed.
# cb_window_pane_tail SLUG — last lines of a research task's cb-session WINDOW
# pane (target cb:<slug>, NOT a session's active pane — that's cb_pane_tail's
# job for code tasks). CB_PANE_CMD-mockable (tests point it at a fixture via
# cat); failure/absence degrades to empty output, never an error.
cb_window_pane_tail() {
  local slug="$1" cmd
  cmd="${CB_PANE_CMD:-tmux capture-pane -p -t \"cb:$slug\" 2>/dev/null | tail -40}"
  eval "$cmd" 2>/dev/null || true
}
classify_research() {
  local td="$1"
  local rep="$td/report.md" beacon="$td/status" slug state age="" liveness pane
  slug="$(basename "$td")"
  if [ -f "$rep" ]; then
    case "$(_fm_status "$rep")" in
      complete|partial) echo ready-for-review; return;;
      failed) echo failed; return;;
    esac
  fi
  # (d) pre-spawn / launch-race grace: cb-brief creates the task dir + brief.md;
  # cb-start writes the FIRST beacon only after the window launches. In that gap
  # there is no beacon, no report, and no window yet — must NOT read `failed`
  # (five research spawns false-failed here today). Key the grace on brief.md
  # (else the task dir) mtime: fresh → running (still spinning up); past the
  # grace → failed (a launch that never produced a first beacon). Gated on
  # no-report so a malformed/non-terminal report is not rescued into `running` —
  # it falls through to the liveness arms below, which since 47078ba6 land it on
  # `needs-input`, not `failed`. That is the R13 side-effect, accepted deliberately
  # (Kyle 2026-08-16): a botched frontmatter is not positive evidence the agent
  # died, and `failed` is the one state cb-reap acts on destructively.
  if [ ! -f "$beacon" ] && [ ! -f "$rep" ]; then
    local src="$td"; [ -f "$td/brief.md" ] && src="$td/brief.md"
    if [ $(( $(date +%s) - $(stat -c %Y "$src") )) -lt "$CB_PRESPAWN_GRACE_SECS" ]; then
      echo running
    else
      echo failed
    fi
    return
  fi
  state="$(_beacon_state "$beacon")"
  [ -f "$beacon" ] && age=$(( $(date +%s) - $(stat -c %Y "$beacon") ))
  # R6 — declared pause: authoritative from the beacon, independent of window
  # (a paused agent's pane is idle-but-may-be-alive). Two clocks.
  if [ "$state" = "paused" ]; then
    if [ -n "$age" ] && [ "$age" -ge "$CB_PAUSE_RESURFACE_SECS" ]; then echo needs-input; else echo paused; fi
    return
  fi
  # agent-declared blocked. Finding 2 (2026-08-14): a declared state beats an
  # inference — that precedence is correct and unchanged — but `blocked` used to
  # return unconditionally, with no age check and no liveness check, while
  # `paused` two lines above gets a resurface clock. So a `blocked` the agent
  # never cleared stayed `blocked` forever while the agent kept working.
  # Observed 2026-08-13: uat-cancellation-fund-release-backfill read `blocked`
  # with its pane showing "Crafting… (7m 39s)" over a live Kusto join.
  #
  # Same two clocks `paused` has, plus the pane check the `alive` branch already
  # trusts: past the resurface threshold, or demonstrably busy, promote to
  # needs-input rather than sitting on a stale declaration.
  #
  # ⚠️ Root cause is upstream and this does not fix it — that agent declared
  # blocked, its question was never delivered, and it carried on working. This
  # makes it visible.
  if [ "$state" = "blocked" ]; then
    if [ -n "$age" ] && [ "$age" -ge "$CB_PAUSE_RESURFACE_SECS" ]; then
      echo needs-input; return
    fi
    if printf '%s\n' "$(cb_window_pane_tail "$slug")" | grep -qE "$CB_BUSY_PATTERN"; then
      echo needs-input; return
    fi
    echo blocked; return
  fi
  liveness="$(cb_window_alive "$slug")"
  case "$liveness" in
    alive)
      if [ -n "$age" ] && [ "$age" -lt "$CB_STALE_ESCALATE_SECS" ]; then
        echo running
      else
        # (c) scope-add #2: a stale beacon is a wedge-SUSPECT, but a turn
        # actively in progress (a 5-8 min advisor/architect call) is positive
        # proof of work — not a stall. Consult the pane before escalating.
        pane="$(cb_window_pane_tail "$slug")"
        if printf '%s\n' "$pane" | grep -qE "$CB_BUSY_PATTERN"; then echo running; else echo blocked; fi
      fi;;
    # R13 polarity, extended to the research lane 2026-08-14 (spec
    # 99 Meta/specs/2026-08-13-classify-r13-polarity-design). Both branches below
    # used to `echo failed` on an ABSENCE of evidence, which is the one state
    # cb-reap acts on destructively (cb-reap:178 kills it outright, skipping the
    # unpushed-commit arithmetic, because its comment assumes `failed` means
    # positive terminal evidence). The code lane's quiet-pane branch was fixed
    # for exactly this on 07-27 after it cost two conductors; these are its
    # unfixed siblings.
    #
    # `gone` is genuinely ambiguous: research X-Men are windows in the shared
    # `cb` session, and a window closes when the agent FINISHES as well as when
    # it crashes. `unavailable` is sharper still — it is what cb_window_alive
    # returns when it could not determine liveness at all (tmux did not answer,
    # the ps table was unreadable). Mapping "I don't know" to the destructive
    # state is the inversion R13 exists to stop.
    #
    # `failed` is left to the paths carrying positive evidence: `failed`
    # frontmatter in report.md (above), a DECLINED PR, an OOM signature, and the
    # post-grace no-beacon launch that never produced one.
    gone)
      if [ -n "$age" ] && [ "$age" -lt "$CB_LAUNCH_GRACE_SECS" ]; then echo running; else echo needs-input; fi;;
    unavailable)
      if [ -n "$age" ] && [ "$age" -lt "$CB_STALE_ESCALATE_SECS" ]; then echo running; else echo needs-input; fi;;
  esac
}
# cb_session_present SESSION — per-slug tmux SESSION NAME presence. alive | gone
# | unavailable. This is the NAME-COLLISION question ("is this session name
# taken?"), which is what cb-start's --adopt guard and collision pre-check need:
# a name that exists will make `tmux new-session -d -s <slug>` fail, whether or
# not a harness is running inside it. Kept byte-identical to the pre-R22
# cb_session_alive so those refusals do not change.
cb_session_present() {
  local sess="$1" cmd out rc
  cmd="${CB_SESSION_LIST_CMD:-tmux list-sessions -F '#{session_name}' 2>/dev/null}"
  out="$(eval "$cmd" 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 127 ]; then echo unavailable; return; fi
  if printf '%s\n' "$out" | grep -Fqx "$sess"; then echo alive; else echo gone; fi
}
# cb_session_pane_pids SESSION — the pane root pids belonging to SESSION, one per
# line. CB_SESSION_PID_CMD-mockable; literal name match (session names carry
# `.`/`-`, so this is a string equality, not a regex).
cb_session_pane_pids() {
  local cmd; cmd="${CB_SESSION_PID_CMD:-tmux list-panes -a -F '#{session_name} #{pane_pid}' 2>/dev/null}"
  eval "$cmd" 2>/dev/null | awk -v s="$1" '$1==s{print $2}'
}
# cb_session_alive SESSION — HARNESS liveness for a code task (R22). Name
# presence first (unchanged), then the process probe. A session is `gone` only if
# EVERY pane in it is positively a dead shell; one harness pane — or one pane we
# cannot read — keeps it `alive`. No pane rows at all means we cannot tell, so we
# return today's answer (`alive`), never a downgrade.
_cb_session_alive_uncached() {
  local sess="$1" present pid saw=""
  present="$(cb_session_present "$sess")"
  [ "$present" = "alive" ] || { echo "$present"; return; }
  while read -r pid; do
    [ -n "$pid" ] || continue
    saw=1
    [ "$(cb_pane_proc_state "$pid")" = "dead" ] || { echo alive; return; }
  done < <(cb_session_pane_pids "$sess")
  if [ -n "$saw" ]; then echo gone; else echo alive; fi
}
# cb_pane_tail SESSION — last lines of a code task's pane, for wedge
# detection. CB_PANE_CMD-mockable (point it at a fixture file via cat);
# failure/absence degrades to empty output, never an error.
cb_pane_tail() {
  local sess="$1" cmd
  cmd="${CB_PANE_CMD:-tmux capture-pane -p -t \"$sess:\" 2>/dev/null | tail -40}"
  eval "$cmd" 2>/dev/null || true
}
# Spend-wedge pane signatures — seeded from the real captures in the
# work-watch design (99 Meta/specs/2026-07-12-work-watch-design.md:84):
# spend-limit text, the /usage-credits nudge, the idle new-task prompt, and
# the queued-messages banner. Extend from the next live wedge (plan 2 open
# question: capture the pattern fixture + resume line together).
# Pane discriminators (Kyle-approved 2026-07-16). These REPLACED the old
# CB_WEDGE_PATTERN, which conflated a genuine spend cap with idle chrome
# (`new task? /clear`, the queued-messages banner — both shown by a HEALTHY
# just-finished / awaiting-PR session), causing false blocked/needs-relaunch
# (eja-3600). Defined once; consumed by classify_code, classify_research (c),
# and cb-remediate (b):
#  - CB_SPEND_PATTERN: the genuine account-level spend/usage cap ONLY — the one
#    signal that means "wedged" (→ blocked/needs-relaunch + remediation).
#  - CB_BUSY_PATTERN: a turn actively in progress. Claude Code prints
#    `(esc to interrupt)` for the duration of a running turn — positive proof of
#    work: a long advisor/architect call is not a stall, and a busy pane is not
#    a wedge.
CB_SPEND_PATTERN='monthly spend limit|usage limit reached|/usage-credits'
CB_BUSY_PATTERN='esc to interrupt'
# OOM signatures (T34, §8.5): an exit-137/Killed build in the pane is an
# explicit escalate, never a silent stall.
CB_OOM_PATTERN='exit 137|Killed'
# Interactive-menu signatures (finding-18 / spec item 18): a live Claude Code
# option menu is the agent asking the HUMAN directly — the select-footer
# ("Enter to select · ↑/↓ to navigate") and/or the "❯ N." option list. This is
# NOT a conductor phase gate (current_task is not */awaiting-approval), so
# without a signature it falls through to the wedge/failed heuristics and a
# genuine decision reads failed/blocked. A live session at a menu is always
# needs-input.
CB_MENU_PATTERN='Enter to select|❯ [0-9]'
# ⚠️ CLAUDE CODE'S OWN PRODUCT PROMPTS RENDER IN THE SAME SHAPE AND ARE NOT GATES.
# The comment above is precise about intent — "the agent asking the HUMAN directly"
# — but `❯ [0-9]` cannot tell an agent's question from the harness's onboarding
# chrome. Measured 2026-08-14 22:01 MT: the conductor `deterministic-report-landing`
# was classified `needs-input` while its pane read `✻ Waiting for 1 background agent
# to finish` and a subagent had been running 16 minutes. The only thing that matched
# was Claude Code's own "Set up auto mode for your environment?" prompt and its
# `❯ 1. Set it up` list. The menu test runs BEFORE the busy test by design (so a real
# gate is never buried as `running`), so the chrome beat the positive proof of work.
#
# Cost: a false "needs you" on Kyle's board for a conductor that needs nothing, which
# is the same class as the 1,537 voicemode warnings — an alert true of the pixels and
# false of the thing it names.
#
# Fix is to NARROW the pattern's input, not to reorder the checks and not to add an
# ignore-list downstream: strip harness chrome from the pane, then apply the unchanged
# menu test to what remains. A real agent menu appearing alongside the chrome still
# matches, because only the chrome block is removed. Same move as CB_SPEND_PATTERN
# being narrowed off idle chrome (2026-07-16).
CB_MENU_CHROME_PATTERN='Set up auto mode for your environment|Auto mode lets Claude act without asking first'
CB_MENU_CHROME_END_PATTERN='Enter to confirm · Esc to cancel'
# _strip_menu_chrome — drop harness prompt blocks (title → footer) from a pane dump.
_strip_menu_chrome() {
  awk -v s="$CB_MENU_CHROME_PATTERN" -v e="$CB_MENU_CHROME_END_PATTERN" '
    !skip && $0 ~ s { skip=1; next }
    skip && $0 ~ e  { skip=0; next }
    !skip'
}
# --- conductor phase-gate vocabulary -----------------------------------------
# The manifest's `current_task` is FREE TEXT a model writes, not a fixed
# vocabulary. The gate sentinel used to be the literal suffix
# `*/awaiting-approval`, which across 1,600 live manifest values matched
# exactly ONE. A predicate with a 1-in-1600 hit rate that gates a delivery is
# indistinguishable from "no conductor is ever at a gate" — the audit's central
# finding, in the classifier itself.
#
# So match on what a gate MEANS, not on the phase prefix. Widening by prefix
# instead ("any ship/* or review/* is a gate") was considered and rejected:
# `ship/complete` alone accounts for 791 of those 1,600 values and
# `ship/3-pull-request` another 170, so prefix-widening would have flooded the
# board's "Needs you" with completed and mid-flight work.
#
# Gate = the conductor is waiting on a human.
# `gate` needs delimiters — bare `gate` matches "investi-gate" (spec/2-investigate).
CB_GATE_PATTERN='await|approval|paused|pending|blocked|(^|[-/])gate([-/]|$)|(^|[-/])hold'
# Progress/terminal = the conductor is working or done; never a gate. Numbered
# steps (`ship/3-pull-request`, `review/2-cycle-02`) and `*/complete`.
# `(^|/)complete$` not `/complete$` — a BARE `complete` with no phase prefix was
# `unknown`. Measured 2026-08-14 on the live conductor `inbox-consolidation-drain-loop`,
# which was parked at a human gate carrying exactly that value, which is the shape the
# canary warns about: an unclassified value falls through to the pane heuristics and a
# paused conductor reads as work. `work/complete` and `ship/complete` already matched;
# only the un-prefixed form did not.
CB_PROGRESS_PATTERN='(^|/)complete$|/[0-9]'
# cb_gate_vocab_class VALUE — gate | progress | unknown. `unknown` is the CANARY:
# vocabulary neither pattern has an opinion about. It is surfaced, never guessed
# at — same discipline as the decision-log verb audit. Gate wins over progress
# so `ship/3-gate` reads as the gate it is.
cb_gate_vocab_class() {
  [ -n "$1" ] || { echo unknown; return; }
  # Strip a trailing `#` comment and surrounding whitespace before matching.
  # `current_task` is free text a model writes, and a conductor that annotates its
  # value — `work/complete   # work/extract-… done 2026-08-05` — defeats every
  # END-ANCHORED alternative in CB_PROGRESS_PATTERN. Measured 2026-08-14: that
  # exact value classified `unknown` while the bare `work/complete` classified
  # `progress`, so the comment alone was the difference. A comment is annotation,
  # not vocabulary; it should never reach the patterns.
  local v="${1%%#*}"
  v="$(printf '%s' "$v" | sed 's/[[:space:]]*$//')"
  [ -n "$v" ] || { echo unknown; return; }
  # GATE IS TESTED FIRST AND STAYS FIRST. Widening the progress side can therefore
  # never mask a gate — a value matching both reads `gate`. That asymmetry is what
  # makes the progress widening below safe, and it is why the gate pattern is NOT
  # widened here: a false gate parks a live conductor, a false progress does not.
  printf '%s' "$v" | grep -qiE "$CB_GATE_PATTERN"     && { echo gate;     return; }
  printf '%s' "$v" | grep -qiE "$CB_PROGRESS_PATTERN" && { echo progress; return; }
  echo unknown
}
# --- the DECLARED gate field (conductor-gate-signal) -------------------------
# Everything above this line infers a gate from `current_task`, which is free
# text. That inference is a heuristic with an unbounded vocabulary: cb-guard's
# `unknown` canary exists precisely because a conductor can improvise wording no
# pattern has an opinion about, and until someone widens the regex that gate is
# invisible. Widening is a fix for yesterday's wording, never tomorrow's.
#
# `gate:` is the conductor DECLARING the gate instead of the watcher guessing at
# it. Three things follow that the heuristic cannot do:
#   1. It carries the QUESTION (`gate_question`) and the answer set
#      (`gate_options`), so the board and the digest can show what is actually
#      being asked rather than a step slug. task_gate below is where that lands.
#   2. It distinguishes the three waits the heuristic collapses into one.
#      CB_GATE_PATTERN matches `paused` and `blocked` — and then routes both to
#      needs-input, so a declared external wait and a hard blocker are
#      indistinguishable from a Kyle decision. Code tasks had no `paused` path at
#      all before this.
#   3. It never touches `current_task`, which is the RESUME POINTER
#      (work-conductor/SKILL.md documents it as "points to NEXT task" and
#      fast-forwards to it on resume). The pre-existing convention overwrote it
#      with `<phase>/awaiting-approval` and relied on the model remembering the
#      real value across the wait — a resumed conductor that lost that value has
#      no matching step to fast-forward to.
#
# POSITIVE-ONLY, same polarity as the old sentinel: a `gate:` on a DEAD session
# does not rescue it from `failed`. `paused` is the one exception, and it is
# deliberate — see _paused_or_resurface.
#
# _paused_or_resurface RUN MANIFEST — R6's two-clock, for code. A bare
# `echo paused` would silently reintroduce the rot classify.sh exists to prevent:
# a forgotten pause that never resurfaces is invisible forever. Under
# CB_PAUSE_RESURFACE_SECS the declared pause holds (board-visible, never a
# wedge, never remediated); past it the pause resurfaces ONCE as needs-input so a
# human sees it. Liveness-independent, mirroring classify_research: a paused
# conductor's session may or may not have outlived the wait, and `failed` is the
# one verdict cb-reap acts on destructively, so an unprovable death is never
# asserted here (R13).
#
# THE CLOCK IS `gate_since`, NOT THE MANIFEST MTIME. Mtime measures the last write
# to the file, and a declared pause does not stop the conductor writing: cb-brief
# tells every agent that asking is not finishing, so a conductor waiting on an
# external clear is expected to keep working independent tasks and to advance
# `current_task` as it does. Each of those writes would reset an mtime clock, and
# the pause would never resurface — precisely the rot the two-clock exists to
# kill. `gate_since` is stamped once when the gate is declared, so the clock runs
# from the declaration however many times the manifest moves afterwards.
#
# No `gate_since` (a conductor that declared the gate but not its timestamp) falls
# back to the mtime. Weaker, and deliberately not an error: a pause with a
# resettable clock still surfaces on the board, and refusing to classify would
# lose the state entirely.
_paused_or_resurface() {
  local run="$1" manifest="$2" since ts now age
  now=$(date +%s)
  since="$(manifest_field "$run" gate_since)"
  ts=""
  [ -n "$since" ] && ts="$(date -d "$since" +%s 2>/dev/null || true)"
  case "$ts" in ''|*[!0-9]*) ts="$(stat -c %Y "$manifest" 2>/dev/null || echo "$now")";; esac
  age=$(( now - ts ))
  if [ "$age" -ge "$CB_PAUSE_RESURFACE_SECS" ]; then echo needs-input; else echo paused; fi
}
# _meta_field TASK-DIR KEY — one key=value line from the task-dir meta file
# (written by cb-start --code: kind/worktree/jira/session).
_meta_field() {
  awk -F= -v k="$2" '$1 == k { sub("^" k "=", ""); print; exit }' "$1/meta" 2>/dev/null
}
# classify_code TASK-DIR — done|ready-for-review|needs-input|paused|blocked|
# needs-relaunch|running|failed.
# Priority (plan 2 T18; `blocked` arrives with M6):
#   1. pr.state = MERGED                      -> done (beats everything)
#   2. summary.md AND pr both exist           -> ready-for-review. summary.md alone
#      does NOT short-circuit (Finding 3, 47078ba6) — it rested on an ordering
#      guarantee nothing enforced, so an unshipped summary read as shipped.
#   3. manifest `gate:` declared by the conductor -> needs-input | blocked |
#      paused, then the current_task inference (cb_gate_vocab_class) as the
#      fallback for a conductor that declared nothing. Both are POSITIVE signals
#      only — with a dead session neither rescues the task from failed, per the
#      dev item's locked constraints. `gate: paused` is the one exception and it
#      is deliberate (see _paused_or_resurface).
#   4. session alive + manifest fresh (< CB_CODE_STALL_SECS) -> running.
#      A missing manifest with a live session is also running — the conductor
#      hasn't booted far enough to write one; the session IS the signal.
#      Degraded-but-safe pre-sentinel interim: a gated conductor stays
#      "running" (never falsely failed) until the sentinel ships.
#   5. else failed — but only from positive evidence: a session confirmed `gone`
#      with no declared-open decision, a DECLINED PR, an OOM signature. Session
#      liveness UNAVAILABLE means we could not tell, so it degrades to the
#      manifest-mtime rule and lands on `needs-input`, never `failed` (R13 Finding
#      1, 47078ba6). Same polarity as classify_research.
# _relaunch_or_blocked TD — M6 req 3. A wedge that has exhausted its
# auto-remediation cap and is STILL wedged is not "blocked" (being retried) —
# it is a distinct human-action state: the robot gave up, a human must
# relaunch. Reached only from the wedge path (so cap + still-wedged is real).
_relaunch_or_blocked() {
  local n; n="$(cat "$1/remediation-count" 2>/dev/null || echo 0)"
  case "$n" in ''|*[!0-9]*) n=0;; esac
  if [ "$n" -ge "$CB_REMEDIATE_CAP" ]; then echo needs-relaunch; else echo blocked; fi
}
classify_code() {
  local td="$1" wt run manifest sess liveness cur gate_state fresh=""
  [ -f "$td/done" ] && { echo done; return; }   # cb-cleanup's marker (covers --force reaps with no merged PR)
  case "$(cat "$td/pr.state" 2>/dev/null)" in
    MERGED) echo done; return;;
    DECLINED) echo failed; return;;   # cb-merge --poll saw a declined PR
  esac
  # Finding 3 — PINNED 2026-08-14 (Kyle: "proceed"; option (a) of the spec).
  # This shortcut sits above every liveness and gate check, so it decides
  # `ready-for-review` before anything can contradict it. It used to key on
  # summary.md alone, which rested on an ordering guarantee NOTHING enforces:
  # on 2026-08-13 it was safe only because summary.md happened to be written
  # 20ms after `pr`. cb-watch:49 already reads the two as independent signals.
  # A conductor that writes its summary before opening a PR would have marked
  # unshipped work ready-for-review, with the gate check that would have caught
  # it sitting below.
  #
  # Requiring `pr` alongside makes the guarantee explicit. Without it, fall
  # through to the gate and liveness checks rather than short-circuiting — a
  # summary with no PR is not shipped, and the checks below can say what it is.
  [ -f "$td/summary.md" ] && [ -f "$td/pr" ] && { echo ready-for-review; return; }
  wt="$(_meta_field "$td" worktree)"
  sess="$(_meta_field "$td" session)"; [ -n "$sess" ] || sess="$(basename "$td")"
  liveness="$(cb_session_alive "$sess")"
  manifest=""
  if [ -n "$wt" ] && run="$(resolve_run "$wt" "$(basename "$td")" "$(_meta_field "$td" jira)" 2>/dev/null)"; then
    manifest="$run/manifest.md"
  fi
  if [ -n "$manifest" ] && [ -f "$manifest" ]; then
    cur="$(manifest_field "$run" current_task)"
    if [ $(( $(date +%s) - $(stat -c %Y "$manifest") )) -lt "$CB_CODE_STALL_SECS" ]; then fresh=1; fi
    # A DECLARED gate beats the inference. Terminal states above (done /
    # ready-for-review) still beat both — a shipped task must never re-open a
    # decision — so this sits after them and before every heuristic.
    gate_state="$(manifest_field "$run" gate)"
    case "$gate_state" in
      needs-input) [ "$liveness" = "alive" ] && { echo needs-input; return; };;
      blocked)     [ "$liveness" = "alive" ] && { _relaunch_or_blocked "$td"; return; };;
      paused)      _paused_or_resurface "$run" "$manifest"; return;;
    esac
    # Fallback: infer from current_task. Load-bearing for as long as any
    # conductor in the fleet predates the `gate:` convention, and permanently for
    # one that forgets to declare.
    if [ "$(cb_gate_vocab_class "$cur")" = gate ] && [ "$liveness" = "alive" ]; then
      echo needs-input; return
    fi
  fi
  case "$liveness" in
    alive)
      local pane; pane="$(cb_pane_tail "$sess")"
      # finding-18: an interactive Claude Code menu means the agent is asking
      # the human directly. Surface needs-input whenever the session is alive,
      # BEFORE the fresh->running shortcut and BEFORE any wedge/oom/stall
      # heuristic — so a live menu never reads running (decision buried until
      # stall), failed, blocked, or needs-relaunch (the M6 mislabel: a
      # human-gated-idle task is not a dead wedge).
      # Chrome-stripped: Claude Code's own onboarding prompts render as `❯ N.` lists
      # and are not the agent asking anything. See CB_MENU_CHROME_PATTERN.
      if printf '%s\n' "$pane" | _strip_menu_chrome | grep -qE "$CB_MENU_PATTERN"; then
        echo needs-input; return
      fi
      # (Kyle-approved 2026-07-16) a turn actively in progress (esc to interrupt)
      # is positive proof of work, not a stall — running whenever alive, even on
      # a stale manifest (code parallel of the research (c) fix).
      if printf '%s\n' "$pane" | grep -qE "$CB_BUSY_PATTERN"; then
        echo running; return
      fi
      if [ -z "$manifest" ] || [ ! -f "$manifest" ] || [ -n "$fresh" ]; then
        echo running
      else
        if printf '%s\n' "$pane" | grep -qE "$CB_OOM_PATTERN"; then
          # OOM-killed build (T34, §8.5): explicit escalate — the marker lets
          # cb-watch tag the failed event as (oom), never a silent stall
          touch "$td/oom-detected" 2>/dev/null || true
          echo failed
        elif printf '%s\n' "$pane" | grep -qE "$CB_SPEND_PATTERN"; then
          # live session, stale manifest, GENUINE spend banner in the pane —
          # blocked (M6): needs-input (sentinel/menu) beats blocked beats failed;
          # an exhausted remediation cap promotes this to needs-relaunch.
          # Narrowed to CB_SPEND_PATTERN (Kyle 2026-07-16): the idle chrome the
          # old CB_WEDGE_PATTERN also matched (`new task? /clear`, queued-messages
          # banner) is NOT a wedge — a healthy just-finished / awaiting-PR session
          # shows it — so idle-chrome-only now falls through to failed, never a
          # false blocked/needs-relaunch (eja-3600).
          _relaunch_or_blocked "$td"
        else
          # A LIVE session, a manifest that hasn't moved, and a quiet pane. That
          # is three different states wearing the same clothes: paused at a gate,
          # crashed mid-turn, or idle after finishing. A quiet pane cannot tell
          # them apart — and `failed` is the only one of the three that cb-reap
          # acts on destructively (cb-reap:178 kills a `failed` session outright,
          # skipping the unpushed-commit arithmetic entirely, because its comment
          # assumes `failed` means positive terminal evidence). It did not: this
          # branch reached it on an ABSENCE of evidence, and it cost two
          # conductors the week of 07-27 — one killed at the ship gate, one at
          # review/2-cycle-02 with 3 unpushed commits.
          #
          # R13 polarity: a state you cannot positively establish is never acted
          # on. needs-input is human-visible (board bucket + digest), cb-reap
          # keeps it, and cb-remediate leaves it alone. The positive-evidence
          # `failed` paths above (DECLINED PR, OOM signature) are untouched, as
          # is `failed` for a session that is actually gone.
          echo needs-input
        fi
      fi;;
    # A code task whose session is gone is NOT automatically a failure.
    #
    # cb-start gives every code conductor a DEDICATED tmux session whose only
    # window IS the agent (`launch.sh` execs claude; `remain-on-exit` is off).
    # So when a conductor calls cb-ask — declaring its question, ending its turn
    # and exiting — that exit destroys the session. The polite, correct outcome
    # of "the worker asked Kyle something" therefore landed here and was
    # labelled `failed`, burying a live question under a corpse. (Research/ops
    # X-Men never hit this: they are windows inside the shared `cb` session,
    # which has a persistent bash window, so their pane closing costs nothing.)
    #
    # A still-open DECLARED decision is positive evidence the worker ASKED
    # rather than crashed — cb-ask is the only writer of `declared`. Surface
    # that as needs-input: the board already buckets it, cb-digest already pages
    # it, and cb-remediate (blocked-only) still leaves it alone. Recovery is
    # `cb-start --code --adopt <slug>`; the worktree, branch, commits, beacon and
    # manifest all survive the session.
    #
    # No declared decision -> a genuine crash. Unchanged: failed.
    # (2026-07-30. The lifecycle itself — keeping the session alive past the
    # agent — is deliberately NOT changed here; that needs cb-start's two
    # name-presence refusals and cb-send's blind-send path to move together.)
    gone) if _has_declared_open "$td"; then echo needs-input; else echo failed; fi;;
    # R13 polarity (2026-08-14) — the third site from the spec's table, and the
    # sharpest of the three: `unavailable` is what cb_session_alive returns when
    # it COULD NOT DETERMINE liveness. A stale manifest on top of that is still
    # not evidence the task died; it is two absences stacked. cb-reap:178 kills
    # `failed` outright, so this branch could destroy a live conductor's
    # unpushed work on the strength of tmux not answering.
    #
    # `gone` above is deliberately untouched: a session confirmed absent WITH no
    # declared-open decision is positive evidence, and `_has_declared_open`
    # already rescues the cb-ask case.
    unavailable)
      if [ -n "$fresh" ]; then echo running; else echo needs-input; fi;;
  esac
}
# classify TASK-DIR — kind dispatch, so cb-watch/cb-board stay one-call.
# meta kind=code -> classify_code; anything else (incl. no meta) -> research.
classify() {
  if [ "$(_meta_field "$1" kind)" = "code" ]; then classify_code "$1"; else classify_research "$1"; fi
}
# task_gate TASK-DIR — what a code task is waiting on (empty for research /
# unresolvable runs). Feeds the event dedup key, the board's "what it's waiting
# on" display, and cb-stuck. It NO LONGER decides whether a decision exists —
# `_decision_for` does, and it requires a declared `gate:`/`gate_question:`,
# because the `current_task` value below is a resume pointer (cb-brief:66).
#
# `gate_question` when the conductor declared one, else `current_task`. That
# preference is the whole point of the field: a step slug (`ship/3-gate`) tells
# Kyle a conductor is stopped, and nothing more, so the board line, the decision
# key and the digest entry all carried a position instead of a question.
#
# On the key: _decision_key hashes (state, gate), so a task whose gate string
# changes gets a NEW key while the old one stays open. Two things bound that.
# cb-send:354 resolves EVERY open key for a slug on delivery, so the first answer
# closes the orphan along with the live one; and a `resolved` on a projected key
# is now durable (_CB_FOLD_BODY's `open` arm), so the superseded key cannot come
# back.
#
# The re-keying that actually bit was NOT gate_question churn. It was the
# `current_task` fallback: `ship/complete` is a fixed string, so the key never
# changed and every `resolved` was overwritten by the next tick's `open`. The
# comment that used to sit here — "no manifest carries `gate_question` yet, so
# nothing re-keys today" — pointed a reader away from that, and manifests do
# carry `gate_question` now.
task_gate() {
  local td="$1" wt run q
  [ "$(_meta_field "$td" kind)" = "code" ] || return 0
  wt="$(_meta_field "$td" worktree)"; [ -n "$wt" ] || return 0
  run="$(resolve_run "$wt" "$(basename "$td")" "$(_meta_field "$td" jira)" 2>/dev/null)" || return 0
  q="$(manifest_field "$run" gate_question)"
  if [ -n "$q" ]; then printf '%s\n' "$q"; else manifest_field "$run" current_task; fi
}
# =============================================================================
# BOARD VERIFY-MARKERS — liveness memo, per-key originating verb, markers
# =============================================================================
# Everything below is ADDITIVE. The only edits above this line are three
# function definitions renamed in place to `_cb_*_uncached` (their memoizing
# public wrappers live here), the CB_DECISION_AGE_WARN_SECS default, and one
# corrected header comment.
#
# WHY MARKERS EXIST. Every input cb-board renders is written by the task ABOUT
# ITSELF — the status beacon, the decision log — so a dead worker's question
# outlives the worker and reads exactly like a live one. The markers are the one
# part of a decision line the board establishes for itself, out of band from the
# task's own claims: is anything still running, how old is the question, is
# there a PR already waiting.
#
# FAIL-SAFE TO SILENT. Unknown or unreadable evidence renders NO marker, never a
# reassuring one. `unavailable` liveness (no tmux binary) marks nothing; an
# absent or unparseable open timestamp marks nothing; a missing pr.state marks
# nothing. An absent marker means "not established", never "checked and fine" —
# so a broken probe degrades the board to today's output rather than lying.

# --- epoch-scoped liveness memo ----------------------------------------------
# Computing a marker resolves liveness a SECOND time for a task classify already
# resolved once, and each resolution shells out to tmux AND runs a full `ps -eo`.
# Across 256 tasks that is a second ~6s on a render already costing ~6s of a 30s
# tick, so the markers only pay for themselves with a memo underneath them.
#
# OPT-IN AND EPOCH-SCOPED are both hard requirements. `cb-watch --loop` is a
# single long-lived process calling its tick every 30 seconds forever; a
# process-lifetime memo there would freeze liveness permanently, which is the
# exact bug class the markers exist to kill. So the memo is OFF unless a caller
# explicitly opens an epoch, and with no epoch open each wrapper calls straight
# through to its `_uncached` body — behaviour identical to before the memo, which
# is also what leaves the suite's CB_PS_CMD / CB_SESSION_LIST_CMD /
# CB_WINDOW_LIST_CMD mocks working untouched. cb-board opens one epoch per
# render; cb-watch is deliberately not touched.
#
# THE STORE IS A DIRECTORY, NOT A SHELL ARRAY — and that is forced, not a taste
# call. Every liveness resolution in this system happens inside a command
# substitution: cb-board runs `$(classify "$td")`, `< <(_open_decisions_aged …)`
# and `$(cb_decision_markers …)`, cb-start runs `$(cb_session_alive "$slug")`,
# and so on down the callers. Each of those forks a subshell, so an in-memory
# memo would be WRITTEN in the subshell and thrown away when it exits — measured
# 2026-08-03: an associative-array version cached nothing at all and every call
# still shelled out. A file per key survives the fork, and reading it back is the
# `$(<file)` builtin, which costs no process.
#
# HIT IS FILE PRESENCE, NOT A NON-EMPTY VALUE. `cb_ps_table`'s documented
# degraded result is the empty string, so a truthiness test would silently
# re-shell on exactly the failing path, where the cost matters most and no test
# would notice.
_CB_LIVE_EPOCH=""   # non-empty = the current epoch's memo dir
# cb_liveness_epoch_begin / _end — open and close one sampling epoch. `begin`
# closes any epoch already open, so an epoch can never inherit a previous one's
# readings; `end` removes the dir, so nothing survives to a later epoch either.
cb_liveness_epoch_begin() {
  cb_liveness_epoch_end
  _CB_LIVE_EPOCH="$(mktemp -d "${TMPDIR:-/tmp}/cb-liveness.XXXXXX" 2>/dev/null || true)"
  return 0
}
cb_liveness_epoch_end() {
  [ -n "${_CB_LIVE_EPOCH:-}" ] && [ -d "$_CB_LIVE_EPOCH" ] && rm -rf "$_CB_LIVE_EPOCH" 2>/dev/null
  _CB_LIVE_EPOCH=""
  return 0
}
# _cb_memo_run KEY CMD... — CMD's stdout, cached under KEY for the open epoch.
# No epoch, no usable memo dir, or a cache file we cannot create → straight
# call-through. Never fails: the fallback on every degraded path is the uncached
# answer, never an empty one (an empty liveness string would classify as nothing
# at all, which is worse than an uncached probe).
_cb_memo_run() {
  local key="$1"; shift
  local dir="${_CB_LIVE_EPOCH:-}" f v sk
  { [ -n "$dir" ] && [ -d "$dir" ]; } || { "$@"; return 0; }
  # A key that is not already a safe filename is not cached at all. Sanitising it
  # instead would let two differently-named sessions share one entry, and a
  # cross-fed liveness verdict is exactly the lie the markers exist to prevent.
  sk="${key//[^A-Za-z0-9._-]/_}"; [ "$sk" = "$key" ] || { "$@"; return 0; }
  f="$dir/$sk"
  if [ ! -e "$f" ]; then
    "$@" > "$f" || true
    [ -e "$f" ] || { "$@"; return 0; }
  fi
  v="$(<"$f")"
  [ -n "$v" ] && printf '%s\n' "$v"   # an empty cached result prints nothing, as the uncached body does
  return 0
}
cb_ps_table()      { _cb_memo_run "ps"        _cb_ps_table_uncached; }
cb_session_alive() { _cb_memo_run "sess.$1"   _cb_session_alive_uncached "$1"; }
cb_window_alive()  { _cb_memo_run "win.$1"    _cb_window_alive_uncached "$1"; }

# --- per-key originating verb -------------------------------------------------
# _decision_verb TD KEY — declared | open | empty.
#
# A dead session is not one thing, and the verb is what tells the two apart.
# `classify_code` reaches needs-input from a GONE session precisely when a
# `declared` key is open: cb-ask ends the agent's turn, and a code conductor's
# tmux session dies with its turn. So on a declared decision, session-gone means
# the worker asked and exited cleanly — the highest-fidelity questions on the
# board. On a heuristic `open` key it means corpse. One glyph for both would tell
# Kyle to distrust exactly the lines he should trust.
#
# Folded the same way _open_heuristic_keys folds: any `declared` line for the key
# wins, else `open` if it has one, else empty. Read-only.
_decision_verb() {
  local log; log="$(_decision_log "$1")"; [ -f "$log" ] || return 0
  awk -v k="$2" '$3!=k{next} $2=="declared"{d=1} $2=="open"{o=1}
       END{ if (d) print "declared"; else if (o) print "open" }' "$log" 2>/dev/null || true
}

# --- one key's open timestamp --------------------------------------------------
# cb_decision_open_ts TD KEY — the ISO timestamp of KEY's last `open`/`declared`
# line, empty when the key is not in the log (the live-projection path).
#
# This exists so cb-board can keep reading `open_decisions_live` for its
# bucketing. `_open_decisions_aged` returns the same set WITH this timestamp
# already attached and was the obvious thing to switch to — but it calls
# `open_decisions_live` internally, and both run `_decision_verb_audit`, so the
# board would audit three times per task instead of the two it already does. On
# the 165 live tasks that own a decisions log that measured +0.27s of a 6.1s
# render, for a field only the ~12 rendered lines actually need. One awk per
# rendered line is the cheaper shape by an order of magnitude.
cb_decision_open_ts() {
  local log; log="$(_decision_log "$1")"; [ -f "$log" ] || return 0
  awk -v k="$2" '($2=="open"||$2=="declared")&&$3==k{t=$1} END{if (t!="") print t}' "$log" 2>/dev/null || true
}

# --- marker computation --------------------------------------------------------
# cb_decision_markers TD KEY [OPEN_TS] — one space-joined marker string, empty
# when nothing qualifies. OPEN_TS is the decision log's open-line ISO timestamp
# and MAY be empty: cb-board's live-projection path renders a needs-input that
# has not been written to the log yet, and that path has no age to report.
#
#   📨 asked & exited   liveness `gone` and the key's originating verb is declared
#   ⚰ no session        liveness `gone` and the verb is the watcher's heuristic
#   ⏳ <N>d              logged open age >= CB_DECISION_AGE_WARN_SECS, whole days
#   🔀 pr <STATE>        pr.state exists and is not MERGED
#
# No PR-merged marker: pr.state=MERGED makes _task_terminal `hard`, which drops
# the task out of open_decisions_live entirely — a merged task has no decision
# line to mark. OPEN and DECLINED are the reachable states, and they carry the
# more useful signal anyway (the work exists and is waiting on a human).
#
# Runs once per rendered decision line, and on this board a fork costs ~10ms, so
# it reads `meta` and `pr.state` with builtins rather than the usual awk/cat
# helpers. Same values, four fewer processes per line.
cb_decision_markers() {
  local td="$1" key="${2-}" ts="${3-}" slug kind="" sess="" liveness verb out="" epoch now age prs line
  slug="${td%/}"; slug="${slug##*/}"
  if [ -f "$td/meta" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in kind=*) kind="${line#kind=}";; session=*) sess="${line#session=}";; esac
    done < "$td/meta"
  fi
  if [ "$kind" = "code" ]; then
    [ -n "$sess" ] || sess="$slug"   # same fallback as classify_code
    liveness="$(cb_session_alive "$sess")"
  else
    liveness="$(cb_window_alive "$slug")"
  fi
  # Only `gone` speaks. `alive` says nothing (the line is honest as it stands)
  # and `unavailable` is "cannot tell", which must never render as either.
  #
  # A gone session with NO logged verb also renders nothing, and that case is
  # real: cb-board's live-projection path keys off _decision_for, whose key was
  # never written to the log. The verb is the whole discriminator between "the
  # worker asked and exited" and "corpse", so with no verb there is nothing to
  # discriminate on — and guessing corpse put both glyphs on the same dead
  # session of eja-3645 in the 2026-08-03 render, telling Kyle to trust and
  # distrust one session at once. Unknown evidence renders nothing.
  if [ "$liveness" = "gone" ]; then
    case "$(_decision_verb "$td" "$key")" in
      declared) out="📨 asked & exited";;
      open)     out="⚰ no session";;
    esac
  fi
  if [ -n "$ts" ]; then
    epoch="$(date -d "$ts" +%s 2>/dev/null || true)"
    case "$epoch" in ''|*[!0-9]*) epoch="";; esac   # unparseable → no age marker, never a guess
    if [ -n "$epoch" ]; then
      now="${EPOCHSECONDS:-$(date +%s)}"; age=$(( now - epoch ))
      if [ "$age" -ge "${CB_DECISION_AGE_WARN_SECS:-259200}" ]; then
        out="${out:+$out }⏳ $(( age / 86400 ))d"
      fi
    fi
  fi
  prs=""; [ -f "$td/pr.state" ] && prs="$(<"$td/pr.state")"
  prs="${prs//[$'\r\n']/}"
  if [ -n "$prs" ] && [ "$prs" != "MERGED" ]; then out="${out:+$out }🔀 pr $prs"; fi
  printf '%s' "$out"
}
