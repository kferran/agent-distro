#!/usr/bin/env bash
# registry.sh — systems registry parser
# Uses CB_REGISTRY env to locate projects.md. Default: `scripts/cerebro/projects.md`
# — i.e. NEXT TO THE CODE THAT READS IT, deliberately not the vault root.
#
# It lived at the vault root until 2026-07-30, when a commit-all from the Windows
# Obsidian clone (`04b8dc38` "notes", committed as kyle.ferran@gmail.com) recorded
# it as DELETED. Effect: `deliverable_for_repo` matched nothing, so every
# `task_type: code` item silently failed cb-intake's gate and the fleet reported
# "nothing claimed" against a queue it could no longer read. Same failure had
# already taken root-level `Today.md` on 2026-07-01 from the same identity.
# Root-level files are the ones an Obsidian-side commit-all sweeps; a file under
# scripts/cerebro/ is not mistaken for a note. See cb-intake's registry preflight.
: "${CB_REGISTRY:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/projects.md}"

# registry_field PROJECT FIELD — reads value from matching "- project: PROJECT" block
registry_field() {
  local proj="$1" field="$2"
  awk -v p="$proj" -v f="$field" '
    /^- project:/ { inblk = ($3 == p) }
    inblk && $1 == f":" { $1=""; sub(/^ /,""); sub(/[ \t]+#.*$/,""); print; exit }
  ' "$CB_REGISTRY"
}

# registry_worktree_root PROJECT — where cb-start creates this target's worktrees,
# absolute and without a trailing slash. Falls back to ~/code/worktrees, which is
# what cb-start hardcoded at both call sites until 2026-07-31 (T39).
#
# The root is a property of the TARGET, not of Cerebro: a vault row
# (delivery: local-only) delivers into the vault's own .claude/worktrees, and
# building it under ~/code/worktrees put a vault branch in the Ultron tree — which
# had to be corrected by hand with --worktree every time.
registry_worktree_root() {
  local root; root="$(registry_field "$1" worktree_root)"
  : "${root:=$HOME/code/worktrees}"
  root="${root/#\~/$HOME}"      # same tilde idiom as the checkout field
  printf '%s\n' "${root%/}"     # no trailing slash, so <root>/<slug> never doubles
}

# registry_reviewers PROJECT — the reviewers row as BB-payload-shaped JSON
# ([{uuid: ...}, ...]). Refuses loudly while the row still carries the
# {uuid-*} placeholders (spec §11 operator supply) or is missing entirely,
# so the code path can never silently ship a reviewer-less PR.
registry_reviewers() {
  local proj="$1" raw
  raw="$(registry_field "$proj" reviewers)"
  if [ -z "$raw" ]; then
    echo "registry: no reviewers row for $proj — supply Bitbucket UUIDs (spec §11)" >&2
    return 1
  fi
  if [[ "$raw" == *"{uuid-"* ]]; then
    echo "registry: reviewers for $proj are placeholders — supply real UUIDs (spec §11)" >&2
    return 1
  fi
  jq -c '[.[] | {uuid: .}]' <<<"$raw"
}
