#!/usr/bin/env bash
# delivery/local-only.sh {create_pr|pr_status|merge} — same interface as
# bitbucket.sh, no network. For registry rows with `delivery: local-only`:
# "create_pr" just records an OPEN state under $CB_HOME/local-prs/<id>;
# "merge" does the local ff (git mockable via CB_GIT_CMD, repo via
# CB_LOCAL_REPO) and flips the state to MERGED for pr_status polls.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$here/../lib/paths.sh"
prdir="$CB_HOME/local-prs"

_git() {
  if [ -n "${CB_GIT_CMD:-}" ]; then eval "$CB_GIT_CMD" '"$@"'; else git "$@"; fi
}

cmd="${1:-}"; shift || true
case "$cmd" in
  create_pr)
    [ $# -eq 5 ] || { echo "usage: local-only.sh create_pr <title> <source> <dest> <body_file> <reviewers_json>" >&2; exit 2; }
    source_branch="$2" dest_branch="$3"
    id="$(printf '%s' "$source_branch" | tr -c 'a-zA-Z0-9._-' '-')"
    mkdir -p "$prdir"
    printf 'OPEN %s %s' "$source_branch" "$dest_branch" | atomic_write "$prdir/$id"
    printf 'local:%s %s\n' "$id" "$id"
    ;;
  pr_status)
    [ $# -eq 1 ] || { echo "usage: local-only.sh pr_status <id>" >&2; exit 2; }
    [ -f "$prdir/$1" ] || { echo "local-only.sh: unknown local pr $1" >&2; exit 1; }
    cut -d' ' -f1 "$prdir/$1"
    ;;
  merge)
    [ $# -eq 1 ] || { echo "usage: local-only.sh merge <id>" >&2; exit 2; }
    rec="$prdir/$1"
    [ -f "$rec" ] || { echo "local-only.sh: unknown local pr $1" >&2; exit 1; }
    # the record is newline-less (atomic_write of a bare printf) — read hits
    # EOF and exits non-zero even though it populated the vars; don't die.
    read -r _state source_branch dest_branch < "$rec" || true
    [ -n "${source_branch:-}" ] || { echo "local-only.sh: malformed record $rec" >&2; exit 1; }
    : "${CB_LOCAL_REPO:?local-only.sh: CB_LOCAL_REPO not set}"
    _git -C "$CB_LOCAL_REPO" merge --ff-only "$source_branch"
    printf 'MERGED %s %s' "$source_branch" "$dest_branch" | atomic_write "$rec"
    ;;
  *)
    echo "usage: local-only.sh {create_pr|pr_status|merge} ..." >&2; exit 2;;
esac
