# lib/queue.sh — Job A: the Inbox-as-queue promoter. The `00 Inbox/` folder IS a
# process queue: an item's presence = "process + route me". This promoter is the
# work-dispatch half of the LOCKED division of labor (§6 #1) — it fishes WORK
# out of the Inbox (and `#queue`-tagged daily-note lines) and promotes it to a
# dev item. It does NOT route non-work — that stays with the `/eod` routing pass;
# this is not a second Inbox router. The promotion write is the ONE sanctioned
# bash vault write for Job A (mirrors the dispatch claim-flip).
#
# TWO PROMOTION PATHS, TWO STATUSES (hardened 2026-07-29):
#   * Inbox auto-discovery  -> `status: drafting`. Auto-discovery is a CANDIDATE,
#     not a decision, so it must not be claimable — `cb-intake` claims on
#     `status: queued`. Kyle promotes drafting->queued. Evidence for the change:
#     of 25 promoter-generated items, 15 had to be demoted or superseded by hand.
#   * daily-note `#queue`   -> `status: queued`. The tag is an explicit human
#     opt-in; the tag IS the review, so this path keeps the fast lane.
#
# Bias TIGHT: a false promotion (a meeting note -> a claimable dev item) is worse
# than a miss (a miss is recovered by /eod or Kyle). So only HIGH-CONFIDENCE work
# promotes; work-ish-but-below-the-autofix-bar promotes as `needs_scoping`
# (flagged + surfaced); a document with AMBIGUOUS IDENTITY (several tickets named
# in the body and no explicit `slug:`/`jira:`) is REFUSED rather than slugged to
# an arbitrary one; everything else is left untouched. Dedup spans the archive as
# well as the live pool, so completed work never re-enters.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/paths.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/registry.sh"
# classify.sh for cb_session_present — the strand janitor (Job A3, below) needs
# session liveness, and sourcing it here keeps queue.sh testable on its own.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/classify.sh"
: "${CB_VAULT:=$HOME/vault}"

# _qfm FILE FIELD — frontmatter scalar (same shape as cb-intake's _fm).
_qfm() {
  awk -v f="$2" '/^---[[:space:]]*$/{n++; next} n==1 && index($0, f":") == 1 {sub("^" f ":[[:space:]]*",""); sub(/[[:space:]]*$/,""); print; exit}' "$1" 2>/dev/null
}
# _jira_key TEXT — the first EJA/ASD/ARCH key in TEXT (empty if none).
_jira_key() { grep -oE '\b(EJA|ASD|ARCH)-[0-9]+\b' <<<"$1" | head -1 || true; }
# _body_keys FILE — the DISTINCT EJA/ASD/ARCH keys in FILE, one per line.
# Identity must never be taken from `head -1` of a multi-ticket document: the
# first key is an artifact of document order, so the derived slug both names an
# arbitrary ticket and CHANGES when the document is edited (2026-07-28
# `open-pr-cleanup.md` yielded `eja-3664`; the same file yielded `asd-641` a day
# later). Callers use the count to decide identity-vs-refuse.
_body_keys() { grep -oE '\b(EJA|ASD|ARCH)-[0-9]+\b' "$1" 2>/dev/null | sort -u || true; }
# _repo_for_jira KEY — the registry repo whose jira_key_prefix matches KEY's
# prefix (empty if the prefix maps to no deliverable project — e.g. ASD, which is
# PO-owned and never auto-dispatched; ARCH until it earns a registry row).
_repo_for_jira() {
  local prefix="${1%%-*}"
  awk -v p="$prefix" '
    /^- project:/ { repo="" }
    $1=="repo:" { repo=$2 }
    $1=="jira_key_prefix:" && $2==p { print repo; exit }
  ' "$CB_REGISTRY" 2>/dev/null
}
# _slugify TEXT — a safe dev-item slug (lowercase alnum + [-._], leading alnum).
_slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9._-]\+/-/g; s/^[^a-z0-9]\+//; s/-\+/-/g; s/-$//' | cut -c1-60
}

