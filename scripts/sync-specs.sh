#!/usr/bin/env bash
# scripts/sync-specs.sh — regenerate docs/ from the vault, which is the single
# source of truth for every spec in this repo.
#
#   ./scripts/sync-specs.sh          regenerate
#   ./scripts/sync-specs.sh --check  exit 1 if regenerating would change anything
#
# WHY THIS EXISTS. The specs were hand-copied into docs/ three times on
# 2026-08-17 and drifted every time -- at one point the copied header still said
# "eleven decisions" while the source had seventeen, and one doc was a full
# commit behind. A copy kept in step by somebody remembering is a copy that
# drifts, so the copy is generated and says so, and --check makes the drift
# detectable instead of discoverable.
#
# The vault is authoritative because that is where Kyle reads, reviews and
# decides. docs/ exists so the implementing agent has the spec in the repo it
# is building, without a second editable original.
set -euo pipefail

VAULT="${CB_VAULT:-$HOME/vault}"
REF="${SPEC_SYNC_REF:-origin/main}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check_only=0
[ "${1:-}" = "--check" ] && check_only=1

# source-in-vault | dest-in-repo | first-line-of-body
SPECS="
00 Inbox/2026-08-16-cerebro-build-spec-v0.2.md|docs/build-spec.md|# Cerebro — Build Specification
99 Meta/specs/2026-08-17-cerebro-host-router-design.md|docs/host-router.md|# Host router
"

[ -d "$VAULT/.git" ] || { echo "sync-specs: no vault git repo at $VAULT" >&2; exit 2; }
git -C "$VAULT" fetch --quiet origin 2>/dev/null || echo "sync-specs: fetch failed, using local $REF" >&2

rc=0
printf '%s\n' "$SPECS" | while IFS='|' read -r src dst pat; do
  [ -n "${src:-}" ] || continue

  git -C "$VAULT" cat-file -e "$REF:$src" 2>/dev/null || {
    echo "sync-specs: $src not found at $REF" >&2; rc=1; continue; }

  sha="$(git -C "$VAULT" rev-parse --short "$REF")"
  body="$(mktemp)"; out="$(mktemp)"
  git -C "$VAULT" show "$REF:$src" > "$body"

  start="$(grep -n "^${pat}" "$body" | head -1 | cut -d: -f1 || true)"
  [ -n "$start" ] || { echo "sync-specs: body marker '$pat' not found in $src" >&2; rm -f "$body" "$out"; rc=1; continue; }

  {
    echo "<!--"
    echo "GENERATED FILE — DO NOT EDIT."
    echo ""
    echo "Source of truth:  $src"
    echo "In:               the vault repo (porch-vault), $REF"
    echo "At commit:        $sha"
    echo ""
    echo "Regenerate:       ./scripts/sync-specs.sh"
    echo "Detect drift:     ./scripts/sync-specs.sh --check"
    echo ""
    echo "Edits made here are lost on the next sync. Edit the vault copy."
    echo "-->"
    echo ""
    tail -n +"$start" "$body"
  } > "$out"

  # vault-internal wikilinks have no meaning in this repo
  sed -i \
    -e 's|\[\[00 Inbox/2026-08-16-cerebro-build-spec-v0\.2\]\]|the build spec (docs/build-spec.md)|g' \
    -e 's|\[\[99 Meta/specs/2026-08-17-cerebro-host-router-design\]\]|the host router design (docs/host-router.md)|g' \
    "$out"

  if [ "$check_only" -eq 1 ]; then
    if ! diff -q "$out" "$here/$dst" >/dev/null 2>&1; then
      echo "DRIFT: $dst is out of date with $src at $sha"; rc=1
    else
      echo "ok: $dst"
    fi
  else
    mv "$out" "$here/$dst"
    echo "wrote $dst  <- $src @ $sha"
  fi
  rm -f "$body" "$out" 2>/dev/null || true
done

exit $rc
