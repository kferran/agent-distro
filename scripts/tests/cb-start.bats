setup() {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks"
  export CB_REGISTRY="$BATS_TEST_TMPDIR/projects.md"
  printf -- '- project: cerebro\n  checkout: %s\n  delivery: research-only\n' "$HOME/vault" > "$CB_REGISTRY"
  export CB_TMUX_CMD="printf 'TMUX %s\n'"      # capture launch, no real tmux
  export CB_WINDOW_LIST_CMD="printf ''"        # no existing windows
  export CB_GUARD_CMD=:   # R1: don't invoke the real cb-guard (network MCP probe) from tests
}

# --- R1: cb-guard rides every supervision command ---
@test "cb-start runs cb-guard first" {
  export CB_GUARD_CMD="$BATS_TEST_TMPDIR/guard-rec"
  printf '#!/usr/bin/env bash\ntouch %q\n' "$BATS_TEST_TMPDIR/guard-ran" > "$CB_GUARD_CMD"
  chmod +x "$CB_GUARD_CMD"
  run scripts/cerebro/cb-start --research probe-g --target cerebro
  [ -f "$BATS_TEST_TMPDIR/guard-ran" ]
}
@test "does not refuse merely because task dir exists (cb-brief already created it)" {
  mkdir -p "$CB_HOME/tasks/dupe"
  run scripts/cerebro/cb-start --research dupe --target cerebro
  [ "$status" -eq 0 ]
}

@test "refuses a slug with shell metacharacters before touching git/tmux (no eval injection)" {
  run scripts/cerebro/cb-start --research 'x;touch /tmp/cb-pwn' --target cerebro
  [ "$status" -eq 2 ]
  [[ "$output" == *slug* ]]
  [ ! -e /tmp/cb-pwn ]
}
@test "refuses when a live tmux window for the slug exists" {
  mkdir -p "$CB_HOME/tasks/dupe"
  CB_WINDOW_LIST_CMD="printf 'dupe\n'" run scripts/cerebro/cb-start --research dupe --target cerebro
  [ "$status" -ne 0 ]; [[ "$output" == *"exists"* || "$output" == *"window"* ]]
}
@test "refuses when beacon=running AND the window is alive" {
  mkdir -p "$CB_HOME/tasks/dupe"
  printf 'running' > "$CB_HOME/tasks/dupe/status"
  CB_WINDOW_LIST_CMD="printf 'dupe\n'" run scripts/cerebro/cb-start --research dupe --target cerebro
  [ "$status" -ne 0 ]; [[ "$output" == *"exists"* || "$output" == *"window"* ]]
}
@test "beacon=running but window gone -> stale beacon, re-dispatches (proceeds + overwrites beacon)" {
  mkdir -p "$CB_HOME/tasks/dupe"
  printf 'running' > "$CB_HOME/tasks/dupe/status"
  # CB_WINDOW_LIST_CMD="printf ''" from setup() -> no live window for "dupe"
  run scripts/cerebro/cb-start --research dupe --target cerebro
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale beacon"* ]]
  [ "$(cat "$CB_HOME/tasks/dupe/status")" = "running" ]
}
@test "spawns a fresh research task and writes running beacon" {
  run scripts/cerebro/cb-start --research probe-x --target cerebro
  [ "$status" -eq 0 ]
  [ "$(cat "$CB_HOME/tasks/probe-x/status")" = "running" ]
}
@test "spawn writes a launch.sh with remote-control and the slug" {
  run scripts/cerebro/cb-start --research probe-y --target cerebro
  [ "$status" -eq 0 ]
  [ -f "$CB_HOME/tasks/probe-y/launch.sh" ]
  [[ "$(cat "$CB_HOME/tasks/probe-y/launch.sh")" == *"--remote-control"* ]]
  [[ "$(cat "$CB_HOME/tasks/probe-y/launch.sh")" == *"probe-y"* ]]
}
@test "scratch-dir path (no --target) mkdirs the worktree dir and writes the beacon" {
  run scripts/cerebro/cb-start --research probe-z
  [ "$status" -eq 0 ]
  [ -d "$CB_HOME/worktrees/probe-z" ]
  [ "$(cat "$CB_HOME/tasks/probe-z/status")" = "running" ]
}

@test "--target unknown/unresolved: no checkout in registry -> error, no beacon, no launch.sh" {
  run scripts/cerebro/cb-start --research ghost --target no-such-project
  [ "$status" -ne 0 ]
  [[ "$output" == *"no-such-project"* ]]
  [ ! -f "$CB_HOME/tasks/ghost/status" ]
  [ ! -f "$CB_HOME/tasks/ghost/launch.sh" ]
}

@test "--target resolves to a checkout path that does not exist -> error, no beacon" {
  printf -- '- project: ghosttown\n  checkout: %s/nope-does-not-exist\n  delivery: research-only\n' "$BATS_TEST_TMPDIR" >> "$CB_REGISTRY"
  run scripts/cerebro/cb-start --research spooky --target ghosttown
  [ "$status" -ne 0 ]
  [[ "$output" == *"nope-does-not-exist"* || "$output" == *"ghosttown"* ]]
  [ ! -f "$CB_HOME/tasks/spooky/status" ]
  [ ! -f "$CB_HOME/tasks/spooky/launch.sh" ]
}

@test "launch failure: tmux launch fails -> no beacon, launch.sh removed, non-zero exit" {
  CB_TMUX_CMD="false" run scripts/cerebro/cb-start --research boom --target cerebro
  [ "$status" -ne 0 ]
  [ ! -f "$CB_HOME/tasks/boom/status" ]
  [ ! -f "$CB_HOME/tasks/boom/launch.sh" ]
}

@test "launch.sh embeds the read-only research-agent constraint" {
  run scripts/cerebro/cb-start --research probe-ro --target cerebro
  [ "$status" -eq 0 ]
  [[ "$(cat "$CB_HOME/tasks/probe-ro/launch.sh")" == *"READ-ONLY"* ]]
}
@test "launch prompt's report frontmatter contract includes promote_to: none|code" {
  run scripts/cerebro/cb-start --research probe-promote --target cerebro
  [ "$status" -eq 0 ]
  [[ "$(cat "$CB_HOME/tasks/probe-promote/launch.sh")" == *"promote_to: none|code"* ]]
}
# §1/§2: the prompt used to say `deliverable:` "is REQUIRED and is the single
# place the drain reads your destination from … your finding will never land".
# The lander reads task meta and ignores the report, so that instruction now has
# research agents inventing destinations for a field nothing consults — the
# exact failure the computed path exists to remove.
@test "the research prompt tells the agent its destination is already decided, not proposed" {
  run scripts/cerebro/cb-start --research probe-dest --target cerebro
  [ "$status" -eq 0 ]
  local ls; ls="$(cat "$CB_HOME/tasks/probe-dest/launch.sh")"
  [[ "$ls" == *"YOUR DESTINATION IS ALREADY DECIDED"* ]]
  [[ "$ls" == *"IGNORED"* ]]
  [[ "$ls" != *"is REQUIRED"* ]]
  [[ "$ls" != *"the single place the drain reads"* ]]
  [[ "$ls" != *"deliverable: none"* ]]
  # the read-only guardrail is untouched by the rewrite
  [[ "$ls" == *"READ-ONLY"* ]]
}
@test "launch.sh bakes in the default claude bin when CB_CLAUDE_BIN is unset" {
  unset CB_CLAUDE_BIN 2>/dev/null || true
  run scripts/cerebro/cb-start --research probe-defbin --target cerebro
  [ "$status" -eq 0 ]
  [[ "$(cat "$CB_HOME/tasks/probe-defbin/launch.sh")" == *"$HOME/.local/bin/claude"* ]]
}
@test "launch.sh bakes in CB_CLAUDE_BIN (resolved at write time, not deferred)" {
  export CB_CLAUDE_BIN="/opt/custom/claude"
  run scripts/cerebro/cb-start --research probe-custombin --target cerebro
  [ "$status" -eq 0 ]
  [[ "$(cat "$CB_HOME/tasks/probe-custombin/launch.sh")" == *"/opt/custom/claude"* ]]
  # baked literally, not a runtime lookup
  [[ "$(cat "$CB_HOME/tasks/probe-custombin/launch.sh")" != *'CB_CLAUDE_BIN'* ]]
}
@test "--research with no value gives usage exit 2, not unbound-variable error" {
  run scripts/cerebro/cb-start --research
  [ "$status" -eq 2 ]
}
@test "--target with no value gives usage exit 2, not unbound-variable error" {
  run scripts/cerebro/cb-start --research foo --target
  [ "$status" -eq 2 ]
}

