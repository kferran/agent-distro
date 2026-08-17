#!/usr/bin/env bash
# delivery/bitbucket.sh {create_pr|update_pr|set_reviewers|decline|pr_status|pr_get|merge} — Bitbucket Cloud REST adapter.
#   create_pr <title> <source> <dest> <body_file> <reviewers_json>  -> prints "url id"
#   update_pr <id> <title> <body_file>                             -> prints "url id" (PUT title+description on an open PR)
#   set_reviewers <id>                                              -> prints "id count" (backfill repo defaults; NOTIFIES — needs Kyle's ok)
#   decline <id>                                                    -> prints DECLINED (reversible; NOTIFIES — needs Kyle's ok)
#   pr_status <id>                                                  -> OPEN|MERGED|DECLINED
#   merge <id>                                                      -> refuses (operator merges)
# Auth: BB_API_TOKEN (from CB_ENV / $CB_HOME/env if unset) fed to curl as an
# `Authorization: Bearer` header via `--config -` on stdin — the token NEVER
# appears in argv (ratified 2026-07-12). Bearer, not Basic: scoped Atlassian
# API tokens (ATCTT…) 401 on Basic auth (verified live 2026-07-13).
# Workspace/repo via CB_BB_WORKSPACE/CB_BB_REPO (cb-pr-check exports them from the
# registry). curl mockable via CB_CURL_CMD (receives the real curl argv; auth
# config on stdin). A 401 anywhere prints "escalate: token dead" and exits 3 so
# callers can page rather than fail silently.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$here/../lib/paths.sh"

if [ -z "${BB_API_TOKEN:-}" ]; then
  env_file="${CB_ENV:-$CB_HOME/env}"
  [ -f "$env_file" ] && { set -a; . "$env_file"; set +a; }
fi
: "${BB_API_TOKEN:?bitbucket.sh: BB_API_TOKEN not set (supply ~/.cerebro/env, spec §11)}"
: "${CB_BB_WORKSPACE:?bitbucket.sh: CB_BB_WORKSPACE not set}"
: "${CB_BB_REPO:?bitbucket.sh: CB_BB_REPO not set}"
api="https://api.bitbucket.org/2.0/repositories/$CB_BB_WORKSPACE/$CB_BB_REPO"

_curl() {
  if [ -n "${CB_CURL_CMD:-}" ]; then eval "$CB_CURL_CMD" '"$@"'; else curl "$@"; fi
}
# _request [curl args...] — auth config on stdin, response body + trailing HTTP
# code captured; sets $body/$code. Exits 3 on 401 (dead token -> page, not fail).
_request() {
  local resp
  # feeder printf `|| true`: a curl/mock that exits before reading stdin
  # SIGPIPEs the printf; under pipefail that would kill the adapter
  resp="$({ printf 'header = "Authorization: Bearer %s"\n' "$BB_API_TOKEN" || true; } | \
    _curl -s -w '\n%{http_code}' --config - "$@")"
  code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  if [ "$code" = "401" ]; then
    echo "escalate: token dead (HTTP 401 from Bitbucket) — refresh BB_API_TOKEN in ~/.cerebro/env" >&2
    exit 3
  fi
}

