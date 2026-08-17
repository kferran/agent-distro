# lib/dedup.sh — content-keyed alert dedup for repeating health probes.
#
# R18's lesson is "key the dedup on CONTENT, not on a time window." cb-watch
# applies it with a PERMANENT seen-set (cb-watch:82-100): a hash seen once never
# re-logs, ever. That is right for a per-slug state-transition log — a
# running↔needs-input flap reproduces a seen hash and is suppressed at the root.
#
# It is wrong for a probe that re-runs on a timer. A permanent seen-set would
# make "watcher down" log on the first outage and stay silent for every outage
# after it — a predicate that has gone silently false, which is the exact defect
# this dedup exists to prevent.
#
# So the probe variant is EDGE-TRIGGERED. Same content key; the stored set is
# the alerts that were ACTIVE ON THE PREVIOUS RUN, rewritten on every run. An
# alert that persists across runs is logged once. An alert that clears and later
# recurs is logged again, because the clean run in between rewrote the set
# without it. Writing the file on a zero-alert run is what re-arms the probe —
# the empty case is load-bearing, not an optimization.
#
# Depends on atomic_write (lib/paths.sh); source paths.sh first.
#
# cb_dedup_new STATEFILE MSG... — print, one per line, the subset of MSG that
# was not active on the previous run, and record the current set. Call ONCE per
# run with the complete active set: a message you omit is a message you are
# telling the dedup has cleared.
cb_dedup_new() {
  local state="$1"; shift
  local prev seen="" msg h
  prev="$(cat "$state" 2>/dev/null || true)"
  for msg in "$@"; do
    [ -n "$msg" ] || continue
    h="$(printf '%s' "$msg" | sha1sum | cut -d' ' -f1)"
    # collapse duplicates raised twice within this same run
    case $'\n'"$seen" in *$'\n'"$h"$'\n'*) continue;; esac
    seen="$seen$h"$'\n'
    case $'\n'"$prev"$'\n' in *$'\n'"$h"$'\n'*) ;; *) printf '%s\n' "$msg";; esac
  done
  printf '%s' "$seen" | atomic_write "$state"
}