@test "real launch path ensures the cb tmux session exists, then opens window <slug> via -t cb:" {
  local faketmux="$BATS_TEST_TMPDIR/faketmux-bin"; mkdir -p "$faketmux"
  cat > "$faketmux/tmux" <<'EOF'
#!/usr/bin/env bash
echo "tmux $*" >> "$CB_TMUX_LOG"
# stateful: no session until "new-session" has run, so the post-create
# hard re-check (race-safety) sees the session as existing.
if [ "$1" = "has-session" ]; then [ -f "$CB_SESSION_MARKER" ] && exit 0 || exit 1; fi
if [ "$1" = "new-session" ]; then touch "$CB_SESSION_MARKER"; fi
exit 0
EOF
  chmod +x "$faketmux/tmux"
  export CB_TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"
  export CB_SESSION_MARKER="$BATS_TEST_TMPDIR/session-marker"
  unset CB_TMUX_CMD
  PATH="$faketmux:$PATH" run scripts/cerebro/cb-start --research probe-sess --target cerebro
  [ "$status" -eq 0 ]
  grep -qx 'tmux has-session -t cb' "$CB_TMUX_LOG"
  grep -qx 'tmux new-session -d -s cb' "$CB_TMUX_LOG"
  grep -q 'tmux new-window -t cb: -n probe-sess ' "$CB_TMUX_LOG"
}

@test "session-ensure is race-safe: new-session failing (loser of the race) does not kill the script under set -e, hard re-check sees the winner's session" {
  local faketmux="$BATS_TEST_TMPDIR/faketmux-bin-race"; mkdir -p "$faketmux"
  cat > "$faketmux/tmux" <<'EOF'
#!/usr/bin/env bash
echo "tmux $*" >> "$CB_TMUX_LOG"
# models the actual race: first has-session sees nothing (both racers agree
# there's no session yet), this racer's new-session loses (duplicate session
# — the other racer won), then the hard re-check's has-session sees the
# winner's session and succeeds.
if [ "$1" = "has-session" ]; then
  n=$(( $(cat "$CB_HS_COUNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$CB_HS_COUNT"
  [ "$n" -ge 2 ] && exit 0 || exit 1
fi
[ "$1" = "new-session" ] && exit 1
exit 0
EOF
  chmod +x "$faketmux/tmux"
  export CB_TMUX_LOG="$BATS_TEST_TMPDIR/tmux-race.log"
  export CB_HS_COUNT="$BATS_TEST_TMPDIR/hs-count"
  unset CB_TMUX_CMD
  PATH="$faketmux:$PATH" run scripts/cerebro/cb-start --research probe-race --target cerebro
  [ "$status" -eq 0 ]
  grep -qx 'tmux new-session -d -s cb' "$CB_TMUX_LOG"
}

@test "session-ensure hard-fails cleanly when the cb session can never be created" {
  local faketmux="$BATS_TEST_TMPDIR/faketmux-bin-fail"; mkdir -p "$faketmux"
  cat > "$faketmux/tmux" <<'EOF'
#!/usr/bin/env bash
echo "tmux $*" >> "$CB_TMUX_LOG"
[ "$1" = "has-session" ] && exit 1   # never exists, no matter what
exit 0
EOF
  chmod +x "$faketmux/tmux"
  export CB_TMUX_LOG="$BATS_TEST_TMPDIR/tmux-fail.log"
  unset CB_TMUX_CMD
  PATH="$faketmux:$PATH" run scripts/cerebro/cb-start --research probe-fail --target cerebro
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot ensure cb session"* ]]
  [ ! -f "$CB_HOME/tasks/probe-fail/launch.sh" ]
  [ ! -f "$CB_HOME/tasks/probe-fail/status" ]
}

@test "stale beacon re-dispatch archives the prior report.md (not left to poison classify_research)" {
  load ../lib/classify.sh
  mkdir -p "$CB_HOME/tasks/dupe"
  printf -- '---\nstatus: complete\n---\n' > "$CB_HOME/tasks/dupe/report.md"
  printf 'running' > "$CB_HOME/tasks/dupe/status"
  # CB_WINDOW_LIST_CMD="printf ''" from setup() -> no live window for "dupe"
  run scripts/cerebro/cb-start --research dupe --target cerebro
  [ "$status" -eq 0 ]
  [ ! -f "$CB_HOME/tasks/dupe/report.md" ]
  [ -f "$CB_HOME/tasks/dupe/report.prev.md" ]
  grep -q "status: complete" "$CB_HOME/tasks/dupe/report.prev.md"
  run classify_research "$CB_HOME/tasks/dupe"
  [ "$output" != "ready-for-review" ]
}

# =====================================================================
# cb-start --code (T20): three-surface collision check + worktree add +
# per-slug-session conductor launch (ratified 2026-07-12).
# =====================================================================

setup_code() {
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME/code/worktrees"
  CO="$BATS_TEST_TMPDIR/checkout"; mkdir -p "$CO"
  printf -- '- project: ultron\n  workspace: porchsoftware\n  repo: ultron\n  base: main\n  branch_prefix: fe/\n  checkout: %s\n  delivery: bitbucket-pr\n' "$CO" > "$CB_REGISTRY"
  export GITMOCK_LOG="$BATS_TEST_TMPDIR/git.log"
  cat > "$BATS_TEST_TMPDIR/gitmock" <<'EOF'
#!/usr/bin/env bash
echo "GIT $*" >> "$GITMOCK_LOG"
case "$*" in
  *"ls-remote"*) [ -f "${GITMOCK_LSREMOTE:-}" ] && cat "$GITMOCK_LSREMOTE";;
  *"branch --list"*) [ -f "${GITMOCK_BRANCHLIST:-}" ] && cat "$GITMOCK_BRANCHLIST";;
  *"rev-list"*"HEAD..origin/"*) echo "${GITMOCK_BEHIND:-0}";;   # commits behind base
  *"rev-list"*"origin/"*"..HEAD"*) echo "${GITMOCK_AHEAD:-0}";;  # commits ahead of base
  *"rev-parse --abbrev-ref"*) echo "${GITMOCK_BRANCH:-fe/adopt}";;
  *"status --porcelain"*) [ -f "${GITMOCK_STATUS:-}" ] && cat "$GITMOCK_STATUS";;
  *"branch --merged"*) [ -f "${GITMOCK_MERGED:-}" ] && cat "$GITMOCK_MERGED";;   # step 17: merged-branch dedup
  *"diff --name-only"*) [ -f "${GITMOCK_DIFF:-}" ] && cat "$GITMOCK_DIFF";;      # R5: an in-flight worktree's changed files
esac
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/gitmock"
  export CB_GIT_CMD="$BATS_TEST_TMPDIR/gitmock"
  export CB_SESSION_LIST_CMD="printf ''"
}

@test "--code success: fetch + worktree-add transcript, meta, beacon, conductor launch.sh" {
  setup_code
  run scripts/cerebro/cb-start --code fix-x --target ultron --jira EJA-123
  [ "$status" -eq 0 ]
  grep -q "GIT -C $CO fetch origin" "$GITMOCK_LOG"
  grep -q "GIT -C $CO worktree add -b fe/fix-x $HOME/code/worktrees/fix-x origin/main" "$GITMOCK_LOG"
  grep -q '^kind=code' "$CB_HOME/tasks/fix-x/meta"
  grep -q "^worktree=$HOME/code/worktrees/fix-x" "$CB_HOME/tasks/fix-x/meta"
  grep -q '^jira=EJA-123' "$CB_HOME/tasks/fix-x/meta"
  grep -q '^session=fix-x' "$CB_HOME/tasks/fix-x/meta"
  [ "$(cat "$CB_HOME/tasks/fix-x/status")" = "running" ]
  # two-step launch: the session starts an IDLE interactive claude; the
  # natural-language conductor prompt lands in launch-line for the dispatch
  # skill to cb-send AFTER context.md is filled (no read-vs-fill race)
  [[ "$(cat "$CB_HOME/tasks/fix-x/launch-line")" == *"ultron:work-conductor"* ]]
  [[ "$(cat "$CB_HOME/tasks/fix-x/launch-line")" == *"EJA-123"* ]]
  [[ "$(cat "$CB_HOME/tasks/fix-x/launch-line")" == *".ai/specs/fix-x/context.md"* ]]
  [[ "$(cat "$CB_HOME/tasks/fix-x/launch.sh")" != *"ultron:work-conductor"* ]]
  # code conductor launches WITH --remote-control so it shows in the remote view
  # (claude.ai/code + phone), like research agents (2026-07-14, Kyle — cb-start:99)
  [[ "$(cat "$CB_HOME/tasks/fix-x/launch.sh")" == *"--remote-control"* ]]
}

@test "--code refuses when the worktree dir already exists (surface 1)" {
  setup_code
  mkdir -p "$HOME/code/worktrees/fix-x"
  run scripts/cerebro/cb-start --code fix-x --target ultron
  [ "$status" -ne 0 ]; [[ "$output" == *"worktree"* ]]
  [ ! -f "$CB_HOME/tasks/fix-x/status" ]
}

@test "--code refuses when the branch exists locally (surface 2a)" {
  setup_code
  export GITMOCK_BRANCHLIST="$BATS_TEST_TMPDIR/branchlist"
  printf '  fe/fix-x\n' > "$GITMOCK_BRANCHLIST"
  run scripts/cerebro/cb-start --code fix-x --target ultron
  [ "$status" -ne 0 ]; [[ "$output" == *"branch"* ]]
}

