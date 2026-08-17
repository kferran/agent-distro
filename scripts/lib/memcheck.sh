# memcheck.sh — measure the health of the auto-memory corpus (`.claude/memory/`).
#
# WHY THIS EXISTS. `.claude/memory/` is loaded into context on EVERY session, so
# it is a standing context budget, not an archive. It grew 17 / 11 / 30 entries in
# May / June / July 2026 and `MEMORY.md` reached 14,952 bytes against a spec
# (CLAUDE.md § Memory) that says the index is "one line per memory, no
# frontmatter, never put memory content there." Median index line: 219 chars.
# Max: 681. That is a second copy of the corpus, and nothing measured it.
#
# WHAT IT WILL NOT DO. It never writes, moves, merges or deletes a memory entry,
# and it never edits MEMORY.md. Every output is a FLAG for a human. Deleting a
# memory is silent and unrecoverable — a wrong drop costs a real preference and
# nobody notices for weeks — so the tool's job ends at "look at this."
#
# WHY THE SKILL-OVERLAP CHECK IS SHINGLES, NOT A SLUG GREP. Slug mentions measure
# the OPPOSITE of what retirement needs. `dispatch/SKILL.md:164` cites
# `[[feedback_finishing_and_delegation_edge]]`; that citation is evidence the
# entry is load-bearing, not that it can go. What retirement needs is whether the
# entry's RULE TEXT was copied into an enforced surface — which is a content
# question. So overlap is measured as verbatim normalized 6-word shingles shared
# between the entry body and the skills/scripts corpus. A 6-gram collides by
# chance almost never, so a hit is a real textual echo. It is still only a
# CANDIDATE signal: the shingle says the words are in both places, never that the
# chokepoint actually fires for every session that needs the rule. That judgment
# is in the report, not here.
#
# WHY THE CONTRADICTION CHECK IS A SURFACER AND SAYS SO. Semantic contradiction
# is not grep-able. `feedback_push_liberally` said "never push code" while
# `feedback_dispatch_landing_step` requires pushing — both true-looking sentences,
# opposite instructions, and no lexical marker distinguishes them from two rules
# that merely share a verb. What IS mechanical: absolutes (`never`, `always`,
# `do NOT`) that share a subject noun. So this emits candidate PAIRS for a human
# to read. Calling that a contradiction detector would be a lie about its power.
#
# All functions are pure filters over stdin/args so the bats suite can drive them
# without a vault.

# --- index line anatomy -----------------------------------------------------
# An index line is `- [Title](slug.md) — hook`. The title+link is IDENTITY (its
# length is set by the entry's name, not by how much content got smuggled in);
# the hook is the part the spec constrains. So the budget is measured on the hook
# alone — otherwise a long-but-honest title reads as bloat and a terse title
# buys room for a paragraph.
: "${CB_MEM_HOOK_MAX:=100}"

# mc_index_slug LINE — the .md target inside (...), empty if not an index line.
mc_index_slug() {
  printf '%s\n' "$1" | sed -n 's/^- \[[^]]*\](\([^)]*\.md\)).*/\1/p'
}

# mc_index_hook LINE — the text after the first em-dash separator, empty if none.
# Uses the em-dash literally: every conforming line in the corpus uses ` — `, and
# matching a plain hyphen would eat hyphenated words inside a title.
mc_index_hook() {
  printf '%s\n' "$1" | sed -n 's/^- \[[^]]*\]([^)]*)[[:space:]]*—[[:space:]]*//p'
}

# mc_index_hook_len LINE — hook length in characters, or -1 when the line is not
# a parseable index entry (no link, or no hook separator). -1 is not 0: "this
# line does not conform" is a different finding from "this hook is empty".
mc_index_hook_len() {
  local line="$1" slug hook
  slug="$(mc_index_slug "$line")"
  [ -n "$slug" ] || { printf '%s\n' -1; return; }
  hook="$(mc_index_hook "$line")"
  [ -n "$hook" ] || { printf '%s\n' -1; return; }
  printf '%s\n' "${#hook}"
}

# --- text normalisation + shingles ------------------------------------------

# mc_normalize — stdin to one lowercase alphanumeric token stream. Markdown
# punctuation, backticks, links and line breaks all collapse to spaces, so
# `**never force-push**` and `never force push` normalise identically. Without
# that, formatting differences alone would hide every real echo.
mc_normalize() {
  tr 'A-Z' 'a-z' | tr -c 'a-z0-9' ' ' | tr -s ' '
  printf '\n'
}

