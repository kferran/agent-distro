#!/usr/bin/env bats
# memcheck.sh — the memory-corpus health checks.
#
# The rules under test, each drawn from a defect reproduced against the live
# corpus on 2026-07-31 (see 00 Inbox/2026-07-31-memory-correction-lifecycle.md):
#   * the index budget applies to the HOOK, not the whole line
#   * a [[link]] resolves against filename OR frontmatter `name:` — and 3 real
#     entries link to targets that satisfy neither
#   * code spans and frontmatter are prose ABOUT links, not links
#   * echo detection is content (shingles), never a slug mention

setup() {
  export CB_MEM_DIR="$BATS_TEST_TMPDIR/memory"
  mkdir -p "$CB_MEM_DIR"
  source "$BATS_TEST_DIRNAME/../lib/memcheck.sh"
}

# mkentry SLUG NAME SHAPE BODY — an entry under either frontmatter shape.
mkentry() {
  local slug="$1" name="$2" shape="$3" body="$4"
  { printf -- '---\nname: %s\n' "$name"
    if [ "$shape" = nested ]; then printf 'metadata:\n  type: feedback\n'
    elif [ "$shape" = flat ]; then printf 'type: feedback\n'; fi
    printf -- '---\n\n%s\n' "$body"
  } > "$CB_MEM_DIR/$slug.md"
  printf '%s\n' "$CB_MEM_DIR/$slug.md"
}

# --- index line anatomy -----------------------------------------------------

@test "mc_index_slug pulls the target out of a conforming index line" {
  run mc_index_slug '- [Some Title](feedback_x.md) — the hook'
  [ "$output" = "feedback_x.md" ]
}

@test "mc_index_slug is empty on a line that is not an index entry" {
  run mc_index_slug '# Memory Index'
  [ -z "$output" ]
}

@test "mc_index_hook returns only the text after the em-dash separator" {
  run mc_index_hook '- [A Title](f.md) — short hook here'
  [ "$output" = "short hook here" ]
}

@test "the budget measures the HOOK, not the line — a long title does not count as bloat" {
  # Identity is not content. Two lines, same 9-char hook, wildly different titles;
  # both must measure 9, or every entry with a descriptive name reads as bloat.
  run mc_index_hook_len '- [A](f.md) — nine char'
  [ "$output" = 9 ]
  run mc_index_hook_len '- [A Very Long Descriptive Entry Title Indeed](f.md) — nine char'
  [ "$output" = 9 ]
}

@test "mc_index_hook_len is -1, not 0, when the line has no hook separator" {
  # "does not conform to the format" is a different finding from "hook is empty",
  # and collapsing them would hide malformed lines inside the compliant count.
  run mc_index_hook_len '- [A Title](f.md)'
  [ "$output" = "-1" ]
}

@test "mc_index_hook_len is -1 on a non-index line" {
  run mc_index_hook_len 'just some prose'
  [ "$output" = "-1" ]
}

# --- normalisation + shingles -----------------------------------------------

@test "mc_normalize erases markdown so formatting alone cannot hide an echo" {
  a="$(printf '**never force-push**, ever.\n' | mc_normalize)"
  b="$(printf '`never force push` ever\n'    | mc_normalize)"
  [ "$a" = "$b" ]
}

@test "mc_shingles emits overlapping n-grams" {
  out="$(printf 'a b c d\n' | mc_shingles 3)"
  [ "$(printf '%s\n' "$out" | sed -n 1p)" = "a b c" ]
  [ "$(printf '%s\n' "$out" | sed -n 2p)" = "b c d" ]
  [ "$(printf '%s\n' "$out" | wc -l)" = 2 ]
}

@test "mc_shingles emits nothing when the stream is shorter than n" {
  out="$(printf 'a b\n' | mc_shingles 6)"
  [ -z "$out" ]
}

@test "shared shingles find a rule copied into a skill despite reformatting" {
  # This is the echo test in miniature: the same rule, one bolded and one plain,
  # must overlap. A slug grep would find nothing here — and that is the point.
  entry="$(mkentry e1 e1 nested 'The **X-Man** must commit and push it to the branch.')"
  skill="$BATS_TEST_TMPDIR/SKILL.md"
  printf 'the x man must commit and push it to the branch\n' > "$skill"
  a="$(mc_normalize < "$entry" | mc_shingles 6 | sort -u)"
  b="$(mc_normalize < "$skill" | mc_shingles 6 | sort -u)"
  n="$(comm -12 <(printf '%s\n' "$a") <(printf '%s\n' "$b") | wc -l)"
  [ "$n" -ge 3 ]
}