@test "--code refuses when the branch exists on the remote (surface 2b)" {
  setup_code
  export GITMOCK_LSREMOTE="$BATS_TEST_TMPDIR/lsremote"
  printf 'abc123\trefs/heads/fe/fix-x\n' > "$GITMOCK_LSREMOTE"
  run scripts/cerebro/cb-start --code fix-x --target ultron
  [ "$status" -ne 0 ]; [[ "$output" == *"remote"* ]]
}

@test "--code refuses when a live tmux session <slug> exists (surface 3)" {
  setup_code
  CB_SESSION_LIST_CMD="printf 'fix-x\n'" run scripts/cerebro/cb-start --code fix-x --target ultron
  [ "$status" -ne 0 ]; [[ "$output" == *"session"* ]]
}

@test "--code launch failure leaves no beacon and no meta, and rolls back the worktree + branch" {
  setup_code
  CB_TMUX_CMD="false" run scripts/cerebro/cb-start --code fix-boom --target ultron
  [ "$status" -ne 0 ]
  [ ! -f "$CB_HOME/tasks/fix-boom/status" ]
  [ ! -f "$CB_HOME/tasks/fix-boom/meta" ]
  [ ! -f "$CB_HOME/tasks/fix-boom/launch.sh" ]
  # the just-created worktree + branch must be torn down, else the slug wedges
  grep -q "GIT -C $CO worktree remove --force $HOME/code/worktrees/fix-boom" "$GITMOCK_LOG"
  grep -q "GIT -C $CO branch -D fe/fix-boom" "$GITMOCK_LOG"
}

@test "--code requires --target with a checkout" {
  setup_code
  run scripts/cerebro/cb-start --code fix-x
  [ "$status" -ne 0 ]
  run scripts/cerebro/cb-start --code fix-x --target no-such
  [ "$status" -ne 0 ]
}

@test "--code registry defaults: branch_prefix fe/ and base main when rows are absent" {
  setup_code
  printf -- '- project: bare\n  checkout: %s\n  delivery: bitbucket-pr\n' "$CO" > "$CB_REGISTRY"
  run scripts/cerebro/cb-start --code fix-d --target bare
  [ "$status" -eq 0 ]
  grep -q "worktree add -b fe/fix-d $HOME/code/worktrees/fix-d origin/main" "$GITMOCK_LOG"
}

@test "session-ensure step is skipped when CB_TMUX_CMD override is set (never touches real tmux)" {
  # CB_TMUX_CMD is already set by setup() — a real "tmux" binary must never be invoked.
  local faketmux="$BATS_TEST_TMPDIR/faketmux-bin2"; mkdir -p "$faketmux"
  cat > "$faketmux/tmux" <<'EOF'
#!/usr/bin/env bash
echo "REAL TMUX CALLED $*" >> "$CB_TMUX_LOG"
exit 0
EOF
  chmod +x "$faketmux/tmux"
  export CB_TMUX_LOG="$BATS_TEST_TMPDIR/tmux2.log"
  PATH="$faketmux:$PATH" run scripts/cerebro/cb-start --research probe-mocked --target cerebro
  [ "$status" -eq 0 ]
  [ ! -s "$CB_TMUX_LOG" ]
}

# --- step 15: cb-start --code --adopt <slug> — attach a conductor to an
# EXISTING worktree so the always-on cb-watch sees it (no more boardless
# hand-launched conductors). ---

@test "--code --adopt attaches to an existing worktree: meta + beacon + --remote-control, no worktree-add" {
  setup_code
  local wt="$HOME/code/worktrees/fix-a"; mkdir -p "$wt"
  run scripts/cerebro/cb-start --code --adopt fix-a --target ultron --jira EJA-77
  [ "$status" -eq 0 ]
  run grep -q 'worktree add' "$GITMOCK_LOG"; [ "$status" -ne 0 ]     # did NOT create a worktree
  grep -q '^kind=code' "$CB_HOME/tasks/fix-a/meta"
  grep -q "^worktree=$wt" "$CB_HOME/tasks/fix-a/meta"
  grep -q '^jira=EJA-77' "$CB_HOME/tasks/fix-a/meta"
  grep -q '^session=fix-a' "$CB_HOME/tasks/fix-a/meta"
  grep -q '^target=ultron' "$CB_HOME/tasks/fix-a/meta"
  [ "$(cat "$CB_HOME/tasks/fix-a/status")" = "running" ]
  [[ "$(cat "$CB_HOME/tasks/fix-a/launch.sh")" == *"--remote-control"* ]]
  [[ "$(cat "$CB_HOME/tasks/fix-a/launch-line")" == *"ultron:work-conductor"* ]]
}

@test "(f) --adopt excludes the whole .ai/ tree and writes a context.md session marker" {
  setup_code
  local wt="$HOME/code/worktrees/fix-f"; mkdir -p "$wt"
  git -C "$wt" init -q                       # real repo so info/exclude is real
  run scripts/cerebro/cb-start --code --adopt fix-f --target ultron --jira EJA-88
  [ "$status" -eq 0 ]
  # (f): the WHOLE .ai/ tree kept out of git's view (broader than cb-brief's
  # per-slug R14 exclude) — adopted worktrees kept shipping .ai/ into PRs (#2464)
  grep -qxF '.ai/' "$wt/.git/info/exclude"
  # (a): adopt writes the context.md session marker (it never calls cb-brief),
  # so resolve_run's freshness floor engages and scopes classify to this session
  [ -f "$wt/.ai/specs/fix-f/context.md" ]
}

@test "(f) --adopt exclude is idempotent — no duplicate .ai/ line on a re-adopt" {
  setup_code
  local wt="$HOME/code/worktrees/fix-g"; mkdir -p "$wt"; git -C "$wt" init -q
  run scripts/cerebro/cb-start --code --adopt fix-g --target ultron
  # kill the session record so the second adopt is not a live no-op
  rm -rf "$CB_HOME/tasks/fix-g"
  run scripts/cerebro/cb-start --code --adopt fix-g --target ultron
  [ "$(grep -cxF '.ai/' "$wt/.git/info/exclude")" -eq 1 ]
}

@test "--code --adopt re-baselines: fetches the worktree + warns when behind origin/base (stale)" {
  setup_code
  mkdir -p "$HOME/code/worktrees/fix-stale"
  export GITMOCK_BEHIND=80 GITMOCK_BRANCH=fe/fix-stale
  run scripts/cerebro/cb-start --code --adopt fix-stale --target ultron
  [ "$status" -eq 0 ]
  grep -q "GIT -C $HOME/code/worktrees/fix-stale fetch origin" "$GITMOCK_LOG"
  [[ "$output" == *behind* ]]                                        # surfaced, not silent
  grep -q '^kind=code' "$CB_HOME/tasks/fix-stale/meta"               # still adopted (not forced)
}

@test "--code --adopt on the base branch, clean + behind → fast-forwards (re-baseline)" {
  setup_code
  mkdir -p "$HOME/code/worktrees/fix-ff"
  export GITMOCK_BEHIND=3 GITMOCK_BRANCH=main   # on base, clean (no GITMOCK_STATUS)
  run scripts/cerebro/cb-start --code --adopt fix-ff --target ultron
  [ "$status" -eq 0 ]
  grep -q "GIT -C $HOME/code/worktrees/fix-ff merge --ff-only origin/main" "$GITMOCK_LOG"
}

@test "--code --adopt is a no-op (warn) when a live session already exists" {
  setup_code
  mkdir -p "$HOME/code/worktrees/fix-live"
  # explicit about WHY it is live — the guard reads harness liveness now, so
  # leaving this to whatever real tmux happens to report would pass by accident
  CB_SESSION_LIST_CMD="printf 'fix-live\n'" \
  CB_SESSION_PID_CMD="printf 'fix-live 1000\n'" \
  CB_PS_CMD="printf '1 0 systemd\n1000 1 claude\n'" \
    run scripts/cerebro/cb-start --code --adopt fix-live --target ultron
  [ "$status" -eq 0 ]
  [[ "$output" == *"already live"* || "$output" == *"no-op"* ]]
  [ ! -f "$CB_HOME/tasks/fix-live/meta" ]                            # no relaunch, no meta clobber
}

@test "--code --adopt still no-ops when liveness is UNAVAILABLE (cannot tell → never relaunch)" {
  setup_code
  mkdir -p "$HOME/code/worktrees/fix-unk"
  CB_SESSION_LIST_CMD="exit 127" run scripts/cerebro/cb-start --code --adopt fix-unk --target ultron
  [ "$status" -eq 0 ]
  [[ "$output" == *"already live"* || "$output" == *"no-op"* ]]
  [ ! -f "$CB_HOME/tasks/fix-unk/meta" ]
}

