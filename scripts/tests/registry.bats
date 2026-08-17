#!/usr/bin/env bats

setup() {
  export CB_REGISTRY="$BATS_TEST_TMPDIR/projects.md"
  cat > "$CB_REGISTRY" <<'EOF'
- project: ultron
  checkout: ~/code/worktrees/main
  delivery: bitbucket-pr
- project: cerebro
  checkout: ~/vault
  delivery: research-only
EOF
  load ../lib/registry.sh
}

@test "reads checkout for a project" {
  run registry_field ultron checkout
  [ "$output" = "~/code/worktrees/main" ]
}

@test "reads delivery for a research-only system" {
  run registry_field cerebro delivery
  [ "$output" = "research-only" ]
}

@test "default CB_REGISTRY resolves to scripts/cerebro/projects.md, NOT the vault root" {
  unset CB_REGISTRY
  # cd to repo root to ensure relative path calculations work
  cd "$(git rev-parse --show-toplevel)"
  # source registry.sh fresh so its default path calc runs
  source scripts/cerebro/lib/registry.sh
  run registry_field ultron checkout
  [ "$output" = "~/code/worktrees/main" ]
  # the whole point of the 2026-07-30 move: it must NOT be the vault root, which is
  # what an Obsidian-side commit-all sweeps (took projects.md 07-30, Today.md 07-01)
  [ "$CB_REGISTRY" = "$(git rev-parse --show-toplevel)/scripts/cerebro/projects.md" ]
  [ "$CB_REGISTRY" != "$(git rev-parse --show-toplevel)/projects.md" ]
}

@test "strips trailing inline # comment from a field value" {
  export CB_REGISTRY="$BATS_TEST_TMPDIR/reg.md"
  printf -- '- project: ultron\n  workspace: porchsoftware   # git@bitbucket.org:porchsoftware/ultron.git\n  checkout: ~/code/worktrees/main\n' > "$CB_REGISTRY"
  source scripts/cerebro/lib/registry.sh
  run registry_field ultron workspace
  [ "$output" = "porchsoftware" ]
}

# --- registry_reviewers (T15): BB-payload-shaped JSON + placeholder guard ---
@test "registry_reviewers emits BB-shaped JSON" {
  export CB_REGISTRY="$BATS_TEST_TMPDIR/reg-reviewers.md"
  printf -- '- project: ultron\n  reviewers: ["a1b2", "c3d4"]\n' > "$CB_REGISTRY"
  run registry_reviewers ultron
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].uuid' <<<"$output")" = "a1b2" ]
  [ "$(jq -r '.[1].uuid' <<<"$output")" = "c3d4" ]
  [ "$(jq 'length' <<<"$output")" = "2" ]
}

@test "registry_reviewers refuses placeholders loudly" {
  export CB_REGISTRY="$BATS_TEST_TMPDIR/reg-placeholder.md"
  printf -- '- project: ultron\n  reviewers: ["{uuid-1}", "{uuid-2}"]\n' > "$CB_REGISTRY"
  run registry_reviewers ultron
  [ "$status" -ne 0 ]
  [[ "$output" == *"placeholder"* ]]
}

@test "registry_reviewers refuses a missing/empty reviewers row" {
  export CB_REGISTRY="$BATS_TEST_TMPDIR/reg-none.md"
  printf -- '- project: ultron\n  checkout: ~/code/worktrees/main\n' > "$CB_REGISTRY"
  run registry_reviewers ultron
  [ "$status" -ne 0 ]
  [[ "$output" == *"reviewers"* ]]
}

@test "registry_reviewers strips the inline # comment before parsing" {
  export CB_REGISTRY="$BATS_TEST_TMPDIR/reg-comment.md"
  printf -- '- project: ultron\n  reviewers: ["a1b2"]   # Bitbucket account UUIDs\n' > "$CB_REGISTRY"
  run registry_reviewers ultron
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].uuid' <<<"$output")" = "a1b2" ]
}

# --- T39: per-row worktree root ------------------------------------------------
# cb-start hardcoded $HOME/code/worktrees/<slug>, so a vault-delivery row
# (delivery: local-only) had its worktree created in the Ultron tree and had to be
# corrected by hand with --worktree. The root is a property of the target, so it
# belongs on the row.
@test "registry_worktree_root reads a row's worktree_root, tilde-expanded" {
  export CB_REGISTRY="$BATS_TEST_TMPDIR/reg-wt.md"
  printf -- '- project: cerebro\n  worktree_root: ~/vault/.claude/worktrees\n' > "$CB_REGISTRY"
  run registry_worktree_root cerebro
  [ "$output" = "$HOME/vault/.claude/worktrees" ]
}

@test "registry_worktree_root defaults to ~/code/worktrees when the row omits it" {
  run registry_worktree_root ultron
  [ "$output" = "$HOME/code/worktrees" ]
}

@test "registry_worktree_root strips a trailing slash (so <root>/<slug> never doubles)" {
  export CB_REGISTRY="$BATS_TEST_TMPDIR/reg-slash.md"
  printf -- '- project: cerebro\n  worktree_root: ~/vault/.claude/worktrees/\n' > "$CB_REGISTRY"
  run registry_worktree_root cerebro
  [ "$output" = "$HOME/vault/.claude/worktrees" ]
}

@test "registry_worktree_root strips an inline # comment like every other field" {
  export CB_REGISTRY="$BATS_TEST_TMPDIR/reg-wtc.md"
  printf -- '- project: cerebro\n  worktree_root: ~/vault/.claude/worktrees   # vault-local\n' > "$CB_REGISTRY"
  run registry_worktree_root cerebro
  [ "$output" = "$HOME/vault/.claude/worktrees" ]
}

@test "the shipped cerebro row resolves to the vault's .claude/worktrees" {
  unset CB_REGISTRY; load ../lib/registry.sh     # the real projects.md next to the code
  run registry_worktree_root cerebro
  [[ "$output" == *"/.claude/worktrees" ]]
  [[ "$output" != *"/code/worktrees"* ]]
}