# mc_shingles [N] — N-word shingles, one per line, from a normalized stream.
mc_shingles() {
  local n="${1:-6}"
  awk -v n="$n" '{ for (i = 1; i + n - 1 <= NF; i++) { s = $i; for (j = 1; j < n; j++) s = s " " $(i + j); print s } }'
}

# --- frontmatter ------------------------------------------------------------

# mc_entry_name FILE — the `name:` value, quotes stripped. This is what a
# `[[link]]` resolves against per CLAUDE.md, and it drifts from the filename
# constantly, which is exactly how dead links get written.
mc_entry_name() {
  sed -n '/^---$/,/^---$/{ s/^[[:space:]]*name:[[:space:]]*//p }' "$1" \
    | head -1 | sed 's/^"\(.*\)"$/\1/; s/^'"'"'\(.*\)'"'"'$/\1/'
}

# mc_schema_shape FILE — `nested` (metadata: → type:), `flat` (top-level type:),
# or `none`. Two shapes coexist in the corpus; a reader written for one silently
# reads no type from the other.
mc_schema_shape() {
  local f="$1"
  if sed -n '/^---$/,/^---$/p' "$f" | grep -q '^metadata:'; then
    printf 'nested\n'
  elif sed -n '/^---$/,/^---$/p' "$f" | grep -q '^type:'; then
    printf 'flat\n'
  else
    printf 'none\n'
  fi
}

# mc_entry_type FILE — the declared type under either schema shape.
mc_entry_type() {
  sed -n '/^---$/,/^---$/{ s/^[[:space:]]*type:[[:space:]]*//p }' "$1" | head -1
}

# --- links ------------------------------------------------------------------

# mc_links FILE — every [[target]], alias and heading anchor stripped.
# Code spans are stripped first: `[[wiki links]]` inside backticks is prose ABOUT
# link syntax, and three of the six "dead links" in the first live run were that.
mc_links() {
  sed '1{/^---$/!b}; 1,/^---$/d' "$1" \
    | sed 's/`[^`]*`//g' \
    | grep -o '\[\[[^]]*\]\]' 2>/dev/null \
    | sed 's/^\[\[//; s/\]\]$//; s/|.*$//; s/#.*$//' \
    | sed 's/[[:space:]]*$//' \
    | grep -v '[<>]' \
    | sort -u
  # `[[00 Inbox/<name>]]` and friends are prose showing the SHAPE of a link, not
  # a link. Angle brackets are the only reliable marker of that, and reporting
  # them as dead trains a reader to skim the dead-link list.
  return 0
}

# mc_dead_links FILE NAMESFILE — the targets in FILE that resolve to nothing.
# NAMESFILE is the caller's universe of resolvable names, one per line: memory
# filenames, memory `name:` values, and vault paths + basenames. Resolution is
# exact-match; Obsidian is case-insensitive on some platforms, so compare folded.
mc_dead_links() {
  local f="$1" names="$2" t
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    grep -qixF -- "$t" "$names" || printf '%s\n' "$t"
  done < <(mc_links "$f")
  # An entry with no links at all leaves `read` as the loop's exit status (1).
  # Under the caller's `set -e` that aborts the scan on the first link-free
  # entry, which is most of them — so the success is stated explicitly.
  return 0
}

# --- absolutes (the contradiction SURFACER, not a detector) -----------------

# mc_absolutes FILE — normalized sentences carrying an absolute. A rule stated as
# an absolute is the one that wins silently when it is stale, which is why these
# and not all sentences: `feedback_push_liberally`'s "never push code" beat the
# newer landing rule for as long as it stood.
mc_absolutes() {
  tr '\n' ' ' < "$1" \
    | sed 's/\([.!?]\)[[:space:]]/\1\n/g' \
    | grep -iE '(^|[^a-z])(never|always|do not|don'"'"'t|must not|no longer|categorically)([^a-z]|$)' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -v '^$'
}

# mc_subject_tokens FILE — the distinctive nouns an entry is ABOUT, used to pair
# absolutes across entries. Frequency-ranked words of 5+ chars from the body,
# minus a stoplist of prose filler. Crude on purpose: this feeds a human-reviewed
# candidate list, and a pair that turns out unrelated costs one line of reading.
mc_subject_tokens() {
  local top="${2:-6}"
  mc_normalize < "$1" | tr ' ' '\n' \
    | grep -E '^[a-z]{5,}$' \
    | grep -vwE 'about|after|apply|because|before|being|below|between|change|claude|could|every|first|going|instead|itself|kyle|later|means|might|never|other|rather|really|right|should|since|still|their|there|these|thing|those|through|until|value|which|while|whole|would|write|wrote|entry|memory' \
    | sort | uniq -c | sort -rn | head -"$top" | awk '{print $2}'
}