@test "--code --adopt refuses when the worktree does not exist" {
  setup_code
  run scripts/cerebro/cb-start --code --adopt fix-none --target ultron
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
  [ ! -f "$CB_HOME/tasks/fix-none/meta" ]
}

@test "--code --adopt launch failure leaves the pre-existing worktree intact (no rollback)" {
  setup_code
  mkdir -p "$HOME/code/worktrees/fix-boom"
  CB_TMUX_CMD="false" run scripts/cerebro/cb-start --code --adopt fix-boom --target ultron
  [ "$status" -ne 0 ]
  [ ! -f "$CB_HOME/tasks/fix-boom/status" ]                          # no beacon on failure
  run grep -q 'worktree remove' "$GITMOCK_LOG"; [ "$status" -ne 0 ]  # NEVER removed the existing worktree
  [ -d "$HOME/code/worktrees/fix-boom" ]
}

@test "--code --adopt honors an explicit --worktree path" {
  setup_code
  local wt="$BATS_TEST_TMPDIR/custom-wt"; mkdir -p "$wt"
  run scripts/cerebro/cb-start --code --adopt fix-cw --target ultron --worktree "$wt"
  [ "$status" -eq 0 ]
  grep -q "^worktree=$wt" "$CB_HOME/tasks/fix-cw/meta"
}

# --- step 16: spawned agents inherit a sane PATH (node bin + ~/.local/bin) ---
# A tmux-spawned non-login shell doesn't source ~/.bashrc, so node/npx/pipx bins
# fall off PATH and any tool the agent drives (Kusto MCP, context7, stop-hooks)
# silently ENOENTs. launch.sh must bake a known-good PATH before exec.

@test "step16: code launch.sh bakes a PATH export with the node bin + ~/.local/bin, NOT exec'd" {
  setup_code
  export CB_NODE_BIN="/fake/nvm/node/v22/bin"
  run scripts/cerebro/cb-start --code fix-p --target ultron
  [ "$status" -eq 0 ]
  local ls="$CB_HOME/tasks/fix-p/launch.sh"
  grep -qF "PATH=\"/fake/nvm/node/v22/bin:$HOME/.local/bin:\$PATH\"" "$ls"
  [[ "$(cat "$ls")" == *"--remote-control"* ]]              # still remote-control
  # the harness runs as a CHILD, so the pane outlives its exit...
  run grep -q '^exec env PATH=' "$ls"; [ "$status" -ne 0 ]
  grep -q '^env PATH=' "$CB_HOME/tasks/fix-p/launch.sh"
  # ...and falls through to a trailing shell, which is what keeps the session up.
  # `exec bash` (not a bare `bash`) so the pane ROOT comm becomes the shell and
  # cb_pane_proc_state can read it as dead.
  [ "$(tail -1 "$CB_HOME/tasks/fix-p/launch.sh")" = "exec bash" ]
}

@test "step16: --adopt launch.sh gets the same PATH export and the same trailing shell" {
  setup_code
  mkdir -p "$HOME/code/worktrees/fix-ap"
  export CB_NODE_BIN="/fake/node/bin"
  run scripts/cerebro/cb-start --code --adopt fix-ap --target ultron
  [ "$status" -eq 0 ]
  local ls="$CB_HOME/tasks/fix-ap/launch.sh"
  grep -qF "env PATH=\"/fake/node/bin:$HOME/.local/bin:\$PATH\"" "$ls"
  # byte-identical to the fresh path (both go through _write_conductor_launch)
  run grep -q '^exec env PATH=' "$ls"; [ "$status" -ne 0 ]
  [ "$(tail -1 "$ls")" = "exec bash" ]
}

@test "step16: research launch.sh also bakes the PATH export" {
  export CB_NODE_BIN="/fake/node/bin"
  run scripts/cerebro/cb-start --research probe-path --target cerebro
  [ "$status" -eq 0 ]
  local ls="$CB_HOME/tasks/probe-path/launch.sh"
  grep -qF "exec env PATH=\"/fake/node/bin:$HOME/.local/bin:\$PATH\"" "$ls"
  [[ "$(cat "$ls")" == *"READ-ONLY"* ]]                     # research prompt still baked
}

@test "step16: degrades to /usr/local/bin when node is off PATH and no nvm dir (no hard-fail)" {
  setup_code
  unset CB_NODE_BIN 2>/dev/null || true
  export CB_NVM_ROOT="$BATS_TEST_TMPDIR/empty-nvm"   # no versions/node/*/bin
  # run cb-start with node OFF PATH so command -v node fails → fallback branch
  PATH="/usr/bin:/bin" run scripts/cerebro/cb-start --code fix-fb --target ultron
  [ "$status" -eq 0 ]                                        # never hard-fails
  grep -q '^env PATH="/usr/local/bin:' "$CB_HOME/tasks/fix-fb/launch.sh"
}

# --- step 17: pre-dispatch ticket-identity dedup (a code spawn carrying a Jira
# KEY checks whether the TICKET is already resolved/in-flight elsewhere — the
# slug-only collision check misses this). WARN by default; REFUSE (needs --force)
# on the strongest "already done" signals: merged branch, archived-done dev item,
# merged PR. ---
ticket_vault() {
  export CB_VAULT="$BATS_TEST_TMPDIR/vault"
  mkdir -p "$CB_VAULT/00 Inbox" "$CB_VAULT/02 Areas/development/archive/items" "$CB_VAULT/00 Inbox"
}

@test "step17: a clean ticket proceeds silently (no dedup warning)" {
  setup_code; ticket_vault
  run scripts/cerebro/cb-start --code fix-clean --target ultron --jira EJA-9999
  [ "$status" -eq 0 ]
  [[ "$output" != *already* ]]
  [ "$(cat "$CB_HOME/tasks/fix-clean/status")" = "running" ]
}

@test "step17: an existing ACTIVE dev item for the ticket → warns, still proceeds" {
  setup_code; ticket_vault
  touch "$CB_VAULT/00 Inbox/some-other-EJA-9.md"
  run scripts/cerebro/cb-start --code fix-x --target ultron --jira EJA-9
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTIVE dev item"* ]]
  [ "$(cat "$CB_HOME/tasks/fix-x/status")" = "running" ]
}

@test "step17: an existing RCA/handle doc in the Inbox → warns, still proceeds" {
  setup_code; ticket_vault
  touch "$CB_VAULT/00 Inbox/2026-07-13-rca-EJA-9.md"
  run scripts/cerebro/cb-start --code fix-r --target ultron --jira EJA-9
  [ "$status" -eq 0 ]
  [[ "$output" == *Inbox* ]]
}

@test "step17: an ARCHIVED (done) dev item for the ticket → refuses without --force, proceeds with it" {
  setup_code; ticket_vault
  touch "$CB_VAULT/02 Areas/development/archive/items/old-EJA-9.md"
  run scripts/cerebro/cb-start --code fix-a2 --target ultron --jira EJA-9
  [ "$status" -ne 0 ]
  [[ "$output" == *ARCHIVED* ]]
  run grep -q 'worktree add' "$GITMOCK_LOG"; [ "$status" -ne 0 ]     # never created the worktree
  run scripts/cerebro/cb-start --code fix-a2 --target ultron --jira EJA-9 --force
  [ "$status" -eq 0 ]
}

@test "step17: a MERGED branch for the ticket → refuses without --force" {
  setup_code; ticket_vault
  export GITMOCK_MERGED="$BATS_TEST_TMPDIR/merged"; printf '  fe/eja-9\n* main\n' > "$GITMOCK_MERGED"
  run scripts/cerebro/cb-start --code fix-mb --target ultron --jira EJA-9
  [ "$status" -ne 0 ]
  [[ "$output" == *merged* || "$output" == *MERGED* ]]
  run grep -q 'worktree add' "$GITMOCK_LOG"; [ "$status" -ne 0 ]
  run scripts/cerebro/cb-start --code fix-mb --target ultron --jira EJA-9 --force
  [ "$status" -eq 0 ]
}

@test "step17: a MERGED Bitbucket PR for the ticket → refuses without --force" {
  setup_code; ticket_vault
  export CB_PR_SEARCH_CMD="echo MERGED"
  run scripts/cerebro/cb-start --code fix-pm --target ultron --jira EJA-9
  [ "$status" -ne 0 ]
  [[ "$output" == *MERGED* ]]
  run scripts/cerebro/cb-start --code fix-pm --target ultron --jira EJA-9 --force
  [ "$status" -eq 0 ]
}