# _is_work_shaped FILE — 0 iff the Inbox file is HIGH-CONFIDENCE work: an explicit
# work type, a real Jira key (frontmatter or an inbox-stub domain+key), or a
# `#claude` delegation tag. A raw/unfilled stub or a meeting note is NOT work.
#
# `type:` is BOTH an allow and a VETO (hardened 2026-07-29). It used to allow only,
# so a self-declared artifact still reached the permissive domain+body-key fallback
# below — that is how a design proposal, a research capture, an open-PR cleanup list
# and a watch note all became dev items. Evidence for the veto being safe: the
# inbox-stub template (`99 Meta/templates/inbox-stub.md`) carries created/domain/jira
# and NO `type:` at all, and across 72 live Inbox files not one used `code` or
# `research` — every value present was an artifact type (report / ops-report / rca /
# assessment / ratify-worklist / design-proposal / inbox-capture / …). So vetoing a
# non-work `type:` cannot break the capture path; it only stops artifacts.
# (This also makes the `*-ratify.md` / `*-night-shift.md` filename skip in
# promote_inbox redundant belt — those carry ratify-worklist / night-shift-report.)
_is_work_shaped() {
  local f="$1" type jira domain key
  type="$(_qfm "$f" type)"
  case "$type" in
    code|research) return 0;;   # explicit work type
    '') : ;;                    # no type — the inbox-stub template shape; keep checking
    *) return 1;;               # any other type self-declares an artifact — never work
  esac
  jira="$(_qfm "$f" jira)"; [ -n "$jira" ] && [ -n "$(_jira_key "$jira")" ] && return 0
  domain="$(_qfm "$f" domain)"; key="$(_jira_key "$(cat "$f" 2>/dev/null)")"
  # domain must be a filled value, not the template placeholder line
  case "$domain" in *'|'*|'') :;; *) [ -n "$key" ] && return 0;; esac
  grep -q '#claude' "$f" 2>/dev/null && return 0
  return 1
}

# _slug_taken SLUG SELF DIR... — is any file in DIR... already this dev item, by its
# frontmatter `slug:` rather than its filename? Frontmatter-only (first `---` block),
# so a slug merely mentioned in prose never blocks a promotion — the same read/don't-grep
# -the-body discipline the reactive-intake dedup gate learned the hard way. SELF is the
# source file being promoted, excluded so a stub that names its own slug does not veto
# itself (pass "" when there is no source file).
_slug_taken() {
  local slug="$1" self="$2" d f; shift 2
  for d in "$@"; do
    [ -d "$d" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ -n "$self" ] && [ "$f" = "$self" ] && continue    # never block a file on itself
      awk -v s="$slug" 'NR==1&&/^---/{i=1;next} i&&/^---/{exit} i&&$0=="slug: " s {found=1; exit}
                        END{exit !found}' "$f" 2>/dev/null && return 0
    done < <(grep -rlF "slug: $slug" "$d" --include="*.md" 2>/dev/null)
  done
  return 1
}

# _emit_item SLUG DOMAIN JIRA REPO RELATED NEEDS_SCOPING SRC [STATUS] [SELF] — create the
# dev item iff it doesn't already exist. Dedup spans BOTH the live pool and the
# ARCHIVE: checking only `items/` let completed work re-enter the queue (eja-3664
# was archived 2026-07-17 and re-promoted 2026-07-28, producing a stub whose own
# `hold:` had to read "do NOT dispatch — ALREADY BUILT").
# STATUS defaults to `drafting` — auto-discovery is a candidate, not a decision, so
# it must NOT be claimable (`cb-intake` claims on `status: queued`). Callers with an
# explicit human opt-in (a `#queue` tag) pass `queued`.
# Returns 0 on create, 1 if it already exists (skip). Caller holds the promote lock.
_emit_item() {
  local slug="$1" domain="$2" jira="$3" repo="$4" related="$5" needs="$6" src="$7" status="${8:-drafting}" self="${9:-}"
  local items="$CB_VAULT/00 Inbox"
  local archive="$CB_VAULT/02 Areas/development/archive/items"
  local f="$items/$slug.md" now
  cb_require_slug "$slug" 2>/dev/null || return 2
  [ -f "$f" ] && return 1                       # already promoted / in flight
  [ -f "$archive/$slug.md" ] && return 1        # already completed — never re-promote
  # 🔴 FILENAME IS NOT IDENTITY — the frontmatter `slug:` is (02 Areas/development/README:
  # "slug in frontmatter is authoritative; older files carry a date prefix"). 39 dev items
  # are date-prefixed, so an exact-filename check misses them and mints a SECOND file for
  # work that already has one. Harmless while dev items lived in their own folder and the
  # Inbox held only stubs; a duplicate factory once 2026-08-14 merged the two, because every
  # date-prefixed dev item then became a promote candidate for its own undated twin. Caught
  # by the step-6 supervised dry-run, which would otherwise have minted 8 duplicates on the
  # first live tick.
  _slug_taken "$slug" "$self" "$items" "$archive" && return 1
  mkdir -p "$items"
  now="$(date -d "@${CB_NOW:-$(date +%s)}" +%F 2>/dev/null || date +%F)"
  {
    printf -- '---\nslug: %s\nstatus: %s\ncreated: %s\n' "$slug" "$status" "$now"
    [ -n "$domain" ]  && printf 'domain: %s\n' "$domain"
    [ -n "$jira" ]    && printf 'jira: %s\n' "$jira"
    [ -n "$repo" ]    && printf 'repo: %s\n' "$repo"
    [ -n "$related" ] && printf 'related_project: %s\n' "$related"
    [ -n "$needs" ]   && printf 'needs_scoping: true\n'
    printf 'source: "%s"\n---\n\n# %s\n\n' "$src" "$slug"
    printf '_Promoted from %s by cb-intake (Inbox-as-queue).' "$src"
    [ -n "$needs" ] && printf ' Below the auto-dispatch bar — needs scoping (no mapped repo / ticket).'
    printf '_\n'
  } > "$f"
  mkdir -p "$CB_HOME/logs"
  local label="$status"; [ -n "$needs" ] && label="needs-scoping"
  printf '%s %s intake-promoted (%s)\n' "$(date -Is)" "$slug" "$label" >> "$CB_HOME/logs/events"
  return 0
}

