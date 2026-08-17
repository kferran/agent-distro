# lib/overlap.sh — R5 dispatch serialization.
#
# Cerebro had no serialization concept at all. cb-start's collision pre-check is
# slug-only and _ticket_precheck asks "is this TICKET already handled" — neither
# asks the question R5 exists for: is another conductor already working the same
# FILES or the same SUBSYSTEM right now? Once intake is armed it claims up to
# CB_AGENT_CAP items an hour, unattended, into a monorepo; three auto-dispatched
# fixes in one subsystem discover each other at PR time, which is the worst place
# and the most expensive time to find out.
#
# Coarse on purpose (the firstmate rule): same repo + overlapping area →
# serialize, everything else parallel. Two disciplines keep it from being noise:
#
#   1. The candidate side is DECLARED, never inferred. A dispatch has not written
#      any code yet, so there is nothing honest to read — guessing its files from
#      the ticket text produces false refusals, and a check that cries wolf gets
#      switched off. So a file-overlap REFUSAL is only assertable when the dev
#      item declares `files:`. Everything else is a subsystem WARN.
#   2. Can't-tell degrades to warn, never to refuse. A missing, reaped or
#      unreadable worktree must not block a spawn — the same rule
#      _ticket_precheck applies to a dead Bitbucket connection.
#
# The in-flight side is real evidence: the other worktree's actually-changed
# files, plus its dev item's domain.
: "${CB_VAULT:=$HOME/vault}"
_ov_git() { if [ -n "${CB_GIT_CMD:-}" ]; then eval "$CB_GIT_CMD" '"$@"'; else git "$@"; fi; }

# _ov_item_field SLUG FIELD — one frontmatter value from a dev item, or empty
_ov_item_field() {
  local f="$CB_VAULT/00 Inbox/$1.md"
  [ -f "$f" ] || return 0
  awk -v k="$2" '/^---[[:space:]]*$/{n++; next} n==1 && index($0, k":")==1 {
    sub("^" k ":[[:space:]]*",""); sub(/[[:space:]]*$/,""); print; exit}' "$f" 2>/dev/null
}

# cb_overlap_declared_files SLUG — the candidate's DECLARED touch set, one path
# per line. Accepts either inline (`files: a/b.ts, c/d.cs`) or a YAML block list
# under `files:`. Empty when the item declares nothing, which is the common case
# and simply means no refusal is assertable for it.
#
# Trailing `#` comments are stripped, and that is load-bearing rather than
# tidiness: the dev-item template documents this field with an inline comment on
# the `files:` line itself, so without the strip every item created from the
# template and left unfilled would "declare" the help text as a path.
cb_overlap_declared_files() {
  local f="$CB_VAULT/00 Inbox/$1.md" inline
  [ -f "$f" ] || return 0
  inline="$(_ov_item_field "$1" files | sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//')"
  if [ -n "$inline" ]; then
    printf '%s\n' "$inline" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^["'"'"']//; s/["'"'"']$//' | grep -v '^$' || true
    return 0
  fi
  # block form: `files:` alone, then `  - path` lines until the next key
  awk '/^---[[:space:]]*$/{n++; next} n!=1 {next}
       /^files:[[:space:]]*$/ {inlist=1; next}
       inlist && /^[[:space:]]*-[[:space:]]*/ {
         sub(/^[[:space:]]*-[[:space:]]*/,""); sub(/[[:space:]]*#.*$/,""); sub(/[[:space:]]*$/,"")
         gsub(/^["'"'"']|["'"'"']$/,""); if ($0 != "") print; next }
       inlist && /^[[:space:]]*#/ {next}
       inlist {exit}' "$f" 2>/dev/null
}

# cb_overlap_worktree_files WORKTREE BASE — what an in-flight conductor has
# actually touched: committed-vs-base plus anything still dirty. Unreadable or
# non-git worktree prints nothing and returns 1, so the caller can tell "no
# overlap" apart from "could not look" and degrade to a warn.
cb_overlap_worktree_files() {
  local wt="$1" base="${2:-main}" out rc=0
  [ -d "$wt" ] || return 1
  _ov_git -C "$wt" rev-parse --git-dir >/dev/null 2>&1 || return 1
  out="$(_ov_git -C "$wt" diff --name-only "origin/$base...HEAD" 2>/dev/null)" || rc=1
  # dirty tree too — a conductor mid-edit owns those files just as much
  out="$out
$(_ov_git -C "$wt" status --porcelain 2>/dev/null | sed 's/^...//; s/.* -> //')" || rc=1
  printf '%s\n' "$out" | sed 's/^[[:space:]]*//' | grep -v '^$' | sort -u || true
  return $rc
}

# cb_overlap_inflight EXCLUDE_SLUG — live code tasks other than EXCLUDE_SLUG, as
# `slug<TAB>target<TAB>worktree`. Liveness reuses classify.sh's cb_session_alive,
# so a finished-but-not-reaped task never serializes anything behind it.
cb_overlap_inflight() {
  local exclude="$1" d slug sess
  for d in "$CB_HOME"/tasks/*/; do
    [ -d "$d" ] || continue
    slug="$(basename "$d")"
    [ "$slug" = "$exclude" ] && continue
    [ "$(_meta_field "${d%/}" kind)" = "code" ] || continue
    sess="$(_meta_field "${d%/}" session)"; [ -n "$sess" ] || sess="$slug"
    [ "$(cb_session_alive "$sess")" = "alive" ] || continue
    printf '%s\t%s\t%s\n' "$slug" "$(_meta_field "${d%/}" target)" "$(_meta_field "${d%/}" worktree)"
  done
}

# cb_overlap_check SLUG TARGET DOMAIN BASE — the R5 surface. Writes findings to
# stderr; returns 0 to proceed, 1 when a declared-file overlap makes this a
# refusal. Callers own the --force override, exactly like _ticket_precheck.
cb_overlap_check() {
  local slug="$1" target="$2" domain="$3" base="${4:-main}"
  local other otarget owt odomain ofiles cfiles hit strong=0 readable
  cfiles="$(cb_overlap_declared_files "$slug")"
  while IFS=$'\t' read -r other otarget owt; do
    [ -n "$other" ] || continue
    # a different repo/project cannot collide — parallel, no note
    [ -n "$target" ] && [ -n "$otarget" ] && [ "$target" != "$otarget" ] && continue
    readable=1; ofiles="$(cb_overlap_worktree_files "$owt" "$base")" || readable=0
    odomain="$(_ov_item_field "$other" domain)"
    if [ -n "$cfiles" ] && [ "$readable" = "1" ] && [ -n "$ofiles" ]; then
      hit="$(printf '%s\n' "$cfiles" | grep -Fxf <(printf '%s\n' "$ofiles") 2>/dev/null || true)"
      if [ -n "$hit" ]; then
        echo "cb-start: ⚠ $slug and in-flight $other both touch:" >&2
        printf '           %s\n' $hit >&2
        strong=1; continue
      fi
    fi
    if [ "$readable" = "0" ]; then
      echo "cb-start: ⚠ in-flight $other — worktree ${owt:-<unset>} unreadable, cannot compare files (not blocking)" >&2
      continue
    fi
    if [ -n "$domain" ] && [ "$domain" = "$odomain" ]; then
      echo "cb-start: ⚠ in-flight $other is in the same subsystem (domain: $domain) — no file overlap yet; expect to coordinate at PR time" >&2
    fi
  done < <(cb_overlap_inflight "$slug")
  [ "$strong" -eq 1 ] && return 1
  return 0
}