# --- R5: dispatch serialization (distinct from step 17 — that asks whether the
# TICKET is already handled, this asks whether the WORK collides with a live
# conductor's files or subsystem) ---
inflight() {  # inflight <slug> <domain> — a LIVE code task holding GITMOCK_DIFF's files
  local wt="$BATS_TEST_TMPDIR/wt-$1"; mkdir -p "$wt"
  mkdir -p "$CB_HOME/tasks/$1"
  printf 'kind=code\nworktree=%s\njira=\nsession=%s\ntarget=ultron\n' "$wt" "$1" > "$CB_HOME/tasks/$1/meta"
  printf -- '---\nslug: %s\nstatus: active\nrepo: ultron\ndomain: %s\n---\n' "$1" "$2" > "$CB_VAULT/00 Inbox/$1.md"
  export CB_SESSION_LIST_CMD="printf '$1\n'"
}
candidate() {  # candidate <slug> <domain> [files-line]
  { printf -- '---\nslug: %s\nstatus: queued\nrepo: ultron\ndomain: %s\n' "$1" "$2"
    [ -n "${3:-}" ] && printf '%s\n' "$3"
    printf -- '---\n'; } > "$CB_VAULT/00 Inbox/$1.md"
}

@test "R5: declared files held by a live conductor → refuses without --force, proceeds with it" {
  setup_code; ticket_vault
  export GITMOCK_DIFF="$BATS_TEST_TMPDIR/diff"; printf 'src/forms/Stamp.cs\n' > "$GITMOCK_DIFF"
  inflight busy forms
  candidate coll forms "files: src/forms/Stamp.cs"
  run scripts/cerebro/cb-start --code coll --target ultron
  [ "$status" -ne 0 ]
  [[ "$output" == *"both touch"* ]]
  [[ "$output" == *"src/forms/Stamp.cs"* ]]
  run grep -q 'worktree add' "$GITMOCK_LOG"; [ "$status" -ne 0 ]   # never created the worktree
  run scripts/cerebro/cb-start --code coll --target ultron --force
  [ "$status" -eq 0 ]
}

@test "R5: same subsystem without a declared overlap warns and still spawns" {
  setup_code; ticket_vault
  export GITMOCK_DIFF="$BATS_TEST_TMPDIR/diff"; printf 'src/forms/Other.cs\n' > "$GITMOCK_DIFF"
  inflight busy forms
  candidate near forms "files: src/forms/Mine.cs"
  run scripts/cerebro/cb-start --code near --target ultron
  [ "$status" -eq 0 ]
  [[ "$output" == *"same subsystem"* ]]
  [[ "$output" != *"both touch"* ]]
}

@test "R5: a clean dispatch says nothing about overlap" {
  setup_code; ticket_vault
  candidate solo forms "files: src/forms/Mine.cs"
  run scripts/cerebro/cb-start --code solo --target ultron
  [ "$status" -eq 0 ]
  [[ "$output" != *"same subsystem"* ]]
  [[ "$output" != *"both touch"* ]]
}

@test "step17: an OPEN Bitbucket PR for the ticket → warns, still proceeds" {
  setup_code; ticket_vault
  export CB_PR_SEARCH_CMD="echo OPEN"
  run scripts/cerebro/cb-start --code fix-po --target ultron --jira EJA-9
  [ "$status" -eq 0 ]
  [[ "$output" == *OPEN* ]]
}

@test "step17: PR sub-check down (connection error) → skip-with-note, does NOT block" {
  setup_code; ticket_vault
  export CB_PR_SEARCH_CMD="exit 1"   # simulate a down / failed Bitbucket search
  run scripts/cerebro/cb-start --code fix-down --target ultron --jira EJA-9
  [ "$status" -eq 0 ]                # never fail-deep on a dead connection
  [[ "$output" == *skipped* ]]
  [ "$(cat "$CB_HOME/tasks/fix-down/status")" = "running" ]
}

@test "step17: a code spawn with no --jira runs no ticket check" {
  setup_code; ticket_vault
  touch "$CB_VAULT/02 Areas/development/archive/items/old-EJA-9.md"   # would refuse IF checked
  run scripts/cerebro/cb-start --code fix-nj --target ultron
  [ "$status" -eq 0 ]
}

@test "step17: --adopt does NOT run the ticket dedup (adopting the ticket's own worktree is intentional)" {
  setup_code; ticket_vault
  mkdir -p "$HOME/code/worktrees/fix-ad"
  touch "$CB_VAULT/02 Areas/development/archive/items/old-EJA-9.md"   # would refuse IF checked
  run scripts/cerebro/cb-start --code --adopt fix-ad --target ultron --jira EJA-9
  [ "$status" -eq 0 ]
}

# --- M6: a (re)launch/adopt of a code task is a FRESH lifecycle — clear any
# exhausted-wedge remediation counters so a later genuinely-new wedge episode
# re-arms remediation from zero. ---

@test "M6: fresh --code launch clears stale remediation counters" {
  setup_code
  mkdir -p "$CB_HOME/tasks/fix-remcnt" "$CB_HOME/beacons"
  printf '2' > "$CB_HOME/tasks/fix-remcnt/remediation-count"
  touch "$CB_HOME/beacons/fix-remcnt.remediated"
  run scripts/cerebro/cb-start --code fix-remcnt --target ultron
  [ "$status" -eq 0 ]
  [ ! -f "$CB_HOME/tasks/fix-remcnt/remediation-count" ]
  [ ! -f "$CB_HOME/beacons/fix-remcnt.remediated" ]
}

@test "M6: --adopt clears stale remediation counters" {
  setup_code
  mkdir -p "$HOME/code/worktrees/fix-remcnt-ad" "$CB_HOME/tasks/fix-remcnt-ad" "$CB_HOME/beacons"
  printf '2' > "$CB_HOME/tasks/fix-remcnt-ad/remediation-count"
  touch "$CB_HOME/beacons/fix-remcnt-ad.remediated"
  run scripts/cerebro/cb-start --code --adopt fix-remcnt-ad --target ultron
  [ "$status" -eq 0 ]
  [ ! -f "$CB_HOME/tasks/fix-remcnt-ad/remediation-count" ]
  [ ! -f "$CB_HOME/beacons/fix-remcnt-ad.remediated" ]
}

# =====================================================================
# cb-start --ops (ops board-agent lane, 2026-07-17): write/ops tasks that
# aren't code-conductor work — a vault-maintenance sweep, a reporting run,
# an approved ops-batch. Board-visible via a `cb` window like research;
# meta kind=ops routes classify → classify_research (beacon + report.md).
# Supervise-only: writes confined to the declared scope, no commit/push,
# no unapproved outward writes.
# =====================================================================

setup_ops() { export CB_VAULT="$BATS_TEST_TMPDIR/vault"; mkdir -p "$CB_VAULT/00 Inbox"; }

@test "--ops spawns a board window: running beacon + kind=ops meta, workdir defaults to the vault" {
  setup_ops
  run scripts/cerebro/cb-start --ops sweep-x
  [ "$status" -eq 0 ]
  [ "$(cat "$CB_HOME/tasks/sweep-x/status")" = "running" ]
  grep -q '^kind=ops' "$CB_HOME/tasks/sweep-x/meta"
  grep -q "^workdir=$CB_VAULT" "$CB_HOME/tasks/sweep-x/meta"
  grep -q '^session=sweep-x' "$CB_HOME/tasks/sweep-x/meta"
}

# §1 / decision 4: the ops lane is brief-then-start, so cb-brief --ops stamps
# the computed landing path into meta BEFORE this write replaces the whole file.
# Losing it here would send every ops task's report to a path recomputed at
# landing time — a different date from the one it was scaffolded with.
@test "--ops preserves a deliverable= line cb-brief already wrote into meta" {
  setup_ops
  mkdir -p "$CB_HOME/tasks/sweep-p"
  printf 'kind=ops\ndeliverable=00 Inbox/2026-01-02-ops-sweep-p.md\n' > "$CB_HOME/tasks/sweep-p/meta"
  run scripts/cerebro/cb-start --ops sweep-p
  [ "$status" -eq 0 ]
  local m="$CB_HOME/tasks/sweep-p/meta"
  grep -qx 'deliverable=00 Inbox/2026-01-02-ops-sweep-p.md' "$m"
  grep -q '^kind=ops' "$m"
  grep -q "^workdir=$CB_VAULT" "$m"
  grep -q '^session=sweep-p' "$m"
}

# The same preserve, END TO END through the real scaffolder rather than a
# hand-written meta. This is the only test that proves decision 4 actually
# holds for the way the ops lane runs — cb-brief --ops writes the meta, cb-start
# --ops rewrites it — and it is worth its own case because the two scripts agree
# by convention (a `deliverable=` line shape), not by a shared function.
@test "brief-then-start: cb-brief --ops's computed deliverable survives the spawn" {
  setup_ops
  run scripts/cerebro/cb-brief --ops sweep-e2e
  [ "$status" -eq 0 ]
  local want; want="deliverable=00 Inbox/$(TZ=America/Denver date +%F)-ops-sweep-e2e.md"
  grep -qx "$want" "$CB_HOME/tasks/sweep-e2e/meta"
  run scripts/cerebro/cb-start --ops sweep-e2e
  [ "$status" -eq 0 ]
  local m="$CB_HOME/tasks/sweep-e2e/meta"
  grep -qx "$want" "$m"          # not recomputed, not dropped
  grep -q '^kind=ops' "$m"
  grep -q "^workdir=$CB_VAULT" "$m"
  grep -q '^session=sweep-e2e' "$m"
  # and the brief cb-start baked into the prompt is the one cb-brief wrote
  [[ "$(cat "$CB_HOME/tasks/sweep-e2e/launch.sh")" == *"# Write scope"* ]]
}

