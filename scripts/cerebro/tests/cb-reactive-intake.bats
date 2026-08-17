#!/usr/bin/env bats
# cb-reactive-intake — the reactive EJA-mirror watcher. Bash owns the poll
# window, the high-water state, the three gates, and the dev-item emit; the MCP
# reads are LLM work, so everything below is testable without Jira.
#
# The three gates each get their own test, plus the "it cannot dispatch" proof.

setup() {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/logs"
  export CB_VAULT="$BATS_TEST_TMPDIR/vault"
  ITEMS="$CB_VAULT/00 Inbox"
  ARCHIVE="$CB_VAULT/02 Areas/development/archive/items"
  mkdir -p "$ITEMS" "$ARCHIVE"
  export CB_RI_STATE="$CB_HOME/reactive-intake"
  export CB_RI_TZ=UTC                              # deterministic datetime literals
  KYLE=5cc081d23f65fd0e7ecefb82
  RI=scripts/cerebro/cb-reactive-intake
}

# a minimal existing dev item whose key appears only in the FILENAME and the body
# prose — the asd-445.md shape. Body prose stopped counting as a declaration at
# 8083b310, so reach for this when the filename is what's under test, or when you
# want a bystander that must NOT hold.
mk_item() { printf -- '---\nslug: %s\nstatus: active\n---\n\n# %s\n\n%s\n' "$1" "$1" "${2:-}" > "$ITEMS/$1.md"; }

# a dev item that DECLARES the keys it tracks, where dev items actually declare
# them: the frontmatter `tickets:` line. `jira:` works the same way.
mk_item_tracking() { # mk_item_tracking <slug> <comma-separated keys>
  printf -- '---\nslug: %s\nstatus: active\ntickets: [%s]\n---\n\n# %s\n' "$1" "$2" "$1" > "$ITEMS/$1.md"
}

offer_ok() { # offer_ok <extra flags...> — a clean, fully-derivable new mirror
  run $RI offer --eja EJA-9001 --asd ASD-9001 --priority High \
    --summary "Product list not refreshed after premium change" \
    --assignee "" --trigger new "$@"
}

# ---------------------------------------------------------------- happy path -

@test "new mirror with an ASD link emits a queued item: both keys, severity, domain" {
  offer_ok
  [ "$status" -eq 0 ]
  f="$(cut -d' ' -f2- <<<"$output")"
  grep -qx 'status: queued'                  "$f"
  grep -qx 'tickets: \[EJA-9001, ASD-9001\]' "$f"   # BOTH keys, not just the EJA
  grep -qx 'severity: High'                  "$f"   # mapped from Jira priority
  grep -qx 'domain: products'                "$f"   # routed to the platform domain layer
  grep -qx 'jira: EJA-9001'                  "$f"
  grep -qx 'repo: ultron'                    "$f"
  grep -qx 'task_type: code'                 "$f"
}

@test "reopened mirror emits too, and says the bounce is the spec" {
  run $RI offer --eja EJA-9002 --asd ASD-9002 --priority Blocker \
    --summary "Beneficiary allocation rejected on resubmit" --assignee "" --trigger reopened
  [ "$status" -eq 0 ]
  f="$(cut -d' ' -f2- <<<"$output")"
  grep -qx 'status: queued'    "$f"
  grep -qx 'severity: Blocker' "$f"
  grep -qx 'domain: ownership' "$f"
  grep -q  'Reopened EJA mirror' "$f"
}

@test "priority maps Blocker/High/Medium/Low onto severity" {
  n=0
  for pair in "Blocker Blocker" "High High" "Medium Medium" "Low Low" "Highest Blocker" "Lowest Low"; do
    set -- $pair; n=$(( n + 1 ))
    run $RI offer --eja "EJA-91$n" --asd "ASD-91$n" --priority "$1" \
      --summary "Product eligibility wrong" --assignee "" --trigger new
    [ "$status" -eq 0 ]
    grep -qx "severity: $2" "$(cut -d' ' -f2- <<<"$output")"
  done
}

