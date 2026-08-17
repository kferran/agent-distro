#!/usr/bin/env bats
# lib/conductor.sh (T17): run resolution + manifest field parsing over a
# fixture worktree that models the live ~150-run .ai/specs/ layout.

setup() {
  load ../lib/conductor.sh
  WT="$BATS_TEST_TMPDIR/worktree"
  mkdir -p "$WT/.ai/specs"
  # decoy-old: unrelated run, oldest
  mkdir -p "$WT/.ai/specs/decoy-old"
  printf -- '---\nname: decoy-old\njira: EJA-1\ncurrent_task: ship/complete\n---\n' > "$WT/.ai/specs/decoy-old/manifest.md"
  touch -d '30 days ago' "$WT/.ai/specs/decoy-old/manifest.md"
}

mk_run() { # mk_run <subdir> <jira> [age]
  mkdir -p "$WT/.ai/specs/$1"
  printf -- '---\nname: %s\njira: %s\ncurrent_phase: build\ncurrent_task: spec/1-knowledge-search\n---\n' "$1" "$2" > "$WT/.ai/specs/$1/manifest.md"
  [ -n "${3:-}" ] && touch -d "$3" "$WT/.ai/specs/$1/manifest.md" || true
}

@test "exact <slug> subdir wins over a newer decoy" {
  mk_run my-slug EJA-5 '2 days ago'
  mk_run decoy-newer EJA-9   # fresh mtime — must NOT win
  run resolve_run "$WT" my-slug EJA-5
  [ "$status" -eq 0 ]
  [ "$output" = "$WT/.ai/specs/my-slug" ]
}

@test "slug dir without a manifest.md does not count as the exact match" {
  mkdir -p "$WT/.ai/specs/my-slug"        # bare dir, no manifest
  mk_run jira-match EJA-5 '2 days ago'
  run resolve_run "$WT" my-slug EJA-5
  [ "$status" -eq 0 ]
  [ "$output" = "$WT/.ai/specs/jira-match" ]
}

@test "jira fallback when no slug dir" {
  mk_run some-run EJA-42 '5 days ago'
  mk_run other-run EJA-7
  run resolve_run "$WT" absent-slug EJA-42
  [ "$status" -eq 0 ]
  [ "$output" = "$WT/.ai/specs/some-run" ]
}

@test "newest-mtime last resort resolves only a run newer than the task's context.md floor" {
  # cb-brief --code wrote context.md for this task just before launch
  mkdir -p "$WT/.ai/specs/my-task"
  touch -d '1 hour ago' "$WT/.ai/specs/my-task/context.md"
  mk_run older-run EJA-1 '10 days ago'    # committed run, pre-dates the floor
  mk_run session-run EJA-2                 # fresh — post-dates the floor
  run resolve_run "$WT" my-task
  [ "$status" -eq 0 ]
  [ "$output" = "$WT/.ai/specs/session-run" ]
}

@test "newest-mtime last resort REFUSES when every run predates the context.md floor" {
  # the mispick guard: only stale committed runs exist, no session run yet
  mkdir -p "$WT/.ai/specs/my-task"
  touch "$WT/.ai/specs/my-task/context.md"      # floor = now
  mk_run committed-a EJA-1 '10 days ago'
  mk_run committed-b EJA-2 '5 days ago'
  run resolve_run "$WT" my-task
  [ "$status" -ne 0 ]
}

@test "newest-mtime last resort refuses when there's no context.md floor at all" {
  mk_run older-run EJA-1 '10 days ago'
  mk_run newest-run EJA-2
  run resolve_run "$WT" absent-slug
  [ "$status" -ne 0 ]
}

@test "scope-add-2a: jira-match respects the context.md floor — a stale same-jira prior cycle is excluded" {
  # adopted / reused same-ticket worktree: a prior cycle left a run with the SAME
  # jira, stale + in a terminal phase. The current session's fresh run must win —
  # the stale prior run must not be mis-resolved (drove eja-3600/eja-3487 flapping).
  mkdir -p "$WT/.ai/specs/my-task"
  touch -d '1 hour ago' "$WT/.ai/specs/my-task/context.md"   # this session's start marker
  mk_run prior-cycle EJA-5 '10 days ago'                     # same jira, predates the floor
  mk_run session-run EJA-5                                   # current session, fresh
  run resolve_run "$WT" my-task EJA-5
  [ "$status" -eq 0 ]
  [ "$output" = "$WT/.ai/specs/session-run" ]
}

@test "scope-add-2a: jira-match with ONLY a stale prior run + a floor refuses (no stale mispick)" {
  mkdir -p "$WT/.ai/specs/my-task"; touch "$WT/.ai/specs/my-task/context.md"   # floor = now
  mk_run prior-cycle EJA-5 '10 days ago'
  run resolve_run "$WT" my-task EJA-5
  [ "$status" -ne 0 ]
}

@test "scope-add-2a: exact slug tier also respects the floor — a stale slug-dir manifest is excluded" {
  # a prior cycle wrote its manifest into the slug dir; the current session's marker
  # post-dates it, and the real current run is elsewhere.
  mkdir -p "$WT/.ai/specs/my-task"
  printf -- '---\njira: EJA-5\ncurrent_task: ship/complete\n---\n' > "$WT/.ai/specs/my-task/manifest.md"
  touch -d '10 days ago' "$WT/.ai/specs/my-task/manifest.md"
  touch -d '1 hour ago' "$WT/.ai/specs/my-task/context.md"
  mk_run session-run EJA-5
  run resolve_run "$WT" my-task EJA-5
  [ "$status" -eq 0 ]
  [ "$output" = "$WT/.ai/specs/session-run" ]
}

@test "non-zero when no runs at all" {
  rm -rf "$WT/.ai/specs"; mkdir -p "$WT/.ai/specs"
  run resolve_run "$WT" absent-slug
  [ "$status" -ne 0 ]
}

@test "CB_SPECS_ROOT overrides the .ai/specs default" {
  mkdir -p "$WT/custom/specs/my-slug"
  printf -- '---\njira: EJA-5\n---\n' > "$WT/custom/specs/my-slug/manifest.md"
  CB_SPECS_ROOT="custom/specs" run resolve_run "$WT" my-slug
  [ "$status" -eq 0 ]
  [ "$output" = "$WT/custom/specs/my-slug" ]
}

@test "manifest_field reads a frontmatter value" {
  mk_run field-run EJA-3
  run manifest_field "$WT/.ai/specs/field-run" current_task
  [ "$output" = "spec/1-knowledge-search" ]
}

@test "manifest_field trims trailing whitespace and CR" {
  mkdir -p "$WT/.ai/specs/crlf-run"
  printf -- '---\r\ncurrent_task: build/awaiting-approval \r\n---\r\n' > "$WT/.ai/specs/crlf-run/manifest.md"
  run manifest_field "$WT/.ai/specs/crlf-run" current_task
  [ "$output" = "build/awaiting-approval" ]
}

@test "manifest_field ignores same-named keys in the body" {
  mkdir -p "$WT/.ai/specs/body-run"
  printf -- '---\njira: EJA-8\n---\ncurrent_task: not-this\n' > "$WT/.ai/specs/body-run/manifest.md"
  run manifest_field "$WT/.ai/specs/body-run" current_task
  [ -z "$output" ]
}