@test "unrelated prose does not manufacture a 6-gram echo" {
  entry="$(mkentry e2 e2 nested 'Always link Jira tickets, never bare numbers.')"
  skill="$BATS_TEST_TMPDIR/OTHER.md"
  printf 'the nightly sweep writes a report into the inbox folder\n' > "$skill"
  a="$(mc_normalize < "$entry" | mc_shingles 6 | sort -u)"
  b="$(mc_normalize < "$skill" | mc_shingles 6 | sort -u)"
  n="$(comm -12 <(printf '%s\n' "$a") <(printf '%s\n' "$b") | wc -l)"
  [ "$n" = 0 ]
}

# --- frontmatter -------------------------------------------------------------

@test "mc_entry_name reads name: under both frontmatter shapes" {
  f="$(mkentry a some-name nested 'body')"; [ "$(mc_entry_name "$f")" = "some-name" ]
  g="$(mkentry b other-name flat 'body')";  [ "$(mc_entry_name "$g")" = "other-name" ]
}

@test "mc_entry_name strips surrounding quotes" {
  printf -- '---\nname: "quoted-name"\n---\n\nbody\n' > "$CB_MEM_DIR/q.md"
  [ "$(mc_entry_name "$CB_MEM_DIR/q.md")" = "quoted-name" ]
}

@test "mc_schema_shape separates the nested and legacy-flat shapes" {
  f="$(mkentry a a nested 'x')"; [ "$(mc_schema_shape "$f")" = "nested" ]
  g="$(mkentry b b flat 'x')";   [ "$(mc_schema_shape "$g")" = "flat" ]
  h="$(mkentry c c none 'x')";   [ "$(mc_schema_shape "$h")" = "none" ]
}

@test "mc_entry_type reads type: out of either shape" {
  f="$(mkentry a a nested 'x')"; [ "$(mc_entry_type "$f")" = "feedback" ]
  g="$(mkentry b b flat 'x')";   [ "$(mc_entry_type "$g")" = "feedback" ]
}

# --- links -------------------------------------------------------------------

@test "mc_links strips aliases and heading anchors" {
  f="$(mkentry a a nested 'see [[target|display]] and [[other#heading]]')"
  run mc_links "$f"
  [[ "$output" == *"target"* ]]
  [[ "$output" == *"other"* ]]
  [[ "$output" != *"display"* ]]
  [[ "$output" != *"heading"* ]]
}

@test "a [[link]] inside a code span is prose about link syntax, not a link" {
  # Three of the six "dead links" in the first live run were exactly this —
  # entries explaining that a `git mv` breaks `[[links]]`.
  f="$(mkentry a a nested 'a git mv breaks every `[[00 Inbox/name]]` pointing at it')"
  run mc_links "$f"
  [ -z "$output" ]
}

@test "a [[link]] in the frontmatter description is metadata, not a rendered link" {
  printf -- '---\nname: a\ndescription: "fix inbound [[links]] a move breaks"\n---\n\nbody\n' \
    > "$CB_MEM_DIR/a.md"
  run mc_links "$CB_MEM_DIR/a.md"
  [ -z "$output" ]
}

@test "mc_dead_links resolves against the filename OR the frontmatter name" {
  f="$(mkentry a a nested 'see [[by-filename]] and [[by-frontmatter-name]]')"
  printf 'by-filename\nby-frontmatter-name\n' > "$BATS_TEST_TMPDIR/names"
  run mc_dead_links "$f" "$BATS_TEST_TMPDIR/names"
  [ -z "$output" ]
}

@test "mc_dead_links reports the target that resolves to neither" {
  # The live instance: reference_shane_wilks_life_team links [[feedback_two_james_morris]];
  # the file is reference_two_james_morris.md with name: two-james-morris.
  f="$(mkentry a a nested 'see [[feedback_two_james_morris]]')"
  printf 'reference_two_james_morris\ntwo-james-morris\n' > "$BATS_TEST_TMPDIR/names"
  run mc_dead_links "$f" "$BATS_TEST_TMPDIR/names"
  [ "$output" = "feedback_two_james_morris" ]
}

