# lib/manifest.sh — the SHARED manifest primitive (spec §2 of the watchlist
# increment). An append-only `~/.cerebro/manifest.jsonl`, one JSON line per
# MATERIAL state/signal event: {source, key, state, ts, detail}. Writers append
# only on material transitions; readers (cb-watchlist) dedupe/flap-suppress and
# render. This is delivery-independent: a signal lives in the manifest whether or
# not any pane was free to show it, so nothing is lost to a busy tick. The
# relay-channel increment reuses this file unchanged — keep the schema EXACTLY
# {source, key, state, ts, detail}; do not bolt Job-B fields (e.g. materiality)
# onto the line (materiality is derived from watchlist.md's material_rule in
# cb-watchlist, not frozen into the primitive).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/paths.sh"
: "${CB_MANIFEST:=$CB_HOME/manifest.jsonl}"

# manifest_ts — the append timestamp (ISO-8601 UTC). Overridable in tests.
manifest_ts() { printf '%s' "${CB_MANIFEST_TS:-$(date -u +%Y-%m-%dT%H:%M:%S+00:00)}"; }

# manifest_append SOURCE KEY STATE DETAIL — append one event line, atomically.
# Multiple poll agents run in parallel (§3), so a bare `>>` is NOT safe (two
# concurrent appends can interleave a partial line); the write is flock'd on a
# sibling lock so each JSON line lands whole. jq builds the line so DETAIL is
# always valid JSON (embedded quotes/newlines/braces can't corrupt the stream).
manifest_append() {
  local source="$1" key="$2" state="$3" detail="${4:-}" ts line
  [ -n "$source" ] && [ -n "$key" ] && [ -n "$state" ] || {
    echo "manifest_append: need SOURCE KEY STATE [DETAIL]" >&2; return 2; }
  ts="$(manifest_ts)"
  line="$(jq -cn --arg s "$source" --arg k "$key" --arg st "$state" \
                 --arg ts "$ts" --arg d "$detail" \
                 '{source:$s, key:$k, state:$st, ts:$ts, detail:$d}')" || return 1
  mkdir -p "$(dirname "$CB_MANIFEST")" "$CB_HOME/locks"
  { flock 8; printf '%s\n' "$line" >> "$CB_MANIFEST"; } 8>"$CB_HOME/locks/manifest.lock"
}

# manifest_events [SOURCE] — emit every event line (optionally filtered to one
# SOURCE), oldest-first (file order = append order). Empty output if no manifest.
manifest_events() {
  [ -f "$CB_MANIFEST" ] || return 0
  if [ -n "${1:-}" ]; then
    jq -c --arg s "$1" 'select(.source==$s)' "$CB_MANIFEST" 2>/dev/null
  else
    cat "$CB_MANIFEST"
  fi
}

# manifest_latest_per_key [SOURCE] — the DEDUPED view the board renders from:
# one TSV row per (source,key), carrying the LATEST event for that key (last
# occurrence in append order wins) plus a transitions count. Two events for the
# same key collapse to a single surfaced line — the milestone-1 accept. Row:
#   source \t key \t state \t ts \t detail \t transitions
# transitions is the number of manifest events seen for that key — flap-suppress
# (§2 "N transitions in M min → one line") reads it to annotate a churning key
# without ever emitting more than one line per key.
manifest_latest_per_key() {
  [ -f "$CB_MANIFEST" ] || return 0
  jq -r --arg s "${1:-}" '
    select($s=="" or .source==$s)
    | [.source, .key, .state, .ts, .detail] | @tsv
  ' "$CB_MANIFEST" 2>/dev/null | awk -F'\t' '
    { last[$1 SUBSEP $2]=$0; n[$1 SUBSEP $2]++; if (!($1 SUBSEP $2 in seen)) { order[++c]=$1 SUBSEP $2; seen[$1 SUBSEP $2]=1 } }
    END { for (i=1;i<=c;i++){ k=order[i]; printf "%s\t%d\n", last[k], n[k] } }
  '
}
