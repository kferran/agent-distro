# lib/push.sh — the out-of-band push channel. ONE implementation, shared by
# cb-guard (watcher-down / connector-auth alarms), cb-notify (R16 focus-ceiling
# alarm), cb-digest and cb-watchlist, so there is a single push path to reason
# about. The token rides `curl --config -` on STDIN, never argv (same
# secrets-off-argv discipline as the rest of the toolbelt). CB_CURL_CMD is the
# test/override hook.
#
# TWO BODY FORMATS, selected by CB_PUSH_FORMAT:
#   raw   (default) — the message as the request body, which is ntfy's contract.
#                     Unchanged from the original single-format implementation.
#   slack           — {"text":"<message>"}, which is what a Slack incoming
#                     webhook wants, plus a JSON content-type.
# Selection is on the explicit variable and never on sniffing the hostname out
# of CB_PUSH_URL. An implicit rule keyed on a URL shape is precisely the kind of
# predicate that goes silently false when the shape changes (spec §9.1, Type B).
#
# The format and the token are orthogonal. A Slack incoming webhook carries its
# own secret in the URL and needs no token, but a bot-token endpoint would want
# both, so neither setting suppresses the other.
#
# Escaping for `slack` goes through jq. The alarm strings interpolate ticket
# keys, slugs, states and free text (cb-watchlist:131 builds
# "watch:$sig $key -> $state ($detail)"), so quotes, backslashes, newlines and
# control characters all reach this function in practice. Hand-rolled escaping
# gets those wrong, Slack answers 400, and the `|| true` below swallows it — an
# alarm channel that drops exactly the messages containing interesting
# characters is worse than no channel at all. jq is already a hard dependency of
# delivery/bitbucket.sh, lib/registry.sh, lib/manifest.sh and cb-watchlist. The
# `raw` path needs none of it and stays pure bash.
#
# ⛔ CB_PUSH_URL IS DELIBERATELY UNSET — asked and declined 2026-08-14, do not re-propose.
# Kyle reads the fleet through the remote Claude Code UI, so an out-of-band webhook
# duplicates a surface he already watches. Return 1 (NO CHANNEL) is therefore the
# NORMAL state on this box, not a misconfiguration: callers degrade to the coordinator
# pane and the durable cb-escalations inbox, which is the intended path. Do not "fix"
# this by inventing a URL, and do not report the unset variable as a defect.
#
# cb_push <message> — attempts an out-of-band push.
#   0 — a channel was configured and the push was attempted
#   1 — NO CHANNEL: CB_PUSH_URL is unset (the standing state here — see above)
#   2 — MISCONFIGURED: a channel is set but unusable (unknown CB_PUSH_FORMAT, or
#       `slack` without jq on PATH)
# 1 and 2 are distinct because callers tell the operator what to do about it, and
# "set CB_PUSH_URL" is actively wrong advice when the URL is already set — that
# is a §9.1 Type-B seam, so it does not get to hide behind a shared exit code.
# Both are non-zero, so any caller degrading on bare non-zero still degrades.
# Nothing malformed is ever sent.
_cb_curl() { if [ -n "${CB_CURL_CMD:-}" ]; then eval "$CB_CURL_CMD" '"$@"'; else curl "$@"; fi; }
cb_push() {
  local msg="$1" fmt="${CB_PUSH_FORMAT:-raw}" body ctype=""
  [ -n "${CB_PUSH_URL:-}" ] || return 1
  case "$fmt" in
    raw)
      body="$msg" ;;
    slack)
      if ! command -v jq >/dev/null 2>&1; then
        printf 'cb_push: CB_PUSH_FORMAT=slack needs jq to escape the message — not sending\n' >&2
        return 2
      fi
      body="$(jq -nc --arg t "$msg" '{text:$t}')" || {
        printf 'cb_push: could not build a JSON body for the slack format — not sending\n' >&2
        return 2
      }
      ctype="Content-Type: application/json" ;;
    *)
      printf 'cb_push: unknown CB_PUSH_FORMAT=%s (want raw or slack) — not sending\n' "$fmt" >&2
      return 2 ;;
  esac
  local args=(-s)
  # NB: an `[ ... ] && args+=(...)` one-liner would abort the caller under
  # `set -e` on the empty-ctype path, since it is not the function's last
  # command. Keep the if.
  if [ -n "$ctype" ]; then args+=(-H "$ctype"); fi
  if [ -n "${CB_PUSH_TOKEN:-}" ]; then
    { printf 'header = "Authorization: Bearer %s"\n' "$CB_PUSH_TOKEN" || true; } | \
      _cb_curl "${args[@]}" --config - -d "$body" "$CB_PUSH_URL" >/dev/null || true
  else
    _cb_curl "${args[@]}" -d "$body" "$CB_PUSH_URL" >/dev/null || true
  fi
  return 0
}