# _drafting_substantive FILE — does the body carry enough to build from? Guards the
# bare-stub case: EJA-2877 sat at Blocker severity with "no acceptance criteria …
# needs a scoping pass, not a queue flip" written in its own frontmatter, and under
# a field-reading bar it would have led the first automated wave. Substance is a
# named section (Goal / Scope / Fix / Root cause / Acceptance) or >= 12 non-empty
# body lines. Deliberately crude — it separates a real spec from a cb-intake stub,
# and nothing finer is worth the false-negative risk.
_drafting_substantive() {
  local f="$1" body
  body="$(awk '/^---[[:space:]]*$/{n++; next} n>=2' "$f" 2>/dev/null)"
  grep -qiE '^#{1,3} +(goal|scope|fix|root cause|acceptance|what|symptom)' <<<"$body" && return 0
  [ "$(grep -c '[^[:space:]]' <<<"$body")" -ge 12 ] && return 0
  return 1
}

# _drafting_spec_gated FILE — does the item document its own unreadiness?
#
# Found 2026-07-31, third auto-promote wave: EJA-3601, EJA-3731 and EJA-3791 all
# passed the substance bar and all three failed the dispatch SPEC-GATE, with lines
# like "needs a product answer before either ships", "Resolve before starting" and
# "Which settings? This gates everything."
#
# The bar had it exactly backwards. A populated `## Open questions` section is not
# substance — it is a careful record of NOT being ready, and the better an item
# documents its gaps the more confidently the substance check promoted it. So read
# that section as the gate it is: any `## Open questions` (or Open question /
# Questions / Blocked on) heading with a non-empty body refuses promotion.
# This moves the dispatch SPEC-GATE earlier, to where it costs a skip instead of a
# claim, a status flip and a revert.
_drafting_spec_gated() {
  local f="$1" sect
  sect="$(awk '
    # `#+` not `#{1,4}`: this awk (mawk) silently does not support interval
    # expressions, so the {1,4} form matched NOTHING and the gate failed OPEN —
    # promoting every spec-gated item. Caught by the bats case below, 2026-07-31.
    /^#+[[:space:]]+([Oo]pen [Qq]uestions?|[Qq]uestions|[Bb]locked [Oo]n)[[:space:]]*$/ {inq=1; next}
    /^#+[[:space:]]/ {inq=0}
    inq {print}
  ' "$f" 2>/dev/null)"
  [ -n "$(grep '[^[:space:]]' <<<"$sect")" ]
}