@test "--ops with no prior deliverable= writes the meta clean (no blank line, no failure)" {
  setup_ops
  run scripts/cerebro/cb-start --ops sweep-n
  [ "$status" -eq 0 ]
  ! grep -q '^deliverable=' "$CB_HOME/tasks/sweep-n/meta"
  [ "$(wc -l < "$CB_HOME/tasks/sweep-n/meta")" -eq 3 ]
}

@test "--ops launch.sh: --remote-control + slug + ops write-contract (NOT read-only)" {
  setup_ops
  run scripts/cerebro/cb-start --ops sweep-c
  [ "$status" -eq 0 ]
  local ls="$CB_HOME/tasks/sweep-c/launch.sh"
  [[ "$(cat "$ls")" == *"--remote-control"* ]]
  [[ "$(cat "$ls")" == *"sweep-c"* ]]
  [[ "$(cat "$ls")" == *"ops agent"* ]]
  [[ "$(cat "$ls")" != *"READ-ONLY"* ]]
  # guardrail (the crux): no commit/push, no unapproved outward writes
  [[ "$(cat "$ls")" == *"commit"* ]]
  [[ "$(cat "$ls")" == *"approv"* ]]
}

# §1 / wave 3 item 0: the ops prompt used to say "write your durable output into
# the vault Inbox ('00 Inbox/')" AND write report.md. Once cb-land files the
# report itself that instruction produces TWO Inbox files for one finding, and
# once cb-brief --ops stamps the computed path into ops meta, an agent that
# picks that same path trips cb-land's collision refusal on every ops run.
# Same rewrite the research prompt got — the destination is computed, visible in
# the brief, and a `deliverable:` the agent writes is ignored.
@test "the ops prompt tells the agent its destination is already decided, not written by hand" {
  setup_ops
  run scripts/cerebro/cb-start --ops sweep-d
  [ "$status" -eq 0 ]
  local ls; ls="$(cat "$CB_HOME/tasks/sweep-d/launch.sh")"
  [[ "$ls" == *"report.md"* ]]
  [[ "$ls" == *"YOUR DESTINATION IS ALREADY DECIDED"* ]]
  [[ "$ls" == *"IGNORED"* ]]
  [[ "$ls" != *"write your durable output into the vault Inbox"* ]]
  [[ "$ls" != *"deliverable: <path to the Inbox file>"* ]]
  # the ops contract is untouched by the rewrite (still not the read-only lane)
  [[ "$ls" != *"READ-ONLY"* ]]
  [[ "$ls" == *"WRITE SCOPE"* ]]
  # the rewrite added backticks, parens and quotes to a string that gets
  # printf %q'd into launch.sh — a mis-escape here does not fail the spawn, it
  # produces a launch.sh that dies when tmux runs it, with no test to catch it
  run bash -n "$CB_HOME/tasks/sweep-d/launch.sh"
  [ "$status" -eq 0 ]
}

@test "--ops appends brief.md task specifics when present" {
  setup_ops
  mkdir -p "$CB_HOME/tasks/sweep-b"
  printf '# Objective\nUnassign 42 tickets.\n' > "$CB_HOME/tasks/sweep-b/brief.md"
  run scripts/cerebro/cb-start --ops sweep-b
  [ "$status" -eq 0 ]
  [[ "$(cat "$CB_HOME/tasks/sweep-b/launch.sh")" == *"Unassign 42 tickets"* ]]
}

@test "--ops --target resolves to a registry checkout workdir" {
  setup_ops
  local co="$BATS_TEST_TMPDIR/checkout-ops"; mkdir -p "$co"
  printf -- '- project: ops-proj\n  checkout: %s\n  delivery: research-only\n' "$co" >> "$CB_REGISTRY"
  run scripts/cerebro/cb-start --ops sweep-t --target ops-proj
  [ "$status" -eq 0 ]
  grep -q "^workdir=$co" "$CB_HOME/tasks/sweep-t/meta"
}

@test "--ops --target unresolved → error, no beacon, no launch" {
  setup_ops
  run scripts/cerebro/cb-start --ops sweep-ghost --target no-such-project
  [ "$status" -ne 0 ]
  [ ! -f "$CB_HOME/tasks/sweep-ghost/status" ]
  [ ! -f "$CB_HOME/tasks/sweep-ghost/launch.sh" ]
}

@test "--ops --scratch uses a disposable scratch workdir" {
  setup_ops
  run scripts/cerebro/cb-start --ops sweep-s --scratch
  [ "$status" -eq 0 ]
  [ -d "$CB_HOME/worktrees/sweep-s" ]
  grep -q "^workdir=$CB_HOME/worktrees/sweep-s" "$CB_HOME/tasks/sweep-s/meta"
}

@test "--ops refuses when a live window for the slug exists" {
  setup_ops
  CB_WINDOW_LIST_CMD="printf 'sweep-x\n'" run scripts/cerebro/cb-start --ops sweep-x
  [ "$status" -ne 0 ]
  [[ "$output" == *"window"* || "$output" == *"exists"* ]]
}

@test "--ops refuses a slug with shell metacharacters (no eval injection)" {
  setup_ops
  run scripts/cerebro/cb-start --ops 'x;touch /tmp/cb-pwn-ops'
  [ "$status" -eq 2 ]
  [ ! -e /tmp/cb-pwn-ops ]
}

@test "--ops with no value gives usage exit 2" {
  run scripts/cerebro/cb-start --ops
  [ "$status" -eq 2 ]
}

@test "--ops launch failure leaves no beacon, no meta, launch.sh removed" {
  setup_ops
  CB_TMUX_CMD="false" run scripts/cerebro/cb-start --ops sweep-boom
  [ "$status" -ne 0 ]
  [ ! -f "$CB_HOME/tasks/sweep-boom/status" ]
  [ ! -f "$CB_HOME/tasks/sweep-boom/meta" ]
  [ ! -f "$CB_HOME/tasks/sweep-boom/launch.sh" ]
}

@test "--ops re-dispatch archives a stale prior report.md (not left to poison classify)" {
  setup_ops
  mkdir -p "$CB_HOME/tasks/sweep-r"
  printf -- '---\nstatus: complete\n---\n' > "$CB_HOME/tasks/sweep-r/report.md"
  run scripts/cerebro/cb-start --ops sweep-r
  [ "$status" -eq 0 ]
  [ ! -f "$CB_HOME/tasks/sweep-r/report.md" ]
  [ -f "$CB_HOME/tasks/sweep-r/report.prev.md" ]
}

@test "--ops task classifies through the research path (kind=ops → classify_research)" {
  setup_ops
  load ../lib/classify.sh
  run scripts/cerebro/cb-start --ops sweep-cl
  [ "$status" -eq 0 ]
  CB_WINDOW_LIST_CMD="printf 'sweep-cl\n'" run classify "$CB_HOME/tasks/sweep-cl"
  [ "$output" = "running" ]
}

@test "--ops launch.sh bakes the PATH export (node bin + ~/.local/bin)" {
  setup_ops
  export CB_NODE_BIN="/fake/node/bin"
  run scripts/cerebro/cb-start --ops sweep-path
  [ "$status" -eq 0 ]
  grep -qF "exec env PATH=\"/fake/node/bin:$HOME/.local/bin:\$PATH\"" "$CB_HOME/tasks/sweep-path/launch.sh"
}

# --- easter egg (2026-07-17, Kyle): each dispatched X-Man is announced by
# naming a member of the roster (Cyclops, Wolverine, …). Cosmetic echo only —
# never an identifier, never affects state/exit. CB_XMAN_PICK pins it for tests.
@test "spawn calls out an X-Man from the roster (ops)" {
  setup_ops
  run scripts/cerebro/cb-start --ops sweep-egg
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cerebro dispatches:"* ]]
}
@test "CB_XMAN_PICK pins the called-out X-Man (deterministic)" {
  setup_ops
  CB_XMAN_PICK=Wolverine run scripts/cerebro/cb-start --ops sweep-wolverine
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cerebro dispatches: Wolverine"* ]]
}
@test "research spawn also calls out an X-Man" {
  CB_XMAN_PICK=Cyclops run scripts/cerebro/cb-start --research probe-egg --target cerebro
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cerebro dispatches: Cyclops"* ]]
}
@test "code spawn also calls out an X-Man" {
  setup_code
  CB_XMAN_PICK=Storm run scripts/cerebro/cb-start --code fix-egg --target ultron
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cerebro dispatches: Storm"* ]]
}