# ------------------------------------------------------------- GATE: DEDUP --

@test "GATE dedup: holds when the ASD key is tracked under an ASD-slugged item (the ASD-1144 case)" {
  mk_item bugpush-asd-1144-product-list-message
  run $RI offer --eja EJA-3872 --asd ASD-1144 --priority Medium \
    --summary "Product list stale after back-nav" --assignee "" --trigger new
  [ "$status" -eq 3 ]
  [[ "$output" == *"HOLD dedup"* ]]
  [[ "$output" == *"ASD-1144"* ]]
  [ -z "$(ls "$ITEMS" | grep -i eja-3872 || true)" ]   # nothing emitted
}

@test "GATE dedup: matches a key living ONLY in the filename (asd-445.md shape)" {
  mk_item asd-445 "some body with no key in it"
  run $RI dedup ASD-445; [ "$status" -eq 1 ]
}

# INVERTED 2026-08-16. This test asserted the opposite until today, and 8083b310
# (2026-08-07) deliberately made the opposite wrong: a body mention is not a
# declaration, and treating it as one held EJA-3599 — four ASD rows, the
# highest-payoff item in the T&L sweep — because its key appeared as prose in three
# unrelated items, plus ASD-1247 on `ticket-note-dedup-index.md`, an index that
# lists seven keys and tracks none. A held item is never queued and nothing reports
# it, so the old assertion pinned a failure that ran in the invisible direction.
@test "GATE dedup: a key living ONLY in the body prose does NOT hold (8083b310)" {
  mk_item odd-slug-name "This supersedes ASD-903 per the 7/23 triage."
  run $RI dedup ASD-903; [ "$status" -eq 0 ]
}

@test "GATE dedup: scans the ARCHIVE too" {
  printf -- '---\nslug: old\ntickets: [EJA-1000, ASD-2000]\n---\n\nbody prose\n' > "$ARCHIVE/old.md"
  run $RI dedup ASD-2000; [ "$status" -eq 1 ]
  run $RI offer --eja EJA-9500 --asd ASD-2000 --priority High \
    --summary "Form stamping wrong" --assignee "" --trigger new
  [ "$status" -eq 3 ]
}

@test "GATE dedup: does not over-reach across key boundaries (ASD-114 ≠ ASD-1144)" {
  mk_item bugpush-asd-1144-product-list-message
  run $RI dedup ASD-114; [ "$status" -eq 0 ]        # clean — 1144 must not match 114
  run $RI dedup ASD-1144; [ "$status" -eq 1 ]
}

@test "GATE dedup: two EJA mirrors on one ASD → the second is SURFACED as a sibling, not silently dropped" {
  mk_item_tracking eja-3953-thing "EJA-3953, ASD-1100"
  run $RI offer --eja EJA-3949 --asd ASD-1100 --priority Medium \
    --summary "Product list wrong" --assignee "" --trigger new
  [ "$status" -eq 3 ]
  [[ "$output" == *"SIBLING MIRROR"* ]]
  [[ "$output" == *"EJA-3949 itself is untracked"* ]]
}

@test "GATE dedup: a hit on EITHER key holds — the EJA alone is not enough" {
  mk_item_tracking some-item "EJA-7777"
  run $RI offer --eja EJA-7777 --asd ASD-8888 --priority High \
    --summary "Owner dropdown blank" --assignee "" --trigger new
  [ "$status" -eq 3 ]
}

# ---------------------------------------------------------- GATE: ASSIGNEE --

@test "GATE live-assignee: a real engineer on the EJA MIRROR holds, and emits nothing" {
  run $RI offer --eja EJA-9310 --asd ASD-9310 --priority Blocker \
    --summary "Product page crash" --assignee 1111aaaa2222bbbb3333cccc \
    --assignee-name "Corey Sanders" --trigger new
  [ "$status" -eq 4 ]
  [[ "$output" == *"HOLD live-assignee"* ]]
  [[ "$output" == *"Corey Sanders"* ]]
  [[ "$output" == *"ASD untouched"* ]]
  [ -z "$(ls "$ITEMS")" ]
}