# promote_drafting — P2: keep the fleet fed without Kyle hand-flipping every item.
#
# THE PROBLEM IT SOLVES: cb-intake claims `status: queued` and nothing else, and
# Kyle is the only path from `drafting` -> `queued`. On 2026-07-30 that meant 111
# drafting items and ZERO queued, so every tick reported "nothing claimed" for
# eight straight hours while the fleet sat idle.
#
# WHAT IT DELIBERATELY DOES NOT DO: it promotes to `queued`, never straight to
# `active`. Promotion and claiming stay separate steps, so (a) the existing claim
# path — severity ordering, agent cap, flock — is untouched, (b) a wrong promotion
# is visible in the queue and revertible before any conductor spawns, and (c) the
# dispatch skill's C1/C1c gates (dedup, live-assignee on the EJA mirror, spec-gate)
# still run afterwards. Promotion never bypasses a safety gate; it only decides
# what is eligible to be looked at.
#
# THE BAR (all required, bias tight — a miss costs a tick, a false promotion costs
# a wrong dispatch):
#   - status: drafting, and no non-empty `hold:` (enforced by cb-intake since
#     2026-07-31; 16 prose-recorded holds were converted to the field first, or
#     this would have promoted work humans had already ruled out)
#   - a Jira key, and a repo mapping to a deliverable registry row
#   - no `needs_scoping: true`, no non-empty `blocked:`
#   - never previously started: no `worktree_path:` and no `branch:`
#   - a substantive body (see _drafting_substantive)
# Capped at CB_PROMOTE_CAP per tick (default 3) so a wrong bar costs one small
# wave, not a flood. CB_PROMOTE=0 disables entirely.
promote_drafting() {
  local items="$CB_VAULT/00 Inbox" f n=0 cap slug jira repo tmp
  [ "${CB_PROMOTE:-1}" = "0" ] && return 0
  cap="${CB_PROMOTE_CAP:-3}"
  mkdir -p "$CB_HOME/locks" "$CB_HOME/logs"
  exec 8>"$CB_HOME/locks/promote-drafting"; flock 8
  for f in "$items"/*.md; do
    [ -f "$f" ] || continue
    [ "$n" -ge "$cap" ] && break
    [ "$(_qfm "$f" status)" = "drafting" ] || continue
    [ -n "$(_qfm "$f" hold)" ] && continue
    [ -n "$(_qfm "$f" blocked)" ] && continue
    case "$(_qfm "$f" needs_scoping)" in true|yes) continue;; esac
    [ -n "$(_qfm "$f" worktree_path)" ] && continue
    [ -n "$(_qfm "$f" branch)" ] && continue
    jira="$(_jira_key "$(_qfm "$f" jira)")"; [ -n "$jira" ] || continue
    repo="$(_qfm "$f" repo)"; [ -n "$repo" ] || continue
    [ -n "$(_deliverable_repo "$repo")" ] || continue
    _drafting_substantive "$f" || {
      printf '%s %s promote-skipped (bare stub — needs scoping, not a queue flip)\n' \
        "$(date -Is)" "$(basename "$f" .md)" >> "$CB_HOME/logs/events"
      continue; }
    _drafting_spec_gated "$f" && {
      printf '%s %s promote-skipped (open questions — spec-gated, answer before queueing)\n' \
        "$(date -Is)" "$(basename "$f" .md)" >> "$CB_HOME/logs/events"
      continue; }
    # flip drafting -> queued, first occurrence only, atomically
    tmp="$(mktemp)"
    awk 'BEGIN{d=0} /^status: drafting[[:space:]]*$/ && !d {print "status: queued"; d=1; next} {print}' "$f" > "$tmp" \
      && mv -f "$tmp" "$f" || { rm -f "$tmp"; continue; }
    n=$(( n + 1 ))
    printf '%s %s promoted drafting->queued (%s, auto-promote)\n' \
      "$(date -Is)" "$(basename "$f" .md)" "$jira" >> "$CB_HOME/logs/events"
  done
  [ "$n" -gt 0 ] && printf '%s auto-promoted %s drafting item(s) to queued (cap %s)\n' \
    "$(date -Is)" "$n" "$cap" >> "$CB_HOME/logs/events"
  return 0
}

# promote_inbox — the tick step. Scan Inbox work items + `#queue` daily-note lines
# and promote each to a queued dev item. Idempotent + concurrency-safe (promote
# lock + slug-exists dedup). Never touches non-work Inbox files.
promote_inbox() {
  local inbox="$CB_VAULT/00 Inbox" f slug jira repo domain key needs
  mkdir -p "$CB_HOME/locks"
  exec 7>"$CB_HOME/locks/promote"; flock 7
  # 1. Inbox files
  for f in "$inbox"/*.md; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in *-ratify.md|*-night-shift.md) continue;; esac  # process-output, not work
    # A LANDED REPORT IS NOT WORK. `cb-land` stamps `landed_by:` on every report it
    # files; those are finished output, not a request to do something. Added 2026-08-15
    # after `cb-land --drain` filed 276 historical reports into the Inbox in one go and
    # intake began promoting them into `needs_scoping` dev-item stubs — 7 before it was
    # caught. The existing `slug:` + lifecycle-`status:` guard below does NOT catch them:
    # a landed report carries `status: complete`, and `complete` is not in that guard's
    # list (drafting|queued|active|archived|done). Keying on `landed_by:` is exact — it is
    # cb-land's own stamp and nothing else writes it.
    case "$(_qfm "$f" landed_by)" in ?*) continue;; esac
    _is_work_shaped "$f" || continue
    slug="$(_qfm "$f" slug)"
    # A file carrying BOTH `slug:` and a lifecycle `status:` IS the dev item (the
    # development README: `status:` frontmatter drives state). It is not a stub awaiting
    # promotion, and promoting it mints a copy of itself under its undated slug. Before
    # 2026-08-14 this could not arise -- dev items lived in their own folder and the Inbox
    # held only stubs. It arises now for the 507 date-prefixed items the move brought in.
    if [ -n "$slug" ]; then
      case "$(_qfm "$f" status)" in
        drafting|queued|active|archived|done)
          printf '%s %s intake-skipped (already a dev item — slug: + lifecycle status:)\n' \
            "$(date -Is)" "$(basename "$f" .md)" >> "$CB_HOME/logs/events"
          continue;;
      esac
    fi
    jira="$(_jira_key "$(_qfm "$f" jira)")"
    # Identity from the BODY only when the body is unambiguous. A document naming
    # several tickets has no single identity: slugging it to the first key names an
    # arbitrary ticket and the slug moves as the document is edited. Bias TIGHT
    # (per the header): a miss is recovered by /eod or Kyle; a false promotion
    # mints a phantom queue entry against work that may already be delivered.
    if [ -z "$jira" ]; then
      local nkeys; nkeys="$(_body_keys "$f" | grep -c . || true)"
      if [ "${nkeys:-0}" -eq 1 ]; then
        jira="$(_body_keys "$f")"
      elif [ "${nkeys:-0}" -gt 1 ] && [ -z "$slug" ]; then
        printf '%s %s intake-skipped (ambiguous identity: %s tickets in body, no slug:/jira:)\n' \
          "$(date -Is)" "$(basename "$f" .md)" "$nkeys" >> "$CB_HOME/logs/events"
        continue
      fi
      # nkeys > 1 WITH an explicit slug: honour the slug, leave `jira` unset —
      # picking one of several would be the same guess in a different place.
    fi
    [ -n "$slug" ] || { [ -n "$jira" ] && slug="$(_slugify "$jira")"; }
    [ -n "$slug" ] || slug="$(_slugify "$(basename "$f" .md | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-//')")"
    domain="$(_qfm "$f" domain)"; case "$domain" in *'|'*) domain="";; esac
    repo="$(_qfm "$f" repo)"; [ -n "$repo" ] || { [ -n "$jira" ] && repo="$(_repo_for_jira "$jira")"; }
    needs=""; [ -n "$repo" ] && [ -n "$(_deliverable_repo "$repo")" ] || needs=1
    _emit_item "$slug" "$domain" "$jira" "$repo" "" "$needs" "[[00 Inbox/$(basename "$f" .md)]]" "" "$f" || true
  done
  # 2. `#queue`-tagged daily-note lines (opt-in from the daily note)
  local daily
  daily="$CB_VAULT/Daily/$(date -d "@${CB_NOW:-$(date +%s)}" +%Y 2>/dev/null || date +%Y)/$(date -d "@${CB_NOW:-$(date +%s)}" +%F 2>/dev/null || date +%F).md"
  [ -f "$daily" ] && _promote_daily_queue "$daily"
  flock -u 7
}

# _deliverable_repo REPO — the registry project whose repo matches AND whose
# delivery is a deliverable mode (mirrors cb-intake's own gate; empty otherwise).
_deliverable_repo() {
  awk -v r="$1" '
    /^- project:/ { repo=""; del="" }
    $1=="repo:" { repo=$2 }
    $1=="delivery:" { del=$2; if (repo==r && (del=="bitbucket-pr" || del=="local-only")) { print; exit } }
  ' "$CB_REGISTRY" 2>/dev/null
}

# _promote_daily_queue DAILY — promote each un-annotated `#queue` line to a queued
# dev item and annotate the line in place (additive edit) so it isn't re-picked.
_promote_daily_queue() {
  local daily="$1" tmp line slug jira repo needs text
  tmp="$(mktemp)"
  while IFS= read -r line; do
    if [[ "$line" == *'#queue'* ]] && [[ "$line" != *'→ [[00 Inbox/'* ]]; then
      text="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[-*][[:space:]]*(\[[ x]\][[:space:]]*)?//; s/#queue//g; s/[[:space:]]+$//')"
      jira="$(_jira_key "$text")"
      slug="$([ -n "$jira" ] && _slugify "$jira" || _slugify "$text")"
      if [ -n "$slug" ]; then
        repo="$([ -n "$jira" ] && _repo_for_jira "$jira" || true)"
        needs=""; [ -n "$repo" ] && [ -n "$(_deliverable_repo "$repo")" ] || needs=1
        # `#queue` is an explicit human opt-in — the tag IS the review, so this path
        # keeps the claimable `queued` status that auto-discovery no longer gets.
        _emit_item "$slug" "" "$jira" "$repo" "" "$needs" "daily-note #queue" "queued" || true
        line="$line → [[00 Inbox/$slug]]"
      fi
    fi
    printf '%s\n' "$line" >> "$tmp"
  done < "$daily"
  mv -f "$tmp" "$daily"
}

# =============================================================================
# Job A3 — the intake→dispatch strand janitor (2026-08-02)
# =============================================================================
# cb-intake claims DURABLY (`queued` -> `active`, under flock) and only then
# fires `dispatch-request <slug>` into the coordinator pane by raw send-keys.
# send-keys exits 0 the moment tmux hands the byte to the pty, so a TUI that
# swallows the key looks exactly like a delivered dispatch. The item is left
# `active` with no worktree, no session and no task dir — invisible to cb-reap
# and cb-watch, holding a claim slot forever. Two items stranded that way on
# 2026-08-01, one for 11h40m. Under the hourly cron the keystroke is belt-and-
# braces (the coordinator also reads cb-intake's stdout); under
# cerebro-intake.timer it is the ONLY channel, which is why this gates arming.
#
# The janitor is deliberately MARKER-GATED: it only ever touches items intake
# itself claimed this cycle, never an item that reached `active` some other way.
# That is what makes it safe. A hand-flipped `active` item, a paused-via-adopt
# item whose session was killed, and a finished ops item whose window has closed
# all look identical to a strand from the outside — reverting any of them would
# do real damage. Intake knows which items IT claimed; nothing else does.
#
#   $CB_HOME/claims/<slug>   live claim marker: item=, claimed=, refires=
#   $CB_HOME/strands/<slug>  persistent revert counter, cleared on a confirmed
#                            spawn — the loop breaker (see below)
#
# Recovery policy (Kyle's brief, 2026-08-02): re-fire once, then
# revert-and-surface on a second miss. A single swallowed Enter is the common
# case and costs nothing to retry; a second miss means the pane is wedged or the
# model never ran the dispatch, and re-firing into that forever is a silent loop.
_claims_dir()  { printf '%s' "${CB_CLAIMS_DIR:-$CB_HOME/claims}"; }
_strands_dir() { printf '%s' "${CB_STRANDS_DIR:-$CB_HOME/strands}"; }

# cb_claim_mark SLUG ITEM-FILE — record that intake is about to claim SLUG.
# Call this BEFORE the status flip, never after: a marker with no flip is inert
# (the janitor sees status != active and drops it), a flip with no marker is the
# unrecoverable state this whole file exists to prevent.
# Preserves any existing marker's refire count — a re-claim of an item that
# stranded earlier should not look like a fresh first attempt.
cb_claim_mark() {
  local slug="$1" item="$2" d; d="$(_claims_dir)"
  mkdir -p "$d" 2>/dev/null || return 0
  printf 'item=%s\nclaimed=%s\nrefires=0\n' "$item" "${CB_NOW:-$(date +%s)}" > "$d/$slug" 2>/dev/null || true
}
# cb_claim_clear SLUG — drop the live marker (claim rolled back, or spawn
# confirmed). Does NOT touch the strand counter; only a confirmed spawn does.
cb_claim_clear() { rm -f "$(_claims_dir)/$1" 2>/dev/null || true; }
_claim_field() { awk -F= -v k="$2" '$1==k{sub("^" k "=",""); print; exit}' "$(_claims_dir)/$1" 2>/dev/null; }

# _spawn_evidence ITEM-FILE SLUG — 0 if ANYTHING proves the dispatch reached a
# spawn. Deliberately a union and deliberately generous: a false "stranded" is
# the only way this janitor can hurt, so every independent signal counts.
#   worktree_path:   the dispatch skill filled the frontmatter (code lane)
#   task dir         cb-start wrote $CB_HOME/tasks/<slug> (all three lanes)
#   worktree dir     `git worktree add` landed, frontmatter not yet written
#   session/window   a live conductor (code: session <slug>) or X-Man
#                    (ops/research: window <slug> in the cb session)
# Ordering note (verified against cb-start:400-410): the task dir is created
# AFTER `git fetch` + `git worktree add`, so a genuinely mid-spawn code item can
# briefly show none of these. The grace window — not the evidence test — is what
# covers that window, which is why it is minutes and not seconds.
_spawn_evidence() {
  local f="$1" slug="$2" root repo proj
  if [ -n "$(_qfm "$f" worktree_path)" ]; then return 0; fi
  # PREFIX match, not equality. A spawn's task slug is allowed to extend the dev
  # item's — live on 2026-08-02, dev item `cerebro-intake-strand-janitor` was
  # running as task `cerebro-intake-strand-janitor-build`. Under an equality test
  # that item reads as stranded while its X-Man is working, and the janitor would
  # re-dispatch it. A prefix hit can only ever err toward NOT recovering, which is
  # the direction this whole component has to fail in.
  if compgen -G "$CB_HOME/tasks/$slug*" >/dev/null 2>&1; then return 0; fi
  repo="$(_qfm "$f" repo)"
  if [ -n "$repo" ]; then
    proj="$(_deliverable_project "$repo")"
    if [ -n "$proj" ]; then
      root="$(registry_worktree_root "$proj")"
      if [ -n "$root" ] && compgen -G "$root/$slug*" >/dev/null 2>&1; then return 0; fi
    fi
  fi
  # a conductor session (code) or an X-Man window in the cb session (ops/research),
  # named for the slug — same prefix tolerance, same reasoning
  if eval "${CB_SESSION_LIST_CMD:-tmux list-sessions -F '#{session_name}' 2>/dev/null}" \
       | _name_prefix_match "$slug"; then return 0; fi
  if eval "${CB_WINDOW_LIST_CMD:-tmux list-windows -t cb -F '#{window_name}' 2>/dev/null || true}" \
       | _name_prefix_match "$slug"; then return 0; fi
  return 1
}
# _name_prefix_match SLUG — 0 if any stdin line starts with SLUG. index(), not a
# regex: slugs carry `.` and `-`, which a pattern would read as metacharacters.
_name_prefix_match() { awk -v s="$1" 'index($0, s) == 1 { f=1; exit } END { exit !f }'; }
# _deliverable_project REPO — the registry PROJECT name for a deliverable repo
# row (_deliverable_repo prints the matching line, not the project).
_deliverable_project() {
  awk -v r="$1" '
    /^- project:/ { proj=$3; repo=""; del="" }
    $1=="repo:" { repo=$2 }
    $1=="delivery:" { del=$2; if (repo==r && (del=="bitbucket-pr" || del=="local-only")) { print proj; exit } }
  ' "$CB_REGISTRY" 2>/dev/null
}

# _strand_refire SLUG — re-send the dispatch-request, same raw path intake used.
# NOT cb_coord_send: making intake delivery-verified is a separate item, and
# lib/coordinator.sh is being re-seeded concurrently. Enter stays a separate key
# event (the 7/13 hotfix — a same-burst Enter reads as a newline in the TUI).
_strand_refire() {
  local slug="$1" tmux="${CB_TMUX_BIN:-tmux}"
  "$tmux" send-keys -t "${CB_SESSION:-Cerebro}" "dispatch-request $slug" || return 1
  sleep "${CB_SEND_DELAY:-0.3}"
  "$tmux" send-keys -t "${CB_SESSION:-Cerebro}" Enter || return 1
}

# _strand_revert ITEM-FILE — flip the first `status: active` back to `queued`.
_strand_revert() {
  local f="$1" tmp
  tmp="$(mktemp "$(dirname "$f")/.strand.XXXXXX")" || return 1
  awk 'BEGIN{d=0} /^status: active[[:space:]]*$/ && !d {print "status: queued"; d=1; next} {print}' "$f" > "$tmp" \
    && mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}
# _strand_hold ITEM-FILE REASON — write a `hold:` line under `status:`. The loop
# breaker. Revert-and-surface alone re-queues the item, the next tick re-claims
# it, and a genuinely dead coordinator turns that into an hourly claim/strand/
# revert cycle that is quieter than the bug it replaced — the same silent loop
# the re-fire cap exists to prevent, one level up. `hold:` is already a hard
# intake gate (cb-intake:106), so this takes the item out of the loop and puts
# it in front of a human with the reason attached, using a mechanism that exists.
_strand_hold() {
  local f="$1" reason="$2" tmp
  [ -n "$(_qfm "$f" hold)" ] && return 0
  tmp="$(mktemp "$(dirname "$f")/.strand.XXXXXX")" || return 1
  awk -v r="$reason" 'BEGIN{d=0} {print} /^status:/ && !d {print "hold: " r; d=1}' "$f" > "$tmp" \
    && mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# reconcile_strands — the tick step. Walks the live claim markers, drops the ones
# whose dispatch provably landed, and recovers the rest once they age past the
# grace window.
#
# Grace window: CB_STRAND_GRACE_SECS, default 600 (10 min). It has to clear a
# normal spawn's fetch + worktree-add (seconds to ~1 min observed) by a wide
# margin, and stay far short of the hourly tick so a strand is caught on the NEXT
# tick rather than sleeping until the one after.
#
# Runs under the intake lock and BEFORE the claim loop, so an item recovered on
# this tick is claimable on this same tick — same reasoning as promote_drafting.
reconcile_strands() {
  local d f slug item now grace refires strands maxcyc claimed_at n=0
  d="$(_claims_dir)"; [ -d "$d" ] || return 0
  grace="${CB_STRAND_GRACE_SECS:-600}"
  maxcyc="${CB_STRAND_MAX_CYCLES:-2}"
  now="${CB_NOW:-$(date +%s)}"
  mkdir -p "$CB_HOME/logs" "$CB_HOME/locks" "$(_strands_dir)"
  # Same flock discipline as the claim itself: read-then-act on shared fleet
  # state. Without it two overlapping ticks each see one un-recovered strand and
  # both re-fire it. Taken and released here, never nested inside the claim lock.
  exec 6>"$CB_HOME/locks/intake"; flock 6
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    slug="$(basename "$f")"
    item="$(_claim_field "$slug" item)"
    # the item file is gone (archived, renamed) — the marker has nothing to guard
    [ -n "$item" ] && [ -f "$item" ] || { cb_claim_clear "$slug"; continue; }
    # not active any more: the claim was rolled back, or the work completed and
    # was archived past `active`. Either way there is no strand to recover.
    [ "$(_qfm "$item" status)" = "active" ] || { cb_claim_clear "$slug"; continue; }
    if _spawn_evidence "$item" "$slug"; then
      cb_claim_clear "$slug"; rm -f "$(_strands_dir)/$slug" 2>/dev/null || true
      continue
    fi
    claimed_at="$(_claim_field "$slug" claimed)"
    case "$claimed_at" in ''|*[!0-9]*) cb_claim_clear "$slug"; continue;; esac
    [ $(( now - claimed_at )) -ge "$grace" ] || continue
    refires="$(_claim_field "$slug" refires)"
    case "$refires" in ''|*[!0-9]*) refires=0;; esac
    if [ "$refires" -lt 1 ] && _strand_refire "$slug"; then
      # First miss. Re-fire and restart the clock — the re-fire gets its own full
      # grace window before it counts as the second miss.
      printf 'item=%s\nclaimed=%s\nrefires=%s\n' "$item" "$now" "$(( refires + 1 ))" > "$f"
      printf '%s %s strand-refired (dispatch never landed; re-sent dispatch-request, %ss grace)\n' \
        "$(date -Is)" "$slug" "$grace" >> "$CB_HOME/logs/events"
      n=$(( n + 1 )); continue
    fi
    # Second miss (or the re-fire send itself failed — a dead pane, which is the
    # same verdict reached sooner). Give the claim back and say so.
    if _strand_revert "$item"; then
      strands="$(cat "$(_strands_dir)/$slug" 2>/dev/null || echo 0)"
      strands=$(( strands + 1 )); printf '%s\n' "$strands" > "$(_strands_dir)/$slug"
      cb_claim_clear "$slug"
      printf '%s %s strand-reverted (active->queued; dispatch never landed after a re-fire; cycle %s)\n' \
        "$(date -Is)" "$slug" "$strands" >> "$CB_HOME/logs/events"
      if [ "$strands" -ge "$maxcyc" ]; then
        # phrased without implying recency: the counter is cleared by a confirmed
        # spawn, not by time or by Kyle clearing the hold, so "$strands cycles" can
        # span weeks and two unrelated episodes
        _strand_hold "$item" "stranded — $strands intake claims have ended without a dispatch landing (counter clears on a confirmed spawn); check the coordinator pane, then delete this line to requeue"
        printf '%s %s strand-held (%s strand cycles — hold: set, out of the claim loop until a human clears it)\n' \
          "$(date -Is)" "$slug" "$strands" >> "$CB_HOME/logs/events"
      fi
      n=$(( n + 1 ))
    else
      printf '%s %s strand-revert-FAILED (could not rewrite %s — left active, holding a slot)\n' \
        "$(date -Is)" "$slug" "$item" >> "$CB_HOME/logs/events"
    fi
  done
  flock -u 6; exec 6>&-
  [ "$n" -gt 0 ] && echo "cb-intake: recovered $n stranded dispatch(es) — see $CB_HOME/logs/events"
  return 0
}