# --- surface 3 asks "is the HARNESS alive", not "is the NAME taken" ----------
# Inverted 2026-07-30. A conductor session now outlives its agent by design, so a
# name-keyed refusal here would permanently block re-spawning any slug that had
# ever run — the failure mode that turns this fix into an outage. The name is
# still a real tmux constraint though, so the dead session is CLEARED first, and
# it has to happen before the worktree add or the launch fails after the mutation.
# The dead-session shape, shared by the cases below: the tmux NAME is present,
# but the pane root is a bare shell with no harness anywhere beneath it.
dead_session_mocks() {
  export CB_SESSION_LIST_CMD="printf '$1\n'"
  export CB_SESSION_PID_CMD="printf '$1 1000\n'"
  export CB_PS_CMD="printf '1 0 systemd\n1000 1 bash\n'"
}

@test "--code does NOT refuse a name-present session whose harness is dead — it clears it and spawns" {
  setup_code
  dead_session_mocks fix-x
  KILLLOG="$BATS_TEST_TMPDIR/killed"
  CB_TMUX_KILL_CMD="echo killed >> $KILLLOG" \
    run scripts/cerebro/cb-start --code fix-x --target ultron
  [ "$status" -eq 0 ]
  [[ "$output" == *"cleared the dead session fix-x"* ]]
  [ -f "$KILLLOG" ]                                   # the stale NAME was actually released
  [ -f "$CB_HOME/tasks/fix-x/status" ]                # and the spawn went through
}

@test "--code STILL refuses when the harness is genuinely alive (surface 3 holds)" {
  setup_code
  KILLLOG="$BATS_TEST_TMPDIR/killed"
  CB_SESSION_LIST_CMD="printf 'fix-x\n'" \
  CB_SESSION_PID_CMD="printf 'fix-x 1000\n'" \
  CB_PS_CMD="printf '1 0 systemd\n1000 1 claude\n'" \
  CB_TMUX_KILL_CMD="echo killed >> $KILLLOG" \
    run scripts/cerebro/cb-start --code fix-x --target ultron
  [ "$status" -ne 0 ]; [[ "$output" == *"already exists"* ]]
  [ ! -f "$KILLLOG" ]                                 # NEVER kill a session doing work
  [ ! -f "$CB_HOME/tasks/fix-x/status" ]
}

@test "--code refuses rather than creating a worktree when the dead session cannot be cleared" {
  setup_code
  dead_session_mocks fix-x
  CB_TMUX_KILL_CMD="false" run scripts/cerebro/cb-start --code fix-x --target ultron
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not clear the dead session"* ]]
  # the point of failing HERE: no worktree was added, so there is nothing to roll back
  run grep -q 'worktree add' "$GITMOCK_LOG"; [ "$status" -ne 0 ]
  [ ! -f "$CB_HOME/tasks/fix-x/status" ]
}

@test "--code --adopt re-adopts a dead session instead of no-oping forever" {
  setup_code
  mkdir -p "$HOME/code/worktrees/fix-dead"
  KILLLOG="$BATS_TEST_TMPDIR/killed"
  CB_SESSION_LIST_CMD="printf 'fix-dead\n'" \
  CB_SESSION_PID_CMD="printf 'fix-dead 1000\n'" \
  CB_PS_CMD="printf '1 0 systemd\n1000 1 bash\n'" \
  CB_TMUX_KILL_CMD="echo killed >> $KILLLOG" \
    run scripts/cerebro/cb-start --code --adopt fix-dead --target ultron
  [ "$status" -eq 0 ]
  [[ "$output" != *"already live"* ]]                 # the old name-keyed no-op is gone
  [ -f "$KILLLOG" ]
  [ -f "$CB_HOME/tasks/fix-dead/meta" ]               # relaunched onto the existing worktree
}

# --- 2026-07-31 board-accuracy: the launch beacon must be newline-terminated ---
# cb-start used to write a BARE `running` with no trailing newline. The agent
# contract (cb-brief) then tells the X-Man to APPEND `{state}: {one line}`, so
# the first append landed on the same line: `runningpaused: awaiting answer`.
# _beacon_state reads that as `runningpaused` — neither paused nor blocked — so
# classify falls through to liveness and a real declared question reads as a
# crash. cb-ask carries an explicit guard for exactly this; a plain agent has none.
@test "the launch beacon ends in a newline, so an agent's first append is its own line" {
  run scripts/cerebro/cb-start --research probe-nl --target cerebro
  [ "$status" -eq 0 ]
  beacon="$CB_HOME/tasks/probe-nl/status"
  [ -s "$beacon" ]
  [ -z "$(tail -c1 "$beacon")" ]     # empty iff the file ends in a newline
  printf 'paused: awaiting answer\n' >> "$beacon"      # what a well-behaved agent does
  load ../lib/classify.sh
  [ "$(_beacon_state "$beacon")" = paused ]
}

# --- 2a: a piped brief must never be silently discarded (hit live 2026-07-31) ---
# A brief piped into `cb-start --code --adopt …` was read and thrown away, and
# cb-start then printed its ordinary success banner — output IDENTICAL to a
# working dispatch. The conductor sat idle with no work and no context.md until a
# human noticed two minutes later. cb-start does not read stdin and is not going
# to start (it is fire-and-forget; briefing belongs to cb-brief + the launch
# line), so the contract is: refuse loudly, before anything spawns.
@test "2a: --code with a piped payload refuses, non-zero, before spawning anything" {
  setup_code
  run bash -c 'printf "a long brief\n" | scripts/cerebro/cb-start --code fix-stdin --target ultron'
  [ "$status" -ne 0 ]
  [[ "$output" == *stdin* ]]
  [ ! -e "$HOME/code/worktrees/fix-stdin" ]      # nothing spawned
  [ ! -f "$CB_HOME/tasks/fix-stdin/meta" ]
  [ ! -f "$GITMOCK_LOG" ]                        # refused before ANY git call
}

@test "2a: --research with a piped payload refuses too (same channel, same trap)" {
  run bash -c 'printf "brief\n" | scripts/cerebro/cb-start --research probe-stdin --target cerebro'
  [ "$status" -ne 0 ]
  [[ "$output" == *stdin* ]]
  [ ! -f "$CB_HOME/tasks/probe-stdin/status" ]
}

@test "2a: the refusal names the correct path (cb-brief + the launch line)" {
  setup_code
  run bash -c 'printf "x\n" | scripts/cerebro/cb-start --code fix-msg --target ultron'
  [[ "$output" == *cb-brief* ]]
}

@test "2a: stdin redirected from /dev/null still spawns (cron/systemd path)" {
  setup_code
  run bash -c 'scripts/cerebro/cb-start --code fix-null --target ultron < /dev/null'
  [ "$status" -eq 0 ]
  [ -f "$CB_HOME/tasks/fix-null/meta" ]
}

@test "2a: an EMPTY pipe is not a discarded brief — it spawns" {
  setup_code
  run bash -c 'printf "" | scripts/cerebro/cb-start --code fix-empty --target ultron'
  [ "$status" -eq 0 ]
  [ -f "$CB_HOME/tasks/fix-empty/meta" ]
}

# --- T39: a vault-row target spawns under its own worktree root -----------------
# cb-start hardcoded $HOME/code/worktrees/<slug> at both call sites, so
# `--code --target cerebro` (delivery: local-only) built its worktree in the
# Ultron tree; this very session had to pass --worktree by hand to work around it.
setup_vault_row() {   # a local-only vault row, the shape of the real `cerebro` row
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME/vault/.claude/worktrees" "$HOME/code/worktrees"
  CO="$HOME/vault"
  printf -- '- project: cerebro\n  repo: vault\n  base: main\n  branch_prefix: cerebro/\n  checkout: %s\n  delivery: local-only\n  worktree_root: %s/.claude/worktrees\n' \
    "$CO" "$CO" > "$CB_REGISTRY"
  export GITMOCK_LOG="$BATS_TEST_TMPDIR/git.log"
  printf '#!/usr/bin/env bash\necho "GIT $*" >> "$GITMOCK_LOG"\nexit 0\n' > "$BATS_TEST_TMPDIR/gitmock"
  chmod +x "$BATS_TEST_TMPDIR/gitmock"
  export CB_GIT_CMD="$BATS_TEST_TMPDIR/gitmock"
  export CB_SESSION_LIST_CMD="printf ''"
}

@test "T39: --code --target cerebro spawns the worktree under .claude/worktrees, not ~/code" {
  setup_vault_row
  run scripts/cerebro/cb-start --code vault-fix --target cerebro
  [ "$status" -eq 0 ]
  grep -q "^worktree=$HOME/vault/.claude/worktrees/vault-fix\$" "$CB_HOME/tasks/vault-fix/meta"
  grep -q "worktree add -b cerebro/vault-fix $HOME/vault/.claude/worktrees/vault-fix" "$GITMOCK_LOG"
  ! grep -q "$HOME/code/worktrees/vault-fix" "$GITMOCK_LOG"
}

@test "T39: the vault row's branch carries no fe/ prefix" {
  setup_vault_row
  run scripts/cerebro/cb-start --code vault-br --target cerebro
  [ "$status" -eq 0 ]
  grep -q "worktree add -b cerebro/vault-br " "$GITMOCK_LOG"
  ! grep -q "fe/" "$GITMOCK_LOG"
}

