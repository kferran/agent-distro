#!/usr/bin/env bats
# The ops launch contract must READ the brief's `# Landing` section, not hardcode a ban.
# 2026-07-31: a blanket "NO COMMIT/PUSH" in cb-start silently overrode briefs that
# explicitly said commit-and-push, so agents did the work and stopped one step short.

setup() {
  TMP="$(mktemp -d)"; export CB_HOME="$TMP/cerebro"
  mkdir -p "$CB_HOME/tasks/t"
  export CB_TMUX_CMD="true"          # don't actually spawn
  export CB_CLAUDE_BIN="/bin/true"
}
teardown() { rm -rf "$TMP"; }

_prompt() { grep -o -- '--remote-control.*' "$CB_HOME/tasks/t/launch.sh" 2>/dev/null; }

@test "brief saying 'commit and push' yields a contract that permits pushing" {
  printf '# Landing\n\n**Commit and push to `fe/x`.**\n\n# Objective\nx\n' > "$CB_HOME/tasks/t/brief.md"
  run scripts/cerebro/cb-start --ops t
  [ -f "$CB_HOME/tasks/t/launch.sh" ]
  run _prompt
  [[ "$output" == *"YOUR BRIEF SAYS COMMIT AND PUSH"* ]]
  [[ "$output" != *"never run git commit"* ]]
}

@test "brief saying 'commit locally' permits a commit but forbids the push" {
  printf '# Landing\n\nCommit locally to the vault; do NOT push.\n\n# Objective\nx\n' > "$CB_HOME/tasks/t/brief.md"
  run scripts/cerebro/cb-start --ops t
  run _prompt
  [[ "$output" == *"COMMIT LOCALLY, DO NOT PUSH"* ]]
}

@test "a brief with no Landing section still defaults to the no-commit ban" {
  printf '# Objective\nx\n' > "$CB_HOME/tasks/t/brief.md"
  run scripts/cerebro/cb-start --ops t
  run _prompt
  [[ "$output" == *"NO COMMIT/PUSH"* ]]
}

@test "merging a PR and outward writes stay banned regardless of Landing" {
  printf '# Landing\n\n**Commit and push to `fe/x`.**\n\n# Objective\nx\n' > "$CB_HOME/tasks/t/brief.md"
  run scripts/cerebro/cb-start --ops t
  run _prompt
  [[ "$output" == *"NEVER merge a PR"* ]]
  [[ "$output" == *"NO UNAPPROVED OUTWARD WRITES"* ]]
}