@test "mc_dead_links succeeds on an entry with no links at all" {
  # Most entries have none; returning the failed `read` would abort a caller
  # running under `set -e` on the first such entry.
  f="$(mkentry a a nested 'no links in this body')"
  : > "$BATS_TEST_TMPDIR/names"
  run mc_dead_links "$f" "$BATS_TEST_TMPDIR/names"
  [ "$status" = 0 ]
  [ -z "$output" ]
}

# --- absolutes (the contradiction surfacer) ---------------------------------

@test "mc_absolutes catches the stale-absolute shape that beat the newer rule" {
  # feedback_push_liberally said "never push code" while the landing rule
  # required pushing. Both read as ordinary sentences; the absolute is the tell.
  f="$(mkentry a a nested 'Never push code. Commit vault changes freely.')"
  run mc_absolutes "$f"
  [[ "$output" == *"Never push code"* ]]
}

@test "mc_absolutes stays quiet on prose with no absolute" {
  f="$(mkentry a a nested 'Prefer the shorter form when the basename is unique.')"
  run mc_absolutes "$f"
  [ -z "$output" ]
}

@test "mc_subject_tokens returns the entry's distinctive nouns, not prose filler" {
  f="$(mkentry a a nested 'The dispatch brief needs a landing section. Every dispatch brief that changes code carries landing.')"
  run mc_subject_tokens "$f" 4
  [[ "$output" == *"dispatch"* ]]
  [[ "$output" != *"about"* ]]
}

# --- cb-memcheck --flags end-to-end -----------------------------------------
# The flag paths that live in the driver rather than the lib. Each is a defect
# the per-entry pass cannot see on its own.

flagsetup() {
  export VAULT_DIR="$BATS_TEST_TMPDIR/vault"
  mkdir -p "$VAULT_DIR/.claude/skills" "$VAULT_DIR/scripts"
  mkentry alpha alpha nested 'a body with no links'   > /dev/null
  mkentry beta  beta  nested 'another body'           > /dev/null
}

runflags() { CB_MEM_DIR="$CB_MEM_DIR" VAULT_DIR="$VAULT_DIR" "$BATS_TEST_DIRNAME/../cb-memcheck" --flags; }

@test "--flags is clear when every index line conforms" {
  flagsetup
  { printf '# Memory Index\n\n'
    printf -- '- [Alpha](alpha.md) — short hook\n'
    printf -- '- [Beta](beta.md) — short hook\n'; } > "$CB_MEM_DIR/MEMORY.md"
  run runflags
  [ "$status" = 0 ]
  [ "$output" = "Memory corpus: clear" ]
}

@test "--flags reports an index line with a link but no hook separator" {
  # -1 folded into the numeric budget test would compare `-1 -gt 100` and pass,
  # making a malformed line the one defect the budget check tolerates.
  flagsetup
  { printf -- '- [Alpha](alpha.md)\n'
    printf -- '- [Beta](beta.md) — short hook\n'; } > "$CB_MEM_DIR/MEMORY.md"
  run runflags
  [[ "$output" == *"alpha — index line has no hook separator"* ]]
}

@test "--flags reports a slug listed twice — the second line is otherwise invisible" {
  flagsetup
  { printf -- '- [Alpha](alpha.md) — short hook\n'
    printf -- '- [Alpha again](alpha.md) — a second hook nobody budgets\n'
    printf -- '- [Beta](beta.md) — short hook\n'; } > "$CB_MEM_DIR/MEMORY.md"
  run runflags
  [[ "$output" == *"alpha — listed more than once"* ]]
}

@test "--flags reports an entry missing from the index, and an index line pointing at nothing" {
  flagsetup
  { printf -- '- [Alpha](alpha.md) — short hook\n'
    printf -- '- [Ghost](ghost.md) — points at no file\n'; } > "$CB_MEM_DIR/MEMORY.md"
  run runflags
  [[ "$output" == *"ghost — index line points at a file that does not exist"* ]]
  [[ "$output" == *"beta — missing from MEMORY.md"* ]]
}

@test "--flags reports a hook over the budget" {
  flagsetup
  long="$(printf 'x%.0s' $(seq 1 120))"
  { printf -- '- [Alpha](alpha.md) — %s\n' "$long"
    printf -- '- [Beta](beta.md) — short hook\n'; } > "$CB_MEM_DIR/MEMORY.md"
  run runflags
  [[ "$output" == *"alpha — index hook 120c > 100"* ]]
}
