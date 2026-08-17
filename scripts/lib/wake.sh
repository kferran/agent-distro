# lib/wake.sh — R4 durable wake queue + drain-at-start.
#
# Cerebro's escalations are keystrokes into the coordinator session. That pane
# can die: cerebro.timer recreates it on a ~2-minute cadence, so there is a
# window where an event fires, lands in logs/events, and nothing ever makes the
# coordinator read it. cb-adopt reports task and session state on restart, but
# never "here are the escalations you never acknowledged."
#
# The invariant is literal, and narrower than it first looks: every wake is
# written here BEFORE the suppression marker advances. Enqueueing only when
# delivery is deferred would close the wrong window — cb_coord_send returning 0
# means send-keys succeeded, not that a coordinator ever read the composer.
# The hole R4 exists for is: escalation decided -> `.notified` advanced ->
# coordinator dies before reading. So the enqueue is unconditional.
#
# Nothing auto-acknowledges either. An entry lives until a coordinator DRAINS
# it, because the drain is the acknowledgement — the same reason firstmate runs
# its drain at the start of every wake-handling and recovery turn.
: "${CB_HOME:=$HOME/.cerebro}"
: "${CB_WAKE_QUEUE:=$CB_HOME/state/wake-queue}"

_cb_wake_lock() { mkdir -p "$CB_HOME/locks"; printf '%s/locks/wake.lock' "$CB_HOME"; }

# cb_wake_enqueue SLUG STATE GATE HASH MSG — record one wake. flock'd because
# concurrent watch ticks appending to the same file can interleave a partial
# line, and a torn line is a lost signal.
cb_wake_enqueue() {
  local slug="$1" state="$2" gate="${3:-}" hash="${4:-}" msg="${5:-}" q lk
  q="$CB_WAKE_QUEUE"; lk="$(_cb_wake_lock)"
  mkdir -p "$(dirname "$q")" || return 1
  {
    flock 6
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -Is)" "$slug" "$state" "$gate" "$hash" "$msg" >> "$q"
  } 6>"$lk"
}

# cb_wake_stage — atomically take the queue aside for reading, echoing the
# staged path. Under the writers' lock, so an enqueue racing the drain lands in
# a fresh queue instead of a file that is about to be deleted. Returns 1 when
# there is nothing to drain.
cb_wake_stage() {
  local q="$CB_WAKE_QUEUE" lk staged rc=1
  lk="$(_cb_wake_lock)"; mkdir -p "$(dirname "$q")"
  staged="$q.draining.$$"
  {
    flock 6
    # Re-absorb stragglers first: a drain killed mid-flight leaves its staged
    # file on disk, and those wakes are exactly the ones that must not be lost.
    for f in "$q".draining.*; do
      [ -f "$f" ] || continue
      [ "$f" = "$staged" ] && continue
      cat "$f" >> "$q" 2>/dev/null && rm -f "$f"
    done
    if [ -s "$q" ]; then mv -f "$q" "$staged" && rc=0; fi
  } 6>"$lk"
  [ "$rc" -eq 0 ] && printf '%s' "$staged"
  return $rc
}

# cb_wake_restore STAGED — put a staged file back on the queue. The failure path
# for a drain that could not emit; losing the wake is worse than paging twice.
cb_wake_restore() {
  local staged="$1" q="$CB_WAKE_QUEUE" lk
  [ -f "$staged" ] || return 0
  lk="$(_cb_wake_lock)"
  { flock 6; cat "$staged" >> "$q" && rm -f "$staged"; } 6>"$lk"
}

# cb_wake_format STAGED — render the drained wakes. Deduped on
# (slug,state,gate,hash) keeping the first sighting, with a count when an event
# was queued more than once, so a flapping task reads as one line and not forty.
cb_wake_format() {
  local staged="$1" n
  n="$(awk -F'\t' '{k=$2"|"$3"|"$4"|"$5; if (!(k in seen)) {seen[k]=1} } END {print length(seen)+0}' "$staged")"
  [ "${n:-0}" -gt 0 ] || return 0
  printf '⚠ %s unacknowledged escalation(s) queued while no coordinator was reading:\n' "$n"
  awk -F'\t' '
    { k=$2"|"$3"|"$4"|"$5
      if (!(k in seen)) { seen[k]=1; order[++i]=k; ts[k]=$1; slug[k]=$2; st[k]=$3; gate[k]=$4; msg[k]=$6 }
      cnt[k]++ }
    END { for (j=1; j<=i; j++) { k=order[j]
            printf "  %s  %s  %s%s%s\n", ts[k], slug[k], st[k],
              (gate[k] != "" ? " (" gate[k] ")" : ""),
              (cnt[k] > 1 ? "  [x" cnt[k] "]" : "") } }' "$staged"
}
