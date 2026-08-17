setup() {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks/eja-live" "$CB_HOME/tasks/eja-dead"
  # inject a fake tmux lister: only eja-live has a window (bare slug — windows
  # live in the dedicated "cb" session, named by slug, not "cb:<slug>")
  export CB_WINDOW_LIST_CMD="printf 'eja-live\n'"
  # hermetic: never read the real vault's dev items (or real tmux sessions)
  export CB_VAULT="$BATS_TEST_TMPDIR/no-vault"
  export CB_SESSION_LIST_CMD="printf ''"
}
@test "adopt marks task with a window active and without stale" {
  run scripts/cerebro/cb-adopt
  [[ "$output" == *"active eja-live"* ]]
  [[ "$output" == *"stale eja-dead"* ]]
}

@test "window with no task dir → orphaned" {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro-orphan"; mkdir -p "$CB_HOME/tasks/eja-live"
  export CB_WINDOW_LIST_CMD="printf 'eja-live\neja-orphan\n'"
  run scripts/cerebro/cb-adopt
  [[ "$output" == *"active eja-live"* ]]
  [[ "$output" == *"orphaned eja-orphan"* ]]
}

@test "slug with both task dir and window → active, not orphaned" {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro-both"; mkdir -p "$CB_HOME/tasks/eja-both"
  export CB_WINDOW_LIST_CMD="printf 'eja-both\n'"
  run scripts/cerebro/cb-adopt
  [[ "$output" == *"active eja-both"* ]]
  [[ "$output" != *"orphaned eja-both"* ]]
}

# --- T39: code-awareness — per-slug conductor sessions + dev-item cross-check ---

mk_code_task() { # mk_code_task <slug>
  mkdir -p "$CB_HOME/tasks/$1"
  printf 'kind=code\nworktree=/x\njira=EJA-9\nsession=%s\ntarget=ultron\n' "$1" > "$CB_HOME/tasks/$1/meta"
}

@test "code task with a live per-slug session → active-code, not window-stale" {
  mk_code_task fix-live
  export CB_SESSION_LIST_CMD="printf 'fix-live\n'"
  run scripts/cerebro/cb-adopt
  [[ "$output" == *"active-code fix-live"* ]]
  [[ "$output" != *"stale fix-live"* ]]
}

@test "code task with a dead session → stale-code" {
  mk_code_task fix-dead
  export CB_SESSION_LIST_CMD="printf ''"
  run scripts/cerebro/cb-adopt
  [[ "$output" == *"stale-code fix-dead"* ]]
}

@test "active dev item with no task dir → untracked-item" {
  export CB_VAULT="$BATS_TEST_TMPDIR/vault"
  mkdir -p "$CB_VAULT/00 Inbox"
  printf -- '---\nslug: eja-777-loose\nstatus: active\nrepo: ultron\n---\n' > "$CB_VAULT/00 Inbox/eja-777-loose.md"
  run scripts/cerebro/cb-adopt
  [[ "$output" == *"untracked-item eja-777-loose"* ]]
}

@test "active dev item WITH a task dir is not untracked" {
  export CB_VAULT="$BATS_TEST_TMPDIR/vault2"
  mkdir -p "$CB_VAULT/00 Inbox"
  printf -- '---\nslug: eja-live\nstatus: active\nrepo: ultron\n---\n' > "$CB_VAULT/00 Inbox/eja-live.md"
  run scripts/cerebro/cb-adopt
  [[ "$output" != *"untracked-item eja-live"* ]]
}
