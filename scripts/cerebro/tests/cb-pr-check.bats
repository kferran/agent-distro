#!/usr/bin/env bats
# cb-pr-check (T22): resolve run → parse 04-ship.md (both live shapes,
# Evidence 6) → verify branch pushed → derive summary.md → REST create_pr →
# arm the poll (pr + pr.state files).

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks" "$CB_HOME/logs"
  export CB_REGISTRY="$BATS_TEST_TMPDIR/projects.md"
  printf -- '- project: ultron\n  workspace: porchsoftware\n  repo: ultron\n  base: main\n  branch_prefix: fe/\n  checkout: %s\n  delivery: bitbucket-pr\n  reviewers: ["a1b2", "c3d4"]\n' "$BATS_TEST_TMPDIR" > "$CB_REGISTRY"
  export BB_EMAIL="a@b" BB_API_TOKEN="tok"
  # curl mock (adapter is real; only curl is mocked)
  export MOCK_DIR="$BATS_TEST_TMPDIR/mock"; mkdir -p "$MOCK_DIR"
  cat > "$MOCK_DIR/curlmock" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_DIR/argv"
cat > "$MOCK_DIR/stdin"
for a in "$@"; do case "$a" in @*) cp "${a#@}" "$MOCK_DIR/payload";; esac; done
cat "$MOCK_DIR/response"
EOF
  chmod +x "$MOCK_DIR/curlmock"
  export CB_CURL_CMD="$MOCK_DIR/curlmock"
  printf '{"id":42,"state":"OPEN","links":{"html":{"href":"https://bb/pr/42"}}}\n201' > "$MOCK_DIR/response"
  # git mock: ls-remote reports the branch as pushed by default
  export GITMOCK_LOG="$BATS_TEST_TMPDIR/git.log"
  export GITMOCK_LSREMOTE="$BATS_TEST_TMPDIR/lsremote"
  printf 'abc\trefs/heads/whatever\n' > "$GITMOCK_LSREMOTE"
  cat > "$BATS_TEST_TMPDIR/gitmock" <<'EOF'
#!/usr/bin/env bash
echo "GIT $*" >> "$GITMOCK_LOG"
case "$*" in *"ls-remote"*) [ -f "${GITMOCK_LSREMOTE:-}" ] && cat "$GITMOCK_LSREMOTE";; esac
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/gitmock"
  export CB_GIT_CMD="$BATS_TEST_TMPDIR/gitmock"
  FIX="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/04-ship"
}

mk_task() { # mk_task <slug> <shape-file> [jira]
  local slug="$1" shape="$2" jira="${3:-EJA-501}"
  WT="$BATS_TEST_TMPDIR/wt-$slug"; mkdir -p "$WT/.ai/specs/$slug"
  mkdir -p "$CB_HOME/tasks/$slug"
  printf 'kind=code\nworktree=%s\njira=%s\nsession=%s\ntarget=ultron\n' "$WT" "$jira" "$slug" > "$CB_HOME/tasks/$slug/meta"
  cp "$FIX/$shape" "$WT/.ai/specs/$slug/manifest-sibling-04-ship" # (unused decoy)
  cp "$FIX/$shape" "$WT/.ai/specs/$slug/04-ship.md"
  printf -- '---\nname: %s\njira: %s\ncurrent_task: ship/complete\n---\n' "$slug" "$jira" > "$WT/.ai/specs/$slug/manifest.md"
}