@test "GATE live-assignee: unassigned passes, Kyle passes" {
  run $RI offer --eja EJA-9320 --asd ASD-9320 --priority High \
    --summary "Trust owner validation" --assignee "" --trigger new
  [ "$status" -eq 0 ]
  run $RI offer --eja EJA-9321 --asd ASD-9321 --priority High \
    --summary "Trust owner validation two" --assignee "$KYLE" --trigger new
  [ "$status" -eq 0 ]
}

@test "GATE live-assignee: an OMITTED --assignee is a usage error, never 'unassigned'" {
  run $RI offer --eja EJA-9330 --asd ASD-9330 --priority High --summary "Something" --trigger new
  [ "$status" -eq 2 ]                     # fails CLOSED — a forgotten flag must not pass the gate
  [[ "$output" == *"must not fail open"* ]]
  [ -z "$(ls "$ITEMS")" ]
}

@test "GATE live-assignee: the script has no way to express an ASD assignee at all" {
  run $RI offer --eja EJA-9340 --asd ASD-9340 --priority High --summary "x" \
    --assignee "" --asd-assignee somebody --trigger new
  [ "$status" -eq 2 ]                     # unknown flag — the ASD's assignee is unreachable by design
  # …and no CODE line (comments stripped) mentions an ASD assignee at all.
  ! sed 's/#.*//' scripts/cerebro/cb-reactive-intake | grep -qi 'asd.assignee'
}

# -------------------------------------------------------------- GATE: SPEC --

@test "GATE spec: an unroutable domain holds at drafting with the question, never queued" {
  run $RI offer --eja EJA-9400 --asd ASD-9400 --priority High \
    --summary "Miscellaneous unclassifiable widget glitch" --assignee "" --trigger new
  [ "$status" -eq 0 ]
  f="$(cut -d' ' -f2- <<<"$output")"
  grep -qx 'status: drafting' "$f"
  ! grep -qx 'status: queued' "$f"
  grep -q  '## Open questions' "$f"
  grep -q  'domain could not be routed' "$f"
}

@test "GATE spec: an unmappable priority and a missing ASD link both hold at drafting" {
  run $RI offer --eja EJA-9410 --priority "" --summary "Product term filter wrong" --assignee "" --trigger new
  [ "$status" -eq 0 ]
  f="$(cut -d' ' -f2- <<<"$output")"
  grep -qx 'status: drafting' "$f"
  grep -q 'does not map to a severity' "$f"
  grep -q 'no linked ASD key' "$f"
  grep -qx 'tickets: \[EJA-9410\]' "$f"
}

@test "GATE spec: --needs-scoping forces drafting even when everything else derives" {
  run $RI offer --eja EJA-9420 --asd ASD-9420 --priority High \
    --summary "Product list wrong" --assignee "" --trigger new \
    --needs-scoping --note "AC names a product code the ticket never gives"
  [ "$status" -eq 0 ]
  f="$(cut -d' ' -f2- <<<"$output")"
  grep -qx 'status: drafting' "$f"
  grep -q 'product code the ticket never gives' "$f"
}