@test "T39: a local-only row invokes no PR adapter" {
  setup_vault_row
  run scripts/cerebro/cb-start --code vault-pr --target cerebro
  [ "$status" -eq 0 ]
  [ ! -f "$CB_HOME/tasks/vault-pr/pr" ]
  [[ "$output" != *bitbucket* ]]
}

@test "T39: --adopt defaults to the row's worktree root too (no hand-passed --worktree)" {
  setup_vault_row
  mkdir -p "$HOME/vault/.claude/worktrees/vault-adopt"
  run scripts/cerebro/cb-start --code --adopt vault-adopt --target cerebro
  [ "$status" -eq 0 ]
  grep -q "^worktree=$HOME/vault/.claude/worktrees/vault-adopt\$" "$CB_HOME/tasks/vault-adopt/meta"
}

@test "T39: a row with no worktree_root still spawns under ~/code/worktrees (unchanged)" {
  setup_code
  run scripts/cerebro/cb-start --code fix-default --target ultron
  [ "$status" -eq 0 ]
  grep -q "^worktree=$HOME/code/worktrees/fix-default\$" "$CB_HOME/tasks/fix-default/meta"
}

@test "T39: an explicit --worktree still overrides the row's root on adopt" {
  setup_vault_row
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere/vault-ovr"
  run scripts/cerebro/cb-start --code --adopt vault-ovr --target cerebro --worktree "$BATS_TEST_TMPDIR/elsewhere/vault-ovr"
  [ "$status" -eq 0 ]
  grep -q "^worktree=$BATS_TEST_TMPDIR/elsewhere/vault-ovr\$" "$CB_HOME/tasks/vault-ovr/meta"
}

# --- --settles: the activation for cross-task settlement (2026-08-03) --------
# The spawn is the one moment the link is KNOWN rather than inferred: you are
# starting this task because Kyle answered that one's question. Afterwards
# nothing in the data connects them, which is why comms-lookback-distillation's
# answered question sat open until a human closed it by hand.

@test "--settles records a settled-by pointer on the asking task" {
  source scripts/cerebro/lib/classify.sh
  ask="$CB_HOME/tasks/asker"; mkdir -p "$ask" "$CB_HOME/tasks/answerer"
  k="$(_decision_key needs-input 'standalone, fold, or hold?')"
  _decision_declare "$ask" "$k" needs-input "standalone, fold, or hold?"
  run scripts/cerebro/cb-start --research answerer --target cerebro --settles asker
  [ "$status" -eq 0 ]
  grep -q " settled-by $k answerer" "$ask/decisions"
  # still open — the pointer settles it when the answering task SHIPS
  run open_decisions_live "$ask"; [[ "$output" == *"standalone, fold, or hold"* ]]
  touch "$CB_HOME/tasks/answerer/done"
  run open_decisions_live "$ask"; [ -z "$output" ]
}

@test "--settles accepts slug:key to target one decision" {
  source scripts/cerebro/lib/classify.sh
  ask="$CB_HOME/tasks/asker2"; mkdir -p "$ask" "$CB_HOME/tasks/answerer2"
  k1="$(_decision_key needs-input 'question one')"; _decision_declare "$ask" "$k1" needs-input "question one"
  k2="$(_decision_key needs-input 'question two')"; _decision_declare "$ask" "$k2" needs-input "question two"
  run scripts/cerebro/cb-start --research answerer2 --target cerebro --settles "asker2:$k1"
  [ "$status" -eq 0 ]
  grep -q " settled-by $k1 answerer2" "$ask/decisions"
  ! grep -q " settled-by $k2 answerer2" "$ask/decisions"
  touch "$CB_HOME/tasks/answerer2/done"
  run open_decisions_live "$ask"; [[ "$output" == *"question two"* ]]; [[ "$output" != *"question one"* ]]
}

# A settlement bookkeeping error must never cost the dispatch — the spawn is the
# expensive thing and the whole point of the run.
@test "--settles against an unknown slug warns but the spawn still succeeds" {
  run scripts/cerebro/cb-start --research answerer3 --target cerebro --settles no-such-asker
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned answerer3"* ]]
  [[ "$output" == *"was not recorded"* ]]
}

@test "--settles requires an argument" {
  run scripts/cerebro/cb-start --research answerer4 --target cerebro --settles
  [ "$status" -eq 2 ]
}

# A spawn answers ONE question. Bare --settles maps to cb-settle --all, which is
# safe only when there is one open decision — otherwise shipping this task would
# retire decisions it never answered.
@test "--settles with no key REFUSES when the asker has several open decisions" {
  source scripts/cerebro/lib/classify.sh
  ask="$CB_HOME/tasks/asker5"; mkdir -p "$ask" "$CB_HOME/tasks/answerer5"
  k1="$(_decision_key needs-input 'question one')"; _decision_declare "$ask" "$k1" needs-input "question one"
  k2="$(_decision_key needs-input 'question two')"; _decision_declare "$ask" "$k2" needs-input "question two"
  run scripts/cerebro/cb-start --research answerer5 --target cerebro --settles asker5
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned answerer5"* ]]              # the spawn is never the casualty
  [[ "$output" == *"ambiguous"* ]]
  [[ "$output" == *"$k1"* ]]; [[ "$output" == *"$k2"* ]]  # names the keys to choose from
  [ ! -e "$ask/decisions.settled" ]
  ! grep -q " settled-by " "$ask/decisions"
  touch "$CB_HOME/tasks/answerer5/done"
  run open_decisions_live "$ask"
  [[ "$output" == *"question one"* ]]; [[ "$output" == *"question two"* ]]
}

# --- the X-Man name as STATE (2026-08-05) ------------------------------------
# The callout used to be a random echo that was never written down: attaching to
# a session told Kyle nothing about who owned it, and a second report of one task
# named a different mutant. The name is now persisted per task and derived from
# the SLUG, so it is stable for the task's whole life. Sessions and windows still
# carry BARE SLUGS — 29 files target them by exact name — so these tests assert
# persistence and stability, never a renamed target.
@test "a spawn persists the X-Man name to the task dir" {
  setup_ops
  run scripts/cerebro/cb-start --ops sweep-persist
  [ "$status" -eq 0 ]
  [ -f "$CB_HOME/tasks/sweep-persist/xman" ]
  name="$(cat "$CB_HOME/tasks/sweep-persist/xman")"
  [ -n "$name" ]
  [[ "$output" == *"Cerebro dispatches: $name"* ]]   # the echo and the file agree
}
@test "the same slug picks the same name twice (no RANDOM)" {
  source scripts/cerebro/lib/paths.sh; source scripts/cerebro/lib/xman.sh
  a="${xman_roster[$(xman_index sweep-determinism)]}"
  b="${xman_roster[$(xman_index sweep-determinism)]}"
  [ "$a" = "$b" ]
  # and a different slug is a different pick (the hash is not a constant)
  c="${xman_roster[$(xman_index sweep-other)]}"
  [ "$a" != "$c" ]
}
@test "an existing xman file is REUSED, never overwritten (a task keeps one identity)" {
  setup_ops
  mkdir -p "$CB_HOME/tasks/sweep-reuse"
  printf 'Rogue\n' > "$CB_HOME/tasks/sweep-reuse/xman"
  # CB_XMAN_PICK loses to the file on purpose: a pinned env var must not rewrite a
  # live task's identity mid-flight.
  CB_XMAN_PICK=Wolverine run scripts/cerebro/cb-start --ops sweep-reuse
  [ "$status" -eq 0 ]
  [ "$(cat "$CB_HOME/tasks/sweep-reuse/xman")" = "Rogue" ]
  [[ "$output" == *"Cerebro dispatches: Rogue"* ]]
}
@test "the roster has no duplicate entries" {
  source scripts/cerebro/lib/xman.sh
  n="${#xman_roster[@]}"
  u="$(printf '%s\n' "${xman_roster[@]}" | sort -u | wc -l)"
  [ "$n" -eq "$u" ]
  [ "$n" -gt 24 ]   # grown past the original roster (Kyle 2026-08-05)
}
@test "the original 24 roster names still resolve (they are in today's logs)" {
  source scripts/cerebro/lib/xman.sh
  for n in Wolverine Storm Cyclops "Jean Grey" Nightcrawler Rogue Gambit Beast \
           Colossus Iceman Magneto Mystique Psylocke Bishop Jubilee "Emma Frost" \
           Kitty-Pryde Havok Banshee Forge Dazzler Cannonball "Professor X" Deadpool; do
    printf '%s\n' "${xman_roster[@]}" | grep -Fqx "$n" || { echo "missing: $n"; return 1; }
  done
}
@test "the display never renames the tmux target" {
  # xman_tmux_mark touches @xman, the pane border and (own-session only)
  # status-right — never rename-session or rename-window. A suffix on either
  # breaks exact-match targeting in 29 files.
  ! grep -qE 'rename-session|rename-window' scripts/cerebro/lib/xman.sh
}
