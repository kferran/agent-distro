#!/usr/bin/env bats
# lib/memcap.sh (T34): memory-aware spawn gate — Ultron vue-tsc + dotnet
# contention has produced real exit-137 OOM kills; never spawn into pressure.

setup() {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks"
  load ../lib/memcap.sh
}

mk_meminfo() { # mk_meminfo <MemAvailable-kB>
  printf 'MemTotal:       65536000 kB\nMemFree:         1000000 kB\nMemAvailable:   %s kB\n' "$1" \
    > "$BATS_TEST_TMPDIR/meminfo"
  export CB_FREE_CMD="cat '$BATS_TEST_TMPDIR/meminfo'"
}

mk_code_task() { # mk_code_task <slug> — a live code agent
  mkdir -p "$CB_HOME/tasks/$1"
  printf 'kind=code\nworktree=/x\njira=\nsession=%s\ntarget=ultron\n' "$1" > "$CB_HOME/tasks/$1/meta"
}

@test "plenty of RAM + under cap → ok" {
  mk_meminfo $(( 16 * 1024 * 1024 ))   # 16 GB in kB
  CB_SESSION_LIST_CMD="printf ''" run memcap_ok
  [ "$status" -eq 0 ]
}

@test "MemAvailable below headroom → fail" {
  mk_meminfo $(( 4 * 1024 * 1024 ))    # 4 GB < 8192 MB default headroom
  CB_SESSION_LIST_CMD="printf ''" run memcap_ok
  [ "$status" -ne 0 ]
  [[ "$output" == *"headroom"* ]]
}

@test "headroom operator-tunable via CB_RAM_HEADROOM_MB" {
  mk_meminfo $(( 4 * 1024 * 1024 ))
  CB_RAM_HEADROOM_MB=2048 CB_SESSION_LIST_CMD="printf ''" run memcap_ok
  [ "$status" -eq 0 ]
}

@test "at the agent cap → fail even with RAM to spare" {
  mk_meminfo $(( 32 * 1024 * 1024 ))
  mk_code_task a1; mk_code_task a2; mk_code_task a3
  # Pin the cap. CB_AGENT_CAP's DEFAULT moved 3→6 on 2026-07-17 for bug-push
  # throughput and this test kept spawning three agents, so it stopped being at
  # the cap at all and went red on main. What it exists to prove is the gate, not
  # whatever the default happens to be this month.
  CB_AGENT_CAP=3 CB_SESSION_LIST_CMD="printf 'a1\na2\na3\n'" run memcap_ok
  [ "$status" -ne 0 ]
  [[ "$output" == *"cap"* ]]
}

@test "dead sessions don't count toward the cap" {
  mk_meminfo $(( 32 * 1024 * 1024 ))
  mk_code_task a1; mk_code_task a2; mk_code_task a3
  CB_AGENT_CAP=3 CB_SESSION_LIST_CMD="printf 'a1\n'" run memcap_ok   # only one actually live
  [ "$status" -eq 0 ]
}

# --- OOM classification (classify_code addition) ---

@test "pane showing exit 137 / Killed → failed with an oom marker" {
  CTD="$BATS_TEST_TMPDIR/tasks-oom/code-slug"; mkdir -p "$CTD"
  CWT="$BATS_TEST_TMPDIR/worktree"; mkdir -p "$CWT/.ai/specs/code-slug"
  printf 'kind=code\nworktree=%s\njira=\nsession=code-slug\ntarget=ultron\n' "$CWT" > "$CTD/meta"
  printf -- '---\ncurrent_task: build/3-implement\n---\n' > "$CWT/.ai/specs/code-slug/manifest.md"
  touch -d '3 hours ago' "$CWT/.ai/specs/code-slug/manifest.md"
  printf 'vue-tsc --build\nKilled\nexit 137\n' > "$BATS_TEST_TMPDIR/oom-pane"
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" CB_PANE_CMD="cat '$BATS_TEST_TMPDIR/oom-pane'" \
    run classify_code "$CTD"
  [ "$output" = "failed" ]
  [ -f "$CTD/oom-detected" ]
}

@test "cb-watch event line carries the oom tag" {
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  mkdir -p "$CB_HOME/tasks/oomy" "$CB_HOME/beacons" "$CB_HOME/logs"
  CWT="$BATS_TEST_TMPDIR/wt-oomy"; mkdir -p "$CWT/.ai/specs/oomy"
  printf 'kind=code\nworktree=%s\njira=\nsession=oomy\ntarget=ultron\n' "$CWT" > "$CB_HOME/tasks/oomy/meta"
  printf -- '---\ncurrent_task: build/3-implement\n---\n' > "$CWT/.ai/specs/oomy/manifest.md"
  touch -d '3 hours ago' "$CWT/.ai/specs/oomy/manifest.md"
  printf 'dotnet build\nKilled\n' > "$BATS_TEST_TMPDIR/oom-pane2"
  export CB_SESSION_LIST_CMD="printf 'oomy\n'"
  export CB_PANE_CMD="cat '$BATS_TEST_TMPDIR/oom-pane2'"
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  grep -q 'oomy failed.*oom' "$CB_HOME/logs/events"
}
