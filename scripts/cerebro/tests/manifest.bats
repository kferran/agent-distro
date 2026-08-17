#!/usr/bin/env bats
# manifest.sh — the shared append-only manifest primitive (spec §2). Covers the
# milestone-1 DoD: schema + atomic append + read + dedupe (two events → one
# board line), and that nothing is lost across a busy tick (append order kept,
# concurrent writers don't interleave a partial line).

setup() {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME"
  export CB_MANIFEST="$CB_HOME/manifest.jsonl"
  load ../lib/manifest.sh
}

@test "append writes one well-formed JSON line with the exact schema" {
  manifest_append preprod ASD-1124 reopened "disclosure page reopened by Thomas Rosales"
  [ "$(wc -l < "$CB_MANIFEST")" -eq 1 ]
  run jq -e '.source=="preprod" and .key=="ASD-1124" and .state=="reopened" and (.ts|test("^2")) and (.detail|test("Thomas"))' "$CB_MANIFEST"
  [ "$status" -eq 0 ]
  # schema is EXACTLY the five fields — relay-channel reuses this primitive
  run jq -r 'keys_unsorted | join(",")' "$CB_MANIFEST"
  [ "$output" = "source,key,state,ts,detail" ]
}

@test "detail with quotes/braces/newlines can't corrupt the stream" {
  manifest_append preprod K1 note 'he said "7/20 slips" {maybe}
line two'
  [ "$(wc -l < "$CB_MANIFEST")" -eq 1 ]          # embedded newline escaped, still one line
  run jq -r '.detail' "$CB_MANIFEST"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"7/20 slips"'* ]]
}

@test "append refuses a missing required field" {
  run manifest_append preprod "" reopened "x"
  [ "$status" -eq 2 ]
}

@test "manifest_events filters by source, keeps append order" {
  manifest_append preprod A new "a"
  manifest_append exec-committee B new "b"
  manifest_append preprod C new "c"
  run manifest_events preprod
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 2 ]
  [[ "$(printf '%s\n' "$output" | head -1 | jq -r .key)" == "A" ]]   # order preserved
  [[ "$(printf '%s\n' "$output" | tail -1 | jq -r .key)" == "C" ]]
}

@test "dedupe: two events for the same key → one board line, latest state wins" {
  manifest_append preprod ASD-1124 reopened "first"
  manifest_append preprod ASD-1124 resolved "later"
  run manifest_latest_per_key preprod
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]          # ONE line for the key
  [[ "$output" == *"resolved"* ]]                          # the LATEST state
  [[ "$output" != *"reopened"* ]]
  # transitions count (last TSV field) reflects the flap without emitting 2 lines
  [ "$(printf '%s' "$output" | awk -F'\t' '{print $NF}')" -eq 2 ]
}

@test "dedupe: distinct keys stay distinct lines" {
  manifest_append preprod A new "a"
  manifest_append preprod B new "b"
  run manifest_latest_per_key preprod
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 2 ]
}

@test "nothing is lost across a busy tick: concurrent appends all land, whole" {
  # 20 parallel writers — flock guarantees each line is whole and all survive.
  for i in $(seq 1 20); do manifest_append preprod "K$i" new "detail $i" & done
  wait
  [ "$(wc -l < "$CB_MANIFEST")" -eq 20 ]
  # every line is valid JSON (no interleaved partial line)
  run bash -c "jq -e . '$CB_MANIFEST' >/dev/null"
  [ "$status" -eq 0 ]
  # all 20 distinct keys present
  [ "$(jq -r .key "$CB_MANIFEST" | sort -u | wc -l)" -eq 20 ]
}

@test "empty manifest reads clean (no file yet)" {
  run manifest_events
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run manifest_latest_per_key preprod
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