cmd="${1:-}"; shift || true
case "$cmd" in
  create_pr)
    [ $# -eq 5 ] || { echo "usage: bitbucket.sh create_pr <title> <source> <dest> <body_file> <reviewers_json>" >&2; exit 2; }
    title="$1" source_branch="$2" dest_branch="$3" body_file="$4" reviewers="$5"
    [ -f "$body_file" ] || { echo "bitbucket.sh: body file $body_file missing" >&2; exit 2; }
    payload="$(mktemp)"; trap 'rm -f "$payload"' EXIT
    # ⚠️ REVIEWERS MUST BE SENT EXPLICITLY. Bitbucket Cloud applies a repo's
    # configured default reviewers **only in the web UI** — a REST create with the
    # `reviewers` field omitted produces a PR with ZERO reviewers. This block used
    # to omit it deliberately, on the belief that "repo default reviewers
    # auto-assign (Kyle 2026-07-13)". That belief was WRONG and it was the cause
    # of a real operational failure: verified 2026-08-04, `ultron` has 15 default
    # reviewers configured while #2651/#2624/#2652/#2649 — all REST-created — each
    # had `reviewers: NONE`. With no reviewers nobody is notified and the PR never
    # appears in anyone's review queue, so Kyle had to hand-share every link in
    # #ultron-prs to get the team to see it. It also explains the zero-approval
    # wall: approvals cannot accumulate on a PR that has no reviewers.
    # So: when the caller supplies no explicit reviewers, fetch the repo defaults
    # and send them. An explicit list still overrides, exactly as before.
    if [ "$(jq -n --argjson r "${reviewers:-[]}" '$r|length')" = "0" ]; then
      _request -G --data-urlencode "pagelen=100" "$api/default-reviewers"
      case "$code" in
        2*) reviewers="$(printf '%s' "$body" | jq -c '[.values[]? | {uuid}]')"
            [ "$(jq -n --argjson r "$reviewers" '$r|length')" = "0" ] &&
              echo "bitbucket.sh: warn — repo has no default reviewers configured; creating PR with none" >&2 ;;
        *)  echo "bitbucket.sh: warn — could not read default reviewers (HTTP $code); creating PR with none" >&2
            reviewers='[]' ;;
      esac
    fi
    # CB_BB_DRAFT=1 opens the PR as a DRAFT (default off, so existing callers
    # are unchanged). Bitbucket Cloud exposes `draft` on the PR resource; used
    # for work that must not enter the merge queue until an operator promotes it.
    draft=false; case "${CB_BB_DRAFT:-}" in 1|true|yes) draft=true;; esac
    _build_payload() {
      jq -n --arg t "$title" --arg s "$source_branch" --arg d "$dest_branch" \
        --rawfile b "$body_file" --argjson r "${reviewers:-[]}" --argjson draft "$draft" \
        '{title:$t, source:{branch:{name:$s}}, destination:{branch:{name:$d}}, description:$b}
         + (if ($r|length) > 0 then {reviewers:$r} else {} end)
         + (if $draft then {draft:true} else {} end)' \
        > "$payload"
    }
    _build_payload
    _request -X POST -H "Content-Type: application/json" --data "@$payload" "$api/pullrequests"
    # Bitbucket rejects a PR whose reviewer list contains its own author. The
    # token cannot self-identify (`/user` returns nothing for scoped API tokens),
    # and the author is only knowable after the create — so instead of
    # hardcoding an identity, strip whatever uuid the error names and retry once.
    # Self-correcting: works for any author, including one added to the defaults
    # later.
    case "$code" in
      2*) ;;
      *)  bad_uuids="$(printf '%s' "$body" | grep -oE '\{[0-9a-f-]{36}\}' | sort -u || true)"
          if [ -n "$bad_uuids" ] && printf '%s' "$body" | grep -qiE 'author|reviewer'; then
            for u in $bad_uuids; do
              reviewers="$(jq -c --arg u "$u" '[.[] | select(.uuid != $u)]' <<<"$reviewers")"
            done
            echo "bitbucket.sh: retrying create_pr without author-as-reviewer ($bad_uuids)" >&2
            _build_payload
            _request -X POST -H "Content-Type: application/json" --data "@$payload" "$api/pullrequests"
          fi
          ;;
    esac
    case "$code" in
      2*) ;;
      *) echo "bitbucket.sh: create_pr failed (HTTP $code): $body" >&2; exit 1;;
    esac
    # a requested draft that came back non-draft is a silent merge-queue entry —
    # refuse rather than report success (the PR still exists; promote or decline it)
    if [ "$draft" = true ] && [ "$(jq -r '.draft' <<<"$body")" != "true" ]; then
      echo "bitbucket.sh: create_pr asked for a DRAFT but Bitbucket returned draft=$(jq -r '.draft' <<<"$body") for PR $(jq -r '.id' <<<"$body")" >&2
      exit 1
    fi
    jq -r '"\(.links.html.href) \(.id)"' <<<"$body"
    ;;
  update_pr)
    [ $# -eq 3 ] || { echo "usage: bitbucket.sh update_pr <id> <title> <body_file>" >&2; exit 2; }
    id="$1" title="$2" body_file="$3"
    [ -f "$body_file" ] || { echo "bitbucket.sh: body file $body_file missing" >&2; exit 2; }
    payload="$(mktemp)"; trap 'rm -f "$payload"' EXIT
    # PUT only title + description; source/destination on an open PR are immutable
    # and echoing them back can 400. Same auth path as create_pr (token on stdin).
    jq -n --arg t "$title" --rawfile b "$body_file" '{title:$t, description:$b}' > "$payload"
    _request -X PUT -H "Content-Type: application/json" --data "@$payload" "$api/pullrequests/$id"
    case "$code" in
      2*) ;;
      *) echo "bitbucket.sh: update_pr failed (HTTP $code): $body" >&2; exit 1;;
    esac
    jq -r '"\(.links.html.href) \(.id)"' <<<"$body"
    ;;
  set_reviewers)
    # Backfill the repo default reviewers onto an ALREADY-OPEN PR. Needed because
    # a PR created outside this adapter (a hand-rolled REST POST) ships with
    # `reviewers: []` — Bitbucket applies repo defaults in the web UI only — and a
    # PR with no reviewers can never accumulate approvals, so the merge gate is
    # unreachable. Measured 2026-08-08: #2746 sat 12h at zero reviewers / zero
    # participants for exactly this reason. `update_pr` cannot do it (it PUTs only
    # title + description), hence a separate verb.
    # ⚠️ This NOTIFIES every default reviewer, so it is an outward write — callers
    # must have Kyle's approval for the specific PR. Same immutability rule as
    # update_pr: PUT title + reviewers, never source/destination.
    [ $# -eq 1 ] || { echo "usage: bitbucket.sh set_reviewers <id>" >&2; exit 2; }
    id="$1"
    _request "$api/pullrequests/$id"
    case "$code" in
      2*) ;;
      *) echo "bitbucket.sh: set_reviewers could not read PR $id (HTTP $code): $body" >&2; exit 1;;
    esac
    pr_state="$(jq -r '.state' <<<"$body")"
    [ "$pr_state" = "OPEN" ] || { echo "bitbucket.sh: set_reviewers refused — PR $id is $pr_state, not OPEN" >&2; exit 1; }
    pr_title="$(jq -r '.title' <<<"$body")"
    author_uuid="$(jq -r '.author.uuid // empty' <<<"$body")"
    _request -G --data-urlencode "pagelen=100" "$api/default-reviewers"
    case "$code" in
      2*) ;;
      *) echo "bitbucket.sh: set_reviewers could not read default reviewers (HTTP $code)" >&2; exit 1;;
    esac
    # drop the author if present — Bitbucket 400s on author-as-reviewer
    reviewers="$(jq -c --arg a "$author_uuid" '[.values[]? | select(.uuid != $a) | {uuid}]' <<<"$body")"
    n="$(jq -n --argjson r "$reviewers" '$r|length')"
    [ "$n" -gt 0 ] || { echo "bitbucket.sh: set_reviewers refused — repo has no default reviewers configured" >&2; exit 1; }
    payload="$(mktemp)"; trap 'rm -f "$payload"' EXIT
    jq -n --arg t "$pr_title" --argjson r "$reviewers" '{title:$t, reviewers:$r}' > "$payload"
    _request -X PUT -H "Content-Type: application/json" --data "@$payload" "$api/pullrequests/$id"
    case "$code" in
      2*) ;;
      *) echo "bitbucket.sh: set_reviewers failed (HTTP $code): $body" >&2; exit 1;;
    esac
    jq -r '"\(.id) \((.reviewers//[])|length)"' <<<"$body"
    ;;
  decline)
    # Decline an open PR. Unlike `merge` this is NOT refused: declining is
    # reversible (the PR can be reopened) and destroys nothing — the branch and
    # its commits survive untouched — so it is the right disposition for a PR
    # that needs rework rather than review. Merge stays operator-driven.
    # Still an outward write (reviewers are notified), so callers need Kyle's
    # approval for the specific PR.
    [ $# -eq 1 ] || { echo "usage: bitbucket.sh decline <id>" >&2; exit 2; }
    id="$1"
    _request "$api/pullrequests/$id"
    case "$code" in
      2*) ;;
      *) echo "bitbucket.sh: decline could not read PR $id (HTTP $code): $body" >&2; exit 1;;
    esac
    pr_state="$(jq -r '.state' <<<"$body")"
    [ "$pr_state" = "OPEN" ] || { echo "bitbucket.sh: decline refused — PR $id is already $pr_state" >&2; exit 1; }
    # NO Content-Type and NO body. Sending `Content-Type: application/json` with
    # an empty payload 400s here (verified 2026-08-08 on #2749) — the endpoint
    # takes no request body at all. A bare POST returns 200.
    _request -X POST "$api/pullrequests/$id/decline"
    case "$code" in
      2*) ;;
      *) echo "bitbucket.sh: decline failed (HTTP $code): $body" >&2; exit 1;;
    esac
    jq -r '.state' <<<"$body"
    ;;
  pr_status)
    [ $# -eq 1 ] || { echo "usage: bitbucket.sh pr_status <id>" >&2; exit 2; }
    _request "$api/pullrequests/$1"
    case "$code" in
      2*) ;;
      *) echo "bitbucket.sh: pr_status failed (HTTP $code): $body" >&2; exit 1;;
    esac
    jq -r '.state' <<<"$body"
    ;;
  pr_get)
    [ $# -eq 1 ] || { echo "usage: bitbucket.sh pr_get <id>" >&2; exit 2; }
    _request "$api/pullrequests/$1"
    case "$code" in
      2*) ;;
      *) echo "bitbucket.sh: pr_get failed (HTTP $code): $body" >&2; exit 1;;
    esac
    printf '%s\n' "$body"
    ;;
  merge)
    echo "bitbucket.sh: merge refused — Bitbucket merge is operator-driven (Kyle merges in the UI); poll with pr_status" >&2
    exit 1
    ;;
  *)
    echo "usage: bitbucket.sh {create_pr|update_pr|pr_status|pr_get|merge} ..." >&2; exit 2;;
esac
