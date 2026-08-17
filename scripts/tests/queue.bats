#!/usr/bin/env bats
# lib/queue.sh — the Inbox-as-queue promoter (Job A). Covers milestone 5's bats
# path: a work-shaped Inbox item queues (+ dispatches if eligible, flags if not),
# a non-work item is left for /eod, and a #queue daily-note line is picked up.
# Tested both directly (promote_inbox) and end-to-end through `cb-intake --tick`.

setup() {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks" "$CB_HOME/locks" "$CB_HOME/logs"
  export CB_VAULT="$BATS_TEST_TMPDIR/vault"
  # ⚠️ ITEMS and INBOX are the SAME directory as of 2026-08-14, when `00 Inbox/`
  # became the single work surface. Both names are kept so each assertion still
  # reads in the register it means -- source stub vs promoted dev item -- but the
  # two are no longer separable by path. Assertions that used to count files in
  # $ITEMS to prove "nothing was promoted" now count PROMOTED items instead; see
  # promoted_count below. Counting the directory would count the source stub.
  export ITEMS="$CB_VAULT/00 Inbox"; mkdir -p "$ITEMS"
  export INBOX="$CB_VAULT/00 Inbox"; mkdir -p "$INBOX"
  export CB_REGISTRY="$BATS_TEST_TMPDIR/projects.md"
  cat > "$CB_REGISTRY" <<'EOF'
- project: ultron
  repo: ultron
  base: main
  delivery: bitbucket-pr
  jira_key_prefix: EJA
- project: friday
  repo: friday
  delivery: research-only
EOF
  export CB_NOW=1784160000   # 2026-07-16T00:00:00Z (deterministic slug/date)
  # intake mocks (for the end-to-end tick tests)
  printf 'MemAvailable:   33554432 kB\n' > "$BATS_TEST_TMPDIR/meminfo"
  export CB_FREE_CMD="cat '$BATS_TEST_TMPDIR/meminfo'"
  export CB_SESSION_LIST_CMD="printf ''" CB_WINDOW_LIST_CMD="printf ''"
  export CB_TMUX_BIN="$BATS_TEST_TMPDIR/faketmux"
  cat > "$CB_TMUX_BIN" <<'EOF'
#!/usr/bin/env bash
echo "tmux $*" >> "$CB_TMUX_LOG"
EOF
  chmod +x "$CB_TMUX_BIN"; export CB_TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"; : > "$CB_TMUX_LOG"
  export CB_SEND_DELAY=0
}

mk_inbox() { printf '%s' "$2" > "$INBOX/$1.md"; }

@test "work-shaped Inbox item (EJA jira) → DRAFTING dev item, repo inferred" {
  mk_inbox "2026-07-16-fix-something-EJA-3487" $'---\ndomain: forms\njira: EJA-3487\n---\n\n# Fix the disclosure gate\n'
  load ../lib/queue.sh
  promote_inbox
  f="$ITEMS/eja-3487.md"
  [ -f "$f" ]
  grep -q '^status: drafting' "$f"       # auto-discovered → NOT claimable until Kyle promotes
  ! grep -q '^status: queued' "$f"
  grep -q '^repo: ultron' "$f"          # inferred from EJA → ultron
  grep -q '^domain: forms' "$f"
  ! grep -q 'needs_scoping' "$f"        # eligible → no flag
  grep -q 'eja-3487 intake-promoted (drafting)' "$CB_HOME/logs/events"
}

@test "end-to-end: an Inbox-promoted item is NOT claimed or dispatched in the same tick" {
  mk_inbox "2026-07-16-fix-EJA-3487" $'---\ndomain: forms\njira: EJA-3487\n---\n\n# Fix it\n'
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: drafting' "$ITEMS/eja-3487.md"       # promoted, deliberately not claimed
  ! grep -q '^status: active' "$ITEMS/eja-3487.md"
  ! grep -q 'dispatch-request eja-3487' "$CB_TMUX_LOG"   # auto-promotion never auto-dispatches
}