@test "shape-A: summary.md carries the body, adapter receives the frontmatter branch" {
  mk_task fix-a shape-a.md EJA-501
  run scripts/cerebro/cb-pr-check fix-a
  [ "$status" -eq 0 ]
  [ -f "$CB_HOME/tasks/fix-a/summary.md" ]
  grep -q 'shape-A distinctive body line' "$CB_HOME/tasks/fix-a/summary.md"
  grep -q "source:.*04-ship.md" "$CB_HOME/tasks/fix-a/summary.md"
  run jq -r '.source.branch.name' "$MOCK_DIR/payload"; [ "$output" = "fe/fix-a" ]
  run jq -r '.destination.branch.name' "$MOCK_DIR/payload"; [ "$output" = "main" ]
  run jq -r '.title' "$MOCK_DIR/payload"; [[ "$output" == *"EJA-501"* ]]
  run jq -r '.reviewers[0].uuid' "$MOCK_DIR/payload"; [ "$output" = "a1b2" ]
  # poll armed
  grep -q '42 https://bb/pr/42' "$CB_HOME/tasks/fix-a/pr"
  [ "$(cat "$CB_HOME/tasks/fix-a/pr.state")" = "OPEN" ]
}

@test "shape-B: title from the Title bullet, description from the fenced block" {
  mk_task fix-b shape-b.md EJA-502
  run scripts/cerebro/cb-pr-check fix-b
  [ "$status" -eq 0 ]
  run jq -r '.title' "$MOCK_DIR/payload"; [ "$output" = "EJA-502: Fix the fix-b thing" ]
  run jq -r '.source.branch.name' "$MOCK_DIR/payload"; [ "$output" = "fe/fix-b" ]
  run jq -r '.description' "$MOCK_DIR/payload"
  [[ "$output" == *"shape-B distinctive description line"* ]]
  # description is the fenced block content, not the whole ship record
  [[ "$output" != *"What shipped"* ]]
  grep -q 'shape-B distinctive description line' "$CB_HOME/tasks/fix-b/summary.md"
}

@test "unpushed branch refuses (create_pr precondition)" {
  mk_task fix-c shape-a.md
  rm -f "$GITMOCK_LSREMOTE"    # ls-remote now returns empty -> not pushed
  run scripts/cerebro/cb-pr-check fix-c
  [ "$status" -ne 0 ]
  [[ "$output" == *"push"* ]]
  [ ! -f "$CB_HOME/tasks/fix-c/pr" ]
}

@test "second invocation with an existing pr file is a no-op (idempotent)" {
  mk_task fix-d shape-a.md
  run scripts/cerebro/cb-pr-check fix-d
  [ "$status" -eq 0 ]
  rm -f "$MOCK_DIR/payload"
  run scripts/cerebro/cb-pr-check fix-d
  [ "$status" -eq 0 ]
  [[ "$output" == *"already"* ]]
  [ ! -f "$MOCK_DIR/payload" ]   # no second create call
}

@test "no reviewers row → create succeeds with the field omitted (repo defaults)" {
  printf -- '- project: ultron\n  workspace: porchsoftware\n  repo: ultron\n  base: main\n  checkout: %s\n  delivery: bitbucket-pr\n' "$BATS_TEST_TMPDIR" > "$CB_REGISTRY"
  mk_task fix-def shape-a.md
  run scripts/cerebro/cb-pr-check fix-def
  [ "$status" -eq 0 ]
  run jq 'has("reviewers")' "$MOCK_DIR/payload"; [ "$output" = "false" ]
  grep -q '42 https://bb/pr/42' "$CB_HOME/tasks/fix-def/pr"
}

@test "placeholder reviewers refuse before any create call" {
  printf -- '- project: ultron\n  workspace: porchsoftware\n  repo: ultron\n  base: main\n  checkout: %s\n  delivery: bitbucket-pr\n  reviewers: ["{uuid-1}"]\n' "$BATS_TEST_TMPDIR" > "$CB_REGISTRY"
  mk_task fix-e shape-a.md
  run scripts/cerebro/cb-pr-check fix-e
  [ "$status" -ne 0 ]
  [[ "$output" == *"placeholder"* ]]
  [ ! -f "$MOCK_DIR/payload" ]
}

@test "adapter 401 (exit 3) propagates as an escalate event line" {
  mk_task fix-f shape-a.md
  printf 'x\n401' > "$MOCK_DIR/response"
  run scripts/cerebro/cb-pr-check fix-f
  [ "$status" -eq 3 ]
  grep -q 'fix-f escalate' "$CB_HOME/logs/events"
}
