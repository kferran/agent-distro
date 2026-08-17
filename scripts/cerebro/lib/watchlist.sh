# lib/watchlist.sh — parse watchlist.md (operator config) + the poll-scheduling
# and last-seen-state seams for Job B. The poll AGENT does the MCP reads + diff;
# these bash seams are what make the poll deterministic and testable: which
# signals are DUE, the per-signal last-seen state read/write, and the
# controlled-vocab material match cb-watchlist fires the push on (§4).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/paths.sh"
# CB_WATCHLIST defaults to watchlist.md at the repo root (sibling of projects.md).
: "${CB_WATCHLIST:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/watchlist.md}"
: "${CB_WATCH_STATE:=$CB_HOME/watchlist}"

# watchlist_signals — every signal (block) name, in file order.
watchlist_signals() {
  [ -f "$CB_WATCHLIST" ] || return 0
  awk '/^- signal:/ { print $3 }' "$CB_WATCHLIST"
}

# watchlist_field SIGNAL FIELD — the value of FIELD in SIGNAL's block. Mirrors
# registry_field: the field must be the block's leading token (`  field: value`);
# a trailing `# comment` is stripped. Multi-value fields (jira, email_*) come back
# as their raw comma-separated string — split with watchlist_list.
watchlist_field() {
  local sig="$1" field="$2"
  awk -v p="$sig" -v f="$field" '
    /^- signal:/ { inblk = ($3 == p) }
    inblk && $1 == f":" { $1=""; sub(/^[ \t]+/,""); sub(/[ \t]+#.*$/,""); sub(/[ \t]+$/,""); print; exit }
  ' "$CB_WATCHLIST"
}

# watchlist_list SIGNAL FIELD — a comma-separated field emitted one trimmed
# value per line (empty entries dropped).
watchlist_list() {
  watchlist_field "$1" "$2" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true
}

# --- poll scheduling --------------------------------------------------------
# watchlist_interval_secs STR — "3h"/"30m"/"2d"/"90s"/"120" → seconds. A bare
# number is seconds. Unparseable → 0 (treat as always-due rather than never).
watchlist_interval_secs() {
  local s="$1" n unit
  case "$s" in
    *[0-9]s) n="${s%s}"; unit=1;;
    *[0-9]m) n="${s%m}"; unit=60;;
    *[0-9]h) n="${s%h}"; unit=3600;;
    *[0-9]d) n="${s%d}"; unit=86400;;
    *[0-9])  n="$s";     unit=1;;
    *) echo 0; return;;
  esac
  case "$n" in ''|*[!0-9]*) echo 0; return;; esac
  echo $(( n * unit ))
}

# _last_poll_file SIGNAL — the marker touched after each successful poll.
_last_poll_file() { printf '%s/%s.last_poll' "$CB_WATCH_STATE" "$1"; }

# watchlist_due SIGNAL — 0 (due) iff never polled, or now - last_poll ≥ interval.
# CB_NOW overridable for tests.
watchlist_due() {
  local sig="$1" f interval age now last
  # Operator pause: a signal with `paused: true` in its block is never due, so the
  # hourly --poll tick skips it. A manual `watch-poll <sig>` still works (the skill
  # polls-if-asked regardless of due). Unpause by removing/false-ing the field.
  case "$(watchlist_field "$sig" paused)" in true|yes|1) return 1;; esac
  f="$(_last_poll_file "$sig")"
  interval="$(watchlist_interval_secs "$(watchlist_field "$sig" poll_interval)")"
  [ -f "$f" ] || return 0                          # never polled → due
  now="${CB_NOW:-$(date +%s)}"
  last="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
  age=$(( now - last ))
  [ "$age" -ge "$interval" ]
}

# watchlist_mark_polled SIGNAL — record a completed poll (resets the due clock).
watchlist_mark_polled() {
  mkdir -p "$CB_WATCH_STATE"
  local f; f="$(_last_poll_file "$1")"
  : > "$f"
  [ -n "${CB_NOW:-}" ] && touch -d "@$CB_NOW" "$f" 2>/dev/null || true
}

# --- last-seen state (the agent's diff anchor) ------------------------------
# The poll agent stores its last-seen id/status snapshot here (opaque to bash);
# next poll diffs against it. One file per signal.
_state_file() { printf '%s/%s.state' "$CB_WATCH_STATE" "$1"; }
watchlist_state_get() { cat "$(_state_file "$1")" 2>/dev/null || true; }
watchlist_state_set() {   # SIGNAL  (content on stdin) — atomic
  mkdir -p "$CB_WATCH_STATE"
  atomic_write "$(_state_file "$1")"
}

# --- materiality (M4 seam) --------------------------------------------------
# watchlist_material_match SIGNAL STATE — 0 iff STATE is in SIGNAL's material_rule
# token set. This is the mechanical push gate: material_rule stays editable in
# config without re-polling, and the manifest primitive stays free of Job-B fields.
watchlist_material_match() {
  local sig="$1" state="$2" tok
  while IFS= read -r tok; do
    [ "$tok" = "$state" ] && return 0
  done < <(watchlist_field "$sig" material_rule | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  return 1
}
