# land.sh — the ONE place that decides where a finished X-Man report lands.
#
# WHY A COMPUTED PATH. Landing used to depend on the agent declaring a
# `deliverable:` in its own report, and an agent that wrote a wrong path (or
# none) stranded its own finding permanently. The destination is now derived
# from facts the scripts already hold — the local date, the task kind, the slug
# — and stamped into the task meta at SCAFFOLD time, before the agent ever
# runs. An agent-written `deliverable:` no longer changes where anything lands.
#
# Sourced, never executed: no `set -e` here. `-e` in a lib leaks into every
# caller (and into bats `load`), turning a benign non-zero test three files
# away into an abort. paths.sh is the house pattern — bare functions, defaults
# via `: "${VAR:=}"`.

# cb_local_date — Kyle's LOCAL calendar date, always.
# The server clock is UTC and rolls over during his evening, so `date +%F`
# writes tomorrow's date for several hours every night. Two X-Men did exactly
# that on 2026-08-05 because their hand-written briefs each restated the rule
# and each got it wrong. One function, so no brief has to carry it.
cb_local_date() { TZ=America/Denver date +%F; }

# cb_deliverable_path KIND SLUG [LOCAL] -> `00 Inbox/<LOCAL>-<KIND>-<SLUG>.md`
# LOCAL defaults to cb_local_date; callers pass it only to pin the date (tests,
# and any caller that already computed it for a same-run commit message).
# Repo-relative on purpose — it is written into task meta and into commits, and
# an absolute path there would bake in whichever vault checkout scaffolded it.
# Refuses an empty KIND or SLUG rather than composing `00 Inbox/2026-08-14--x.md`:
# a blank component is a caller bug, and a silently-malformed path is the exact
# failure this whole mechanism exists to remove.
cb_deliverable_path() {
  local kind="${1:-}" slug="${2:-}" local_date="${3:-}"
  [ -n "$kind" ] || { echo "cb_deliverable_path: KIND required" >&2; return 2; }
  [ -n "$slug" ] || { echo "cb_deliverable_path: SLUG required" >&2; return 2; }
  [ -n "$local_date" ] || local_date="$(cb_local_date)"
  printf '00 Inbox/%s-%s-%s.md\n' "$local_date" "$kind" "$slug"
}

# --- the lander's half (§2/§3/§4) -------------------------------------------
# Validation and stamping live here rather than in cb-land so the shapes can be
# tested without standing up a vault, a git repo and a task dir.

# cb_land_dest_ok PATH — may the lander write PATH (repo-relative)?
# 0 = yes, 2 = refused, reason on stderr.
#
# It does NOT call `lib/denylist.sh`'s `cb_is_forbidden`, and that is deliberate
# rather than an omission: the lander's gate is strictly narrower. Every path
# the shared denylist catches — `CLAUDE.md`, `People/`, `Confidential/`,
# `.claude/`, `scripts/`, absolute, traversal — is already excluded by the three
# tests below, because the lander writes to exactly one folder and nowhere else.
# Adding the call would buy no refusal and would couple the lander to a list it
# does not consult. The denylist is for the scripts that write across the vault
# (`cb-ingest`, `cb-distill`), where an allowlist that tight is not available.
#
# Order matters. Absolute and traversal are rejected BEFORE the `00 Inbox/`
# prefix test: `00 Inbox/../CLAUDE.md` satisfies the prefix and resolves to the
# one file the fleet must never rewrite.
cb_land_dest_ok() {
  local p="${1:-}"
  [ -n "$p" ] || { echo "cb_land_dest_ok: empty destination" >&2; return 2; }
  case "$p" in
    /*)   echo "cb_land_dest_ok: absolute path refused: $p" >&2; return 2;;
    *..*) echo "cb_land_dest_ok: path traversal refused: $p" >&2; return 2;;
  esac
  case "$p" in
    '00 Inbox/'?*) : ;;
    *) echo "cb_land_dest_ok: destination must be a file under '00 Inbox/': $p" >&2; return 2;;
  esac
  case "$p" in */) echo "cb_land_dest_ok: destination is a directory: $p" >&2; return 2;; esac
  return 0
}

# _cb_land_has_frontmatter FILE — a COMPLETE opening `---` … `---` block.
# Completeness is the point: a report that opens a fence and never closes it is
# malformed, yet `ul_report_field` still finds its `status:` and it sails
# through the terminal gate. Inserting provenance after line 1 of such a file
# produces a landed page whose whole body is swallowed by an unterminated
# frontmatter block, so that case gets a fresh block prepended instead.
_cb_land_has_frontmatter() {
  local first
  [ -f "$1" ] || return 1
  IFS= read -r first < "$1" || return 1
  [[ "${first%$'\r'}" =~ ^---[[:space:]]*$ ]] || return 1
  awk 'NR==1 { next } /^---[[:space:]]*$/ { found=1; exit } END { exit !found }' "$1"
}

# cb_land_stamp REPORT SLUG KIND SRC LANDED_AT — the report with provenance,
# on stdout. The report's own frontmatter fields are kept verbatim; the
# provenance goes INTO that block so the landed page has one frontmatter, not
# two stacked ones (Obsidian only reads the first, and a reader diffing the
# landed file against the report should see an insertion, not a rewrite).
#
# LANDED_AT is a parameter, not `date -Is` inline, precisely so the idempotent
# re-run test in cb-land can re-stamp with the ALREADY-recorded timestamp and
# get a byte-identical result. With the clock read in here, no re-run could
# ever be byte-identical and the spec's idempotency clause would be dead code.
cb_land_stamp() {
  local rep="$1" slug="$2" kind="$3" src="$4" at="$5" prov
  prov="$(printf 'landed_from: %s\nlanded_slug: %s\nlanded_kind: %s\nlanded_at: %s\nlanded_by: cb-land' \
    "$src" "$slug" "$kind" "$at")"
  if _cb_land_has_frontmatter "$rep"; then
    head -n 1 "$rep"; printf '%s\n' "$prov"; tail -n +2 "$rep"
  else
    printf -- '---\n%s\n---\n\n' "$prov"; cat "$rep"
  fi
}
