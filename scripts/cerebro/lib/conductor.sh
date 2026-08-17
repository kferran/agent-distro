# conductor.sh — conductor-run resolution + manifest parsing (read-only seam).
# The conductor's .ai/specs/ root holds ~150 committed run subdirs in every
# worktree (mtimes ≈ checkout time), so newest-mtime alone is not robust —
# it only finds the run created DURING the session. Resolver order (plan 2
# Evidence 7): exact <slug> subdir → manifest jira: match → newest manifest.
# Specs root via CB_SPECS_ROOT (caller resolves `conductor_specs_root` from
# the registry; default .ai/specs).

# manifest_field RUN-DIR FIELD — frontmatter value from manifest.md.
# Frontmatter-only (same fence discipline as classify.sh's _fm_status);
# strips trailing whitespace/CR.
manifest_field() {
  local dir="$1" field="$2"
  awk -v f="$field" '
    /^---[[:space:]]*\r?$/ { n++; next }
    n==1 && index($0, f":") == 1 {
      sub("^" f ":[[:space:]]*", ""); sub(/[[:space:]]*\r?$/, ""); print; exit
    }
  ' "$dir/manifest.md" 2>/dev/null
}

# _run_in_scope RUN-DIR FLOOR — 0 iff RUN-DIR/manifest.md exists AND is in scope
# for the current session: either there is no FLOOR (older tasks / no context.md
# → unconditional, back-compat) or the manifest post-dates the FLOOR. The FLOOR
# is the task's own context.md — the current session's start marker (scope-add
# #2a). A reused/adopted worktree carries prior-cycle runs (same slug or same
# jira, stale ship/complete state); without the floor on tiers 1 & 2 those get
# mis-resolved as the current run, driving blocked→failed flapping off stale
# artifacts (eja-3600, eja-3487). Applied to ALL tiers so resolution is scoped
# to this session's run, not merely the newest-mtime last resort.
_run_in_scope() {
  [ -f "$1/manifest.md" ] || return 1
  [ -f "$2" ] || return 0
  [ "$1/manifest.md" -nt "$2" ]
}
# resolve_run WORKTREE SLUG [JIRA] — prints the run dir path, non-zero if none.
resolve_run() {
  local wt="$1" slug="$2" jira="${3:-}"
  local root="$wt/${CB_SPECS_ROOT:-.ai/specs}"
  root="${root%/}"
  local floor="$root/$slug/context.md"
  # 1. exact slug subdir, but only if it's a real in-scope run (has a manifest
  #    that post-dates this session's context.md floor — a prior cycle's stale
  #    slug-dir manifest is excluded)
  if _run_in_scope "$root/$slug" "$floor"; then
    printf '%s\n' "$root/$slug"; return 0
  fi
  # 2. the subdir whose manifest jira: matches AND is in scope (a stale same-jira
  #    prior cycle in a reused/adopted worktree is skipped)
  local d
  if [ -n "$jira" ]; then
    for d in "$root"/*/; do
      _run_in_scope "${d%/}" "$floor" || continue
      if [ "$(manifest_field "${d%/}" jira)" = "$jira" ]; then
        printf '%s\n' "${d%/}"; return 0
      fi
    done
  fi
  # 3. newest manifest.md by mtime — but ONLY if it's newer than the floor.
  #    cb-brief --code writes context.md immediately before launch, so a genuine
  #    session-run's manifest post-dates it, while the ~150 committed runs carry
  #    checkout-time mtimes that predate it. Without that floor, an unrelated
  #    committed run gets mis-resolved (→ bogus needs-input gate).
  local newest
  newest="$(ls -1t "$root"/*/manifest.md 2>/dev/null | head -1)"
  if [ -n "$newest" ] && [ -f "$floor" ] && [ "$newest" -nt "$floor" ]; then
    printf '%s\n' "$(dirname "$newest")"; return 0
  fi
  echo "conductor: no run dir resolvable under $root (slug=$slug${jira:+, jira=$jira}); newest manifest ${newest:+predates}${newest:-absent} the task context.md floor" >&2
  return 1
}