# promoted_count — how many dev items promote_inbox/_emit_item actually minted.
# _emit_item stamps every item it writes with `_Promoted from ... by cb-intake`,
# which is the only thing that distinguishes a promoted item from the Inbox stub
# it came from now that both live in `00 Inbox/`.
promoted_count() { grep -lF 'by cb-intake (Inbox-as-queue)' "$ITEMS"/*.md 2>/dev/null | wc -l; }

@test "ambiguous identity: a multi-ticket body with no explicit slug/jira is REFUSED, not guessed" {
  mk_inbox "2026-07-16-open-pr-cleanup" $'---\ndomain: forms\n---\n\n# Open PR cleanup\n\n- EJA-3664 is already built\n- EJA-3487 needs a re-word\n- ASD-641 correlation id\n'
  load ../lib/queue.sh
  promote_inbox
  [ "$(promoted_count)" -eq 0 ]         # no item minted under an arbitrary key
  [ ! -f "$ITEMS/eja-3664.md" ]
  [ ! -f "$ITEMS/eja-3487.md" ]
  grep -q 'intake-skipped (ambiguous identity' "$CB_HOME/logs/events"
}

@test "single-ticket body with no frontmatter jira still promotes under that key" {
  mk_inbox "2026-07-16-one-ticket-only" $'---\ndomain: forms\n---\n\n# Just the one\n\nEJA-3487 is the only key here, mentioned EJA-3487 twice.\n'
  load ../lib/queue.sh
  promote_inbox
  [ -f "$ITEMS/eja-3487.md" ]           # unambiguous → body key is a safe identity
  grep -q '^jira: EJA-3487' "$ITEMS/eja-3487.md"
  grep -q '^status: drafting' "$ITEMS/eja-3487.md"
}

@test "an explicit slug wins over a multi-ticket body (no refusal, no guessed jira)" {
  mk_inbox "2026-07-16-explicit" $'---\nslug: my-explicit-slug\ndomain: forms\n---\n\n# x\n\nEJA-3664 and EJA-3487 and ASD-641.\n'
  load ../lib/queue.sh
  promote_inbox
  [ -f "$ITEMS/my-explicit-slug.md" ]
  ! grep -q '^jira:' "$ITEMS/my-explicit-slug.md"   # cannot pick one of three — leave it unset
}

@test "dedup is ARCHIVE-aware: a slug already archived is never re-promoted" {
  mkdir -p "$CB_VAULT/02 Areas/development/archive/items"
  printf -- '---\nslug: eja-3487\nstatus: archived\n---\n' > "$CB_VAULT/02 Areas/development/archive/items/eja-3487.md"
  mk_inbox "2026-07-16-EJA-3487-again" $'---\ndomain: forms\njira: EJA-3487\n---\n\n# already shipped\n'
  load ../lib/queue.sh
  promote_inbox
  [ ! -f "$ITEMS/eja-3487.md" ]         # completed work must not re-enter the pool
}

@test "#queue daily-note lines still land at queued — the tag IS the human review" {
  local ymd yr daily
  ymd="$(date -d "@$CB_NOW" +%F)"; yr="$(date -d "@$CB_NOW" +%Y)"
  mkdir -p "$CB_VAULT/Daily/$yr"; daily="$CB_VAULT/Daily/$yr/$ymd.md"
  printf '# %s\n\n## Notes\n- fix the annuitant edge case EJA-3600 #queue\n' "$ymd" > "$daily"
  load ../lib/queue.sh
  promote_inbox
  [ -f "$ITEMS/eja-3600.md" ]
  grep -q '^status: queued' "$ITEMS/eja-3600.md"   # explicit opt-in keeps the fast path
}

@test "work-shaped but below the bar (ASD → no mapped repo) → drafting + needs_scoping, NOT dispatched" {
  mk_inbox "2026-07-16-asd-thing-ASD-1200" $'---\ndomain: case-flow\njira: ASD-1200\n---\n\n# Some ASD item\n'
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  f="$ITEMS/asd-1200.md"
  [ -f "$f" ]
  grep -q '^status: drafting' "$f"       # surfaced for review, not silently stalled and not claimable
  grep -q '^needs_scoping: true' "$f"
  ! grep -q 'dispatch-request asd-1200' "$CB_TMUX_LOG"   # PO-owned / no repo → never auto-dispatched
  grep -q 'asd-1200 intake-promoted (needs-scoping)' "$CB_HOME/logs/events"
}

@test "a self-declared artifact type vetoes promotion even with domain + jira" {
  # every `type:` in the real Inbox is an artifact type (report / rca / assessment /
  # ops-report / ratify-worklist / …); none is `code` or `research`.
  for ty in report rca assessment ops-report design-proposal inbox-capture watch investigation; do
    rm -f "$ITEMS"/*.md
    mk_inbox "2026-07-16-artifact-$ty" "$(printf -- '---\ntype: %s\ndomain: forms\njira: EJA-3487\n---\n\n# an output document\n' "$ty")"
    load ../lib/queue.sh
    promote_inbox
    [ ! -f "$ITEMS/eja-3487.md" ] || { echo "type=$ty leaked through"; false; }
    rm -f "$INBOX/2026-07-16-artifact-$ty.md"
  done
}

@test "the inbox-stub template shape (NO type:) still promotes — the veto must not break capture" {
  # 99 Meta/templates/inbox-stub.md carries created/domain/jira and NO type field
  mk_inbox "2026-07-16-real-capture" $'---\ncreated: 2026-07-16\ndomain: forms\njira: EJA-3487\n---\n\n# A real thing to fix\n'
  load ../lib/queue.sh
  promote_inbox
  [ -f "$ITEMS/eja-3487.md" ]
  grep -q '^status: drafting' "$ITEMS/eja-3487.md"
}

@test "an explicit work type still promotes" {
  mk_inbox "2026-07-16-explicit-work" $'---\ntype: code\ndomain: forms\njira: EJA-3487\n---\n\n# Fix it\n'
  load ../lib/queue.sh
  promote_inbox
  [ -f "$ITEMS/eja-3487.md" ]
}

@test "a needs-Kyle register item is NEVER promoted, even carrying a real EJA key" {
  # The register moved INTO `00 Inbox/` on 2026-08-14, so promote_inbox's glob now sees
  # all ~145 of its items -- and most of them name a ticket. `type: decision` must veto
  # them via _is_work_shaped, or an hourly timer mints a phantom dev item for a question
  # Kyle has not answered yet. This is the folder-merge hazard one layer in from the
  # ITEMS/INBOX collapse; it was not reachable before the move.
  mk_inbox "2026-08-03-needs-kyle-lori-sadler" $'---\ntype: decision\nstatus: needs-kyle\nseverity: high\ndecide-by: 2026-08-06\nid: lori-sadler-is-waiting-on-you-on-two-tickets\nlanded: 2026-08-03\ndomain: forms\ntickets: [EJA-3591, EJA-3678]\n---\n\n- [ ] 2026-08-03 - Lori Sadler is waiting on you on two tickets. Needs: a call.\n'
  load ../lib/queue.sh
  promote_inbox
  [ "$(promoted_count)" -eq 0 ]
  [ -f "$INBOX/2026-08-03-needs-kyle-lori-sadler.md" ]   # left in place, untouched
}

@test "the other new Inbox types are vetoed too — friction, opportunity, report, dev-item" {
  # Part 4 lands `type: friction` / `type: opportunity` files here, and step 2 backfilled
  # a clock onto every report already in the folder. None of them are promotable work.
  for ty in friction opportunity report dev-item; do
    mk_inbox "2026-08-14-x-$ty" $'---\ntype: '"$ty"$'\nstatus: needs-kyle\ndomain: tooling\njira: EJA-4200\n---\n\n# thing\n\nEJA-4200 is involved.\n'
  done
  load ../lib/queue.sh
  promote_inbox
  [ "$(promoted_count)" -eq 0 ]
}

@test "a DATE-PREFIXED dev item is never duplicated — identity is frontmatter slug:, not filename" {
  # The regression the step-6 supervised dry-run caught. 507 of the moved dev items are
  # date-prefixed and 39 declare a `slug:` that differs from their filename. _emit_item
  # used to dedup on "$items/$slug.md" alone, so it did not see
  # `2026-07-17-bugpush-eja-3591-....md` when asked to mint `bugpush-eja-3591-....md`,
  # and would have created a second file for work that already had one. Harmless while
  # dev items lived in their own folder; a duplicate factory once 00 Inbox became both.
  mk_inbox "2026-07-17-bugpush-eja-3591-ny-usaa-replacement-forms-tab" $'---\nslug: bugpush-eja-3591-ny-usaa-replacement-forms-tab\nstatus: drafting\ndomain: forms\njira: EJA-3591\nrepo: ultron\n---\n\n# NY USAA replacement forms tab blank\n\nReal body with enough to build from.\n'
  load ../lib/queue.sh
  promote_inbox
  [ ! -f "$ITEMS/bugpush-eja-3591-ny-usaa-replacement-forms-tab.md" ]   # no undated twin
  [ "$(promoted_count)" -eq 0 ]
}

@test "a file that IS a dev item (slug: + lifecycle status:) is skipped, not re-promoted" {
  mk_inbox "2026-05-01-session-timeout-EJA-2621" $'---\nslug: session-timeout-EJA-2621\nstatus: active\ndomain: forms\njira: EJA-2621\nrepo: ultron\n---\n\n# Session timeout\n\nBody with real content to build from.\n'
  load ../lib/queue.sh
  promote_inbox
  [ "$(promoted_count)" -eq 0 ]
  [ ! -f "$ITEMS/session-timeout-EJA-2621.md" ]
  grep -q 'intake-skipped (already a dev item' "$CB_HOME/logs/events"
}

@test "a stub naming its own slug but carrying NO lifecycle status still promotes" {
  # The other side of that guard — this is the pre-existing "explicit slug wins" shape,
  # and the dev-item skip must not swallow it.
  mk_inbox "2026-07-16-stub-with-slug" $'---\nslug: my-explicit-slug\ndomain: forms\n---\n\n# x\n\nEJA-3664 and EJA-3487.\n'
  load ../lib/queue.sh
  promote_inbox
  [ -f "$ITEMS/my-explicit-slug.md" ]
}

@test "slug dedup reads FRONTMATTER only — a slug named in prose does not block a promotion" {
  # The mirror of the reactive-intake dedup lesson: matching a slug anywhere in a file
  # produces false holds, and a held item is silently never queued.
  mk_inbox "2026-07-16-some-analysis" $'---\ncreated: 2026-07-16\n---\n\n# Analysis\n\nSupersedes slug: eja-3487 per the triage.\n'
  mk_inbox "2026-07-16-EJA-3487" $'---\ndomain: forms\njira: EJA-3487\n---\n\n# real work\n'
  load ../lib/queue.sh
  promote_inbox
  [ -f "$ITEMS/eja-3487.md" ]        # promoted despite the prose mention elsewhere
}

@test "a non-work Inbox item is left untouched for /eod (no dev item, not deleted)" {
  mk_inbox "2026-07-16-lunch-notes" $'---\ncreated: 2026-07-16\n---\n\n# Random thoughts from lunch\n\nNothing actionable here.\n'
  load ../lib/queue.sh
  promote_inbox
  [ "$(promoted_count)" -eq 0 ]              # nothing promoted
  [ -f "$INBOX/2026-07-16-lunch-notes.md" ]  # left in place for the routing pass
}

@test "a raw unfilled inbox-stub (placeholder domain, empty jira) is NOT promoted" {
  mk_inbox "2026-07-16-blank-stub" $'---\ncreated: 2026-07-16\ndomain: ownership | forms | products | case-flow | carriers\njira: \n---\n\n# [One-line description]\n'
  load ../lib/queue.sh
  promote_inbox
  [ "$(promoted_count)" -eq 0 ]
}

@test "#claude-tagged Inbox item (no jira) → drafting + needs_scoping" {
  mk_inbox "2026-07-16-refactor-idea" $'---\ncreated: 2026-07-16\n---\n\n# Refactor the cb-watch tick #claude\n'
  load ../lib/queue.sh
  promote_inbox
  # slug from filename (no jira)
  f="$ITEMS/refactor-idea.md"
  [ -f "$f" ]
  grep -q '^status: drafting' "$f"
  grep -q '^needs_scoping: true' "$f"       # no repo mapping → below bar
}

@test "idempotent: two ticks → one dev item, never re-promoted" {
  mk_inbox "2026-07-16-EJA-3487" $'---\ndomain: forms\njira: EJA-3487\n---\n\n# x\n'
  load ../lib/queue.sh
  promote_inbox
  first="$(cat "$ITEMS/eja-3487.md")"
  # even after cb-intake flips it active, a second promote must not recreate/clobber
  promote_inbox
  [ "$(promoted_count)" -eq 1 ]
  [ "$(cat "$ITEMS/eja-3487.md")" = "$first" ]
}

@test "#queue daily-note line is picked up and annotated in place" {
  local ymd yr daily
  ymd="$(date -d "@$CB_NOW" +%F)"; yr="$(date -d "@$CB_NOW" +%Y)"
  mkdir -p "$CB_VAULT/Daily/$yr"; daily="$CB_VAULT/Daily/$yr/$ymd.md"
  cat > "$daily" <<EOF
# $ymd

## Notes
- look into the annuitant edge case EJA-3500 #queue
- a normal note with no tag
EOF
  load ../lib/queue.sh
  promote_inbox
  [ -f "$ITEMS/eja-3500.md" ]
  grep -q '^status: queued' "$ITEMS/eja-3500.md"
  grep -q '→ \[\[00 Inbox/eja-3500\]\]' "$daily"   # line annotated
  grep -q 'a normal note with no tag' "$daily"                        # untagged line untouched
  # second run does not re-annotate or duplicate
  promote_inbox
  [ "$(grep -c '→ \[\[00 Inbox/eja-3500\]\]' "$daily")" -eq 1 ]
}

# --- promote_drafting (P2, 2026-07-31): keep the queue fed without hand-flipping ---

mk_draft() { # mk_draft <slug> <extra-frontmatter-lines>
  { printf -- '---\nslug: %s\nstatus: drafting\njira: EJA-9001\nrepo: ultron\n' "$1"
    [ -n "${2:-}" ] && printf '%s\n' "$2"
    printf -- '---\n\n# %s\n\n## Goal\nA real, buildable spec.\n' "$1"
  } > "$ITEMS/$1.md"
}

@test "promote_drafting flips an eligible drafting item to queued" {
  mk_draft okitem
  run bash -c 'source scripts/cerebro/lib/paths.sh; source scripts/cerebro/lib/registry.sh; source scripts/cerebro/lib/queue.sh; promote_drafting'
  [ "$status" -eq 0 ]
  grep -q '^status: queued' "$ITEMS/okitem.md"
  grep -q 'promoted drafting->queued' "$CB_HOME/logs/events"
}

@test "promote_drafting REFUSES an item carrying hold:" {
  mk_draft helditem 'hold: "waiting on a product call"'
  run bash -c 'source scripts/cerebro/lib/paths.sh; source scripts/cerebro/lib/registry.sh; source scripts/cerebro/lib/queue.sh; promote_drafting'
  grep -q '^status: drafting' "$ITEMS/helditem.md"
}

@test "promote_drafting REFUSES a bare stub and says why" {
  printf -- '---\nslug: stub\nstatus: drafting\njira: EJA-9002\nrepo: ultron\n---\n\n# stub\n' > "$ITEMS/stub.md"
  run bash -c 'source scripts/cerebro/lib/paths.sh; source scripts/cerebro/lib/registry.sh; source scripts/cerebro/lib/queue.sh; promote_drafting'
  grep -q '^status: drafting' "$ITEMS/stub.md"
  grep -q 'stub promote-skipped (bare stub' "$CB_HOME/logs/events"
}

@test "promote_drafting REFUSES an item already started (worktree_path/branch)" {
  mk_draft started 'worktree_path: ~/code/worktrees/started'
  run bash -c 'source scripts/cerebro/lib/paths.sh; source scripts/cerebro/lib/registry.sh; source scripts/cerebro/lib/queue.sh; promote_drafting'
  grep -q '^status: drafting' "$ITEMS/started.md"
}

@test "promote_drafting REFUSES a non-deliverable repo and a missing jira" {
  printf -- '---\nslug: nodel\nstatus: drafting\njira: EJA-9003\nrepo: friday\n---\n\n## Goal\nreal spec here\n' > "$ITEMS/nodel.md"
  printf -- '---\nslug: nojira\nstatus: drafting\nrepo: ultron\n---\n\n## Goal\nreal spec here\n' > "$ITEMS/nojira.md"
  run bash -c 'source scripts/cerebro/lib/paths.sh; source scripts/cerebro/lib/registry.sh; source scripts/cerebro/lib/queue.sh; promote_drafting'
  grep -q '^status: drafting' "$ITEMS/nodel.md"
  grep -q '^status: drafting' "$ITEMS/nojira.md"
}

@test "promote_drafting honours CB_PROMOTE_CAP — a wrong bar costs one wave, not a flood" {
  for s in c1 c2 c3 c4 c5; do mk_draft "$s"; done
  CB_PROMOTE_CAP=2 run bash -c 'source scripts/cerebro/lib/paths.sh; source scripts/cerebro/lib/registry.sh; source scripts/cerebro/lib/queue.sh; promote_drafting'
  [ "$(grep -l '^status: queued' "$ITEMS"/c?.md | wc -l)" -eq 2 ]
}

@test "CB_PROMOTE=0 disables auto-promotion entirely (kill switch)" {
  mk_draft offitem
  CB_PROMOTE=0 run bash -c 'source scripts/cerebro/lib/paths.sh; source scripts/cerebro/lib/registry.sh; source scripts/cerebro/lib/queue.sh; promote_drafting'
  grep -q '^status: drafting' "$ITEMS/offitem.md"
}

@test "promote_drafting REFUSES an item with open questions (spec-gated)" {
  { printf -- '---\nslug: gated\nstatus: drafting\njira: EJA-9100\nrepo: ultron\n---\n\n## Goal\nA real spec.\n\n## Open questions\n\n- Which settings? This gates everything.\n'
  } > "$ITEMS/gated.md"
  run bash -c 'source scripts/cerebro/lib/paths.sh; source scripts/cerebro/lib/registry.sh; source scripts/cerebro/lib/queue.sh; promote_drafting'
  grep -q '^status: drafting' "$ITEMS/gated.md"
  grep -q 'gated promote-skipped (open questions' "$CB_HOME/logs/events"
}

@test "an EMPTY open-questions heading does not gate (only real questions do)" {
  printf -- '---\nslug: emptyq\nstatus: drafting\njira: EJA-9101\nrepo: ultron\n---\n\n## Goal\nA real spec.\n\n## Open questions\n\n## References\n- a link\n' > "$ITEMS/emptyq.md"
  run bash -c 'source scripts/cerebro/lib/paths.sh; source scripts/cerebro/lib/registry.sh; source scripts/cerebro/lib/queue.sh; promote_drafting'
  grep -q '^status: queued' "$ITEMS/emptyq.md"
}

# --- Job A3: the intake→dispatch strand janitor ------------------------------
# cb-intake claims durably, then fires `dispatch-request` by raw send-keys, which
# exits 0 whether or not the TUI read the key. These cover the recovery: re-fire
# once, revert-and-surface on the second miss, and — the constraint that matters
# most — never touch an item that is genuinely mid-spawn.

mk_active() { # mk_active <slug> [extra frontmatter line]
  printf -- '---\nslug: %s\nstatus: active\nrepo: ultron\ndomain: forms\n%s---\n\n# %s\n' \
    "$1" "${2:+$2$'\n'}" "$1" > "$ITEMS/$1.md"
}
mk_marker() { # mk_marker <slug> <claimed-epoch> [refires]
  mkdir -p "$CB_HOME/claims"
  printf 'item=%s\nclaimed=%s\nrefires=%s\n' "$ITEMS/$1.md" "$2" "${3:-0}" > "$CB_HOME/claims/$1"
}

@test "strand janitor: an aged strand is RE-FIRED once, not reverted" {
  load ../lib/queue.sh
  export CB_NOW=2000 CB_STRAND_GRACE_SECS=600
  mk_active str-a; mk_marker str-a 1000 0
  reconcile_strands
  grep -q '^status: active' "$ITEMS/str-a.md"           # first miss never reverts
  grep -q 'dispatch-request str-a' "$CB_TMUX_LOG"
  grep -q 'str-a strand-refired' "$CB_HOME/logs/events"
  grep -q '^refires=1' "$CB_HOME/claims/str-a"
  grep -q '^claimed=2000' "$CB_HOME/claims/str-a"        # the re-fire restarts the clock
}

@test "strand janitor: inside the grace window nothing happens — the mid-spawn guard" {
  load ../lib/queue.sh
  export CB_NOW=1500 CB_STRAND_GRACE_SECS=600
  mk_active str-young; mk_marker str-young 1000 0
  reconcile_strands
  grep -q '^status: active' "$ITEMS/str-young.md"
  ! grep -q 'dispatch-request str-young' "$CB_TMUX_LOG"
  ! grep -q 'str-young strand' "$CB_HOME/logs/events"
  [ -f "$CB_HOME/claims/str-young" ]
}

@test "strand janitor: an IN-FLIGHT spawn (task dir present) is never reverted, however old" {
  load ../lib/queue.sh
  export CB_NOW=99999 CB_STRAND_GRACE_SECS=1
  mk_active str-live; mk_marker str-live 1000 1     # already re-fired: next stop is revert
  mkdir -p "$CB_HOME/tasks/str-live"                # cb-start got there first
  reconcile_strands
  grep -q '^status: active' "$ITEMS/str-live.md"
  ! grep -q 'str-live strand-reverted' "$CB_HOME/logs/events"
  [ ! -f "$CB_HOME/claims/str-live" ]               # evidence retires the marker
}

@test "strand janitor: worktree_path in the frontmatter is spawn evidence" {
  load ../lib/queue.sh
  export CB_NOW=99999 CB_STRAND_GRACE_SECS=1
  mk_active str-wt "worktree_path: $BATS_TEST_TMPDIR/wt"
  mk_marker str-wt 1000 1
  reconcile_strands
  grep -q '^status: active' "$ITEMS/str-wt.md"
  [ ! -f "$CB_HOME/claims/str-wt" ]
}

@test "strand janitor: a live tmux session named for the slug is spawn evidence" {
  load ../lib/queue.sh
  export CB_NOW=99999 CB_STRAND_GRACE_SECS=1
  export CB_SESSION_LIST_CMD="printf 'str-sess\n'"
  mk_active str-sess; mk_marker str-sess 1000 1
  reconcile_strands
  grep -q '^status: active' "$ITEMS/str-sess.md"
  [ ! -f "$CB_HOME/claims/str-sess" ]
}

@test "strand janitor: an ops X-Man's window in the cb session is spawn evidence" {
  load ../lib/queue.sh
  export CB_NOW=99999 CB_STRAND_GRACE_SECS=1
  export CB_WINDOW_LIST_CMD="printf 'bash\nstr-ops\n'"
  mk_active str-ops; mk_marker str-ops 1000 1
  reconcile_strands
  grep -q '^status: active' "$ITEMS/str-ops.md"
  [ ! -f "$CB_HOME/claims/str-ops" ]
}

@test "strand janitor: SECOND miss reverts active->queued and surfaces it" {
  load ../lib/queue.sh
  export CB_NOW=9000 CB_STRAND_GRACE_SECS=600
  mk_active str-b; mk_marker str-b 1000 1
  run reconcile_strands
  [ "$status" -eq 0 ]
  [[ "$output" == *"recovered 1 stranded dispatch"* ]]
  grep -q '^status: queued' "$ITEMS/str-b.md"
  ! grep -q '^status: active' "$ITEMS/str-b.md"
  grep -q 'str-b strand-reverted' "$CB_HOME/logs/events"
  [ ! -f "$CB_HOME/claims/str-b" ]
  [ "$(cat "$CB_HOME/strands/str-b")" = 1 ]
}

@test "strand janitor: a second strand CYCLE sets hold: — the loop breaker" {
  load ../lib/queue.sh
  export CB_NOW=9000 CB_STRAND_GRACE_SECS=600 CB_STRAND_MAX_CYCLES=2
  mkdir -p "$CB_HOME/strands"; printf '1\n' > "$CB_HOME/strands/str-c"   # stranded once already
  mk_active str-c; mk_marker str-c 1000 1
  reconcile_strands
  grep -q '^status: queued' "$ITEMS/str-c.md"
  grep -q '^hold: stranded' "$ITEMS/str-c.md"
  grep -q 'str-c strand-held' "$CB_HOME/logs/events"
}

@test "strand janitor: a confirmed spawn CLEARS the strand history" {
  load ../lib/queue.sh
  export CB_NOW=99999 CB_STRAND_GRACE_SECS=1
  mkdir -p "$CB_HOME/strands"; printf '1\n' > "$CB_HOME/strands/str-d"
  mk_active str-d; mk_marker str-d 1000 1
  mkdir -p "$CB_HOME/tasks/str-d"
  reconcile_strands
  [ ! -f "$CB_HOME/strands/str-d" ]
}

@test "strand janitor: a failed re-fire send is the same verdict, reached sooner" {
  load ../lib/queue.sh
  export CB_NOW=9000 CB_STRAND_GRACE_SECS=600
  cat > "$CB_TMUX_BIN" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$CB_TMUX_BIN"
  mk_active str-dead; mk_marker str-dead 1000 0      # FIRST miss, but the pane is gone
  reconcile_strands
  grep -q '^status: queued' "$ITEMS/str-dead.md"
  grep -q 'str-dead strand-reverted' "$CB_HOME/logs/events"
}

@test "strand janitor is MARKER-GATED: an active item intake never claimed is untouched" {
  load ../lib/queue.sh
  export CB_NOW=99999 CB_STRAND_GRACE_SECS=1
  mk_active hand-flipped                              # no marker — Kyle's own edit,
  reconcile_strands                                   # or a paused-via-adopt item
  grep -q '^status: active' "$ITEMS/hand-flipped.md"
  ! grep -q 'hand-flipped strand' "$CB_HOME/logs/events"
}

@test "strand janitor: a marker whose item is no longer active is dropped, not acted on" {
  load ../lib/queue.sh
  export CB_NOW=99999 CB_STRAND_GRACE_SECS=1
  printf -- '---\nslug: str-done\nstatus: queued\nrepo: ultron\n---\n' > "$ITEMS/str-done.md"
  mk_marker str-done 1000 1
  reconcile_strands
  grep -q '^status: queued' "$ITEMS/str-done.md"
  [ ! -f "$CB_HOME/claims/str-done" ]
  ! grep -q 'str-done strand-reverted' "$CB_HOME/logs/events"
}

@test "strand janitor: a marker pointing at a vanished item file is dropped" {
  load ../lib/queue.sh
  export CB_NOW=99999 CB_STRAND_GRACE_SECS=1
  mk_marker str-gone 1000 1                            # item archived out from under it
  reconcile_strands
  [ ! -f "$CB_HOME/claims/str-gone" ]
}

@test "strand janitor: no claims dir at all is a no-op, not an error" {
  load ../lib/queue.sh
  rm -rf "$CB_HOME/claims"
  run reconcile_strands
  [ "$status" -eq 0 ]
}

@test "strand janitor: a task dir whose slug EXTENDS the item slug is still spawn evidence" {
  # live on 2026-08-02: dev item cerebro-intake-strand-janitor ran as task
  # cerebro-intake-strand-janitor-build. Equality would have called it stranded.
  load ../lib/queue.sh
  export CB_NOW=99999 CB_STRAND_GRACE_SECS=1
  mk_active str-pfx; mk_marker str-pfx 1000 1
  mkdir -p "$CB_HOME/tasks/str-pfx-build"
  reconcile_strands
  grep -q '^status: active' "$ITEMS/str-pfx.md"
  [ ! -f "$CB_HOME/claims/str-pfx" ]
}

@test "strand janitor: a session name that extends the slug is spawn evidence" {
  load ../lib/queue.sh
  export CB_NOW=99999 CB_STRAND_GRACE_SECS=1
  export CB_SESSION_LIST_CMD="printf 'other\nstr-sfx-fix\n'"
  mk_active str-sfx; mk_marker str-sfx 1000 1
  reconcile_strands
  grep -q '^status: active' "$ITEMS/str-sfx.md"
}

@test "strand janitor: an unrelated session name is NOT taken as evidence" {
  load ../lib/queue.sh
  export CB_NOW=99999 CB_STRAND_GRACE_SECS=1
  export CB_SESSION_LIST_CMD="printf 'unrelated\nprefixed-str-neg\n'"   # slug is not at index 1
  mk_active str-neg; mk_marker str-neg 1000 1
  reconcile_strands
  grep -q '^status: queued' "$ITEMS/str-neg.md"
  grep -q 'str-neg strand-reverted' "$CB_HOME/logs/events"
}