@test "GATE spec: NEVER queued + hold:, and never queued with open questions" {
  for pri in High "" Bogus; do
    for sum in "Product list wrong" "Unclassifiable thing"; do
      rm -f "$ITEMS"/*.md
      run $RI offer --eja EJA-9500 --asd ASD-9500 --priority "$pri" --summary "$sum" \
        --assignee "" --trigger new
      [ "$status" -eq 0 ]
      f="$(cut -d' ' -f2- <<<"$output")"
      if grep -qx 'status: queued' "$f"; then
        ! grep -q '^hold:' "$f"              # cb-intake does not read hold: — it must never coexist
        ! grep -q '## Open questions' "$f"
      fi
    done
  done
}

# ------------------------------------------------- "it cannot dispatch" (DoD 5)

@test "PROOF: the script cannot dispatch, transition, assign, or comment" {
  # No tmux, no dispatch-request, no network, no Jira write verb anywhere in it.
  ! grep -qiE 'tmux|send-keys|dispatch-request'            scripts/cerebro/cb-reactive-intake
  ! grep -qiE 'curl|wget|nc |ssh |/dev/tcp'                scripts/cerebro/cb-reactive-intake
  ! grep -qiE 'transition|addComment|editJiraIssue|assignee=|--assign ' scripts/cerebro/cb-reactive-intake
  ! grep -qiE 'cb-start|cb-send|cb-intake'                 scripts/cerebro/cb-reactive-intake
  ! grep -qiE 'git (commit|push)'                          scripts/cerebro/cb-reactive-intake
}

@test "PROOF: a successful offer's ONLY filesystem mutation in the vault is the new item" {
  mk_item unrelated-neighbour "nothing to do with this"      # a bystander that must survive untouched
  find "$CB_VAULT" -type f | sort > "$BATS_TEST_TMPDIR/before"
  offer_ok
  [ "$status" -eq 0 ]
  find "$CB_VAULT" -type f | sort > "$BATS_TEST_TMPDIR/after"
  [ "$(comm -13 "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after" | wc -l)" -eq 1 ]  # exactly one new file
  [ "$(comm -23 "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after" | wc -l)" -eq 0 ]  # nothing removed/renamed
  grep -q 'nothing to do with this' "$ITEMS/unrelated-neighbour.md"                     # bystander unmodified
}

@test "PROOF: a held offer writes NOTHING into the vault" {
  mk_item bugpush-asd-1144-product-list-message
  before="$(find "$CB_VAULT" -type f | sort)"
  run $RI offer --eja EJA-3872 --asd ASD-1144 --priority Medium --summary "x" --assignee "" --trigger new
  [ "$status" -eq 3 ]
  [ "$(find "$CB_VAULT" -type f | sort)" = "$before" ]
}

# -------------------------------------------- the cb-intake contract (DoD 1) -
# The emitted shape is only worth anything if the CONSUMER accepts it. This is
# the actual seam between the two scripts — a frontmatter field-name or ordering
# change would otherwise break the handoff silently. Setup mirrors cb-intake.bats.

@test "CONTRACT: an emitted queued item is claimed and dispatched by cb-intake --tick" {
  export CB_REGISTRY="$BATS_TEST_TMPDIR/projects.md"
  printf -- '- project: ultron\n  repo: ultron\n  base: main\n  checkout: %s\n  delivery: bitbucket-pr\n' \
    "$BATS_TEST_TMPDIR" > "$CB_REGISTRY"
  printf 'MemAvailable:   33554432 kB\n' > "$BATS_TEST_TMPDIR/meminfo"
  export CB_FREE_CMD="cat '$BATS_TEST_TMPDIR/meminfo'"
  export CB_SESSION_LIST_CMD="printf ''" CB_WINDOW_LIST_CMD="printf ''" CB_SEND_DELAY=0
  export CB_TMUX_BIN="$BATS_TEST_TMPDIR/faketmux" CB_TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"
  printf '#!/usr/bin/env bash\necho "tmux $*" >> "$CB_TMUX_LOG"\n' > "$CB_TMUX_BIN"; chmod +x "$CB_TMUX_BIN"
  mkdir -p "$CB_VAULT/00 Inbox"

  offer_ok
  [ "$status" -eq 0 ]
  slug="$(basename "$(cut -d' ' -f2- <<<"$output")" .md)"

  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -qx 'status: active' "$ITEMS/$slug.md"          # cb-intake parsed our frontmatter and flipped it
  grep -q "dispatch-request $slug" "$CB_TMUX_LOG"      # …and asked the coordinator to dispatch it
}

@test "CONTRACT: an emitted DRAFTING item is NOT claimed by cb-intake --tick" {
  export CB_REGISTRY="$BATS_TEST_TMPDIR/projects.md"
  printf -- '- project: ultron\n  repo: ultron\n  base: main\n  checkout: %s\n  delivery: bitbucket-pr\n' \
    "$BATS_TEST_TMPDIR" > "$CB_REGISTRY"
  printf 'MemAvailable:   33554432 kB\n' > "$BATS_TEST_TMPDIR/meminfo"
  export CB_FREE_CMD="cat '$BATS_TEST_TMPDIR/meminfo'"
  export CB_SESSION_LIST_CMD="printf ''" CB_WINDOW_LIST_CMD="printf ''" CB_SEND_DELAY=0
  export CB_TMUX_BIN="$BATS_TEST_TMPDIR/faketmux" CB_TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"
  printf '#!/usr/bin/env bash\necho "tmux $*" >> "$CB_TMUX_LOG"\n' > "$CB_TMUX_BIN"; chmod +x "$CB_TMUX_BIN"
  mkdir -p "$CB_VAULT/00 Inbox"

  run $RI offer --eja EJA-9600 --asd ASD-9600 --priority High \
    --summary "Unclassifiable widget glitch" --assignee "" --trigger new   # unroutable domain → drafting
  [ "$status" -eq 0 ]
  slug="$(basename "$(cut -d' ' -f2- <<<"$output")" .md)"
  grep -qx 'status: drafting' "$ITEMS/$slug.md"

  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -qx 'status: drafting' "$ITEMS/$slug.md"        # untouched — the spec gate actually holds
  [ ! -s "$CB_TMUX_LOG" ] || ! grep -q "dispatch-request $slug" "$CB_TMUX_LOG"
}

# ------------------------------------------------------- window + failure ----

@test "the poll window is absolute and overlaps the last success (no relative -15m gap)" {
  export CB_NOW=1000000000
  run $RI --seed 999999000; [ "$status" -eq 0 ]
  run $RI window; [ "$status" -eq 0 ]
  since="$(cut -f1 <<<"$output")"; until="$(cut -f2 <<<"$output")"
  [ "$since" = "$(TZ=UTC date -d @999998700 '+%Y/%m/%d %H:%M')" ]   # 999999000 - 300s lookback
  [ "$until" = "$(TZ=UTC date -d @1000000000 '+%Y/%m/%d %H:%M')" ]
}

@test "--tick is silent before the interval and prints the window after it" {
  export CB_NOW=1000000000
  $RI --seed 1000000000
  CB_NOW=1000000600 run $RI --tick             # 10 min < 15 min interval
  [ "$status" -eq 0 ]; [ -z "$output" ]
  CB_NOW=1000001000 run $RI --tick             # 16.7 min ≥ interval
  [ "$status" -eq 0 ]; [ -n "$output" ]
}

@test "a failed poll does NOT advance the high-water — the next poll re-covers the window" {
  export CB_NOW=1000000000
  $RI --seed 999999000
  run $RI record-failure "jira unreachable"; [ "$status" -eq 0 ]
  [ "$(cat "$CB_RI_STATE/last_success")" = 999999000 ]
  [ "$(cat "$CB_RI_STATE/failures")" = 1 ]
  $RI mark-polled 1000000000
  [ "$(cat "$CB_RI_STATE/last_success")" = 1000000000 ]
  [ "$(cat "$CB_RI_STATE/failures")" = 0 ]     # a good poll clears the streak
}

@test "--tick screams on stderr once the watcher has been blind for the alert threshold" {
  export CB_NOW=1000000000
  $RI --seed 999999000
  for _ in 1 2 3 4; do $RI record-failure "jira 503" >/dev/null; done
  run $RI --tick 2>&1
  [[ "$output" == *"BLIND"* ]]
}

@test "forward-only: an unseeded watcher looks back one interval, never the whole backlog" {
  export CB_NOW=1000000000
  run $RI window; [ "$status" -eq 0 ]
  [ "$(cut -f1 <<<"$output")" = "$(TZ=UTC date -d @999998800 '+%Y/%m/%d %H:%M')" ]  # now - 900 - 300
}
