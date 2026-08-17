setup() { export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks/probe-x"; }

@test "scaffolds brief with frontmatter + sections" {
  run scripts/cerebro/cb-brief --research probe-x
  [ -f "$CB_HOME/tasks/probe-x/brief.md" ]
  grep -q '^type: research' "$CB_HOME/tasks/probe-x/brief.md"
  grep -q '^# Context' "$CB_HOME/tasks/probe-x/brief.md"
}

# --- R9: the sparse status-beacon contract the agent needs to emit ---
@test "--research brief frontmatter carries the beacon path (so the agent knows where to append)" {
  run scripts/cerebro/cb-brief --research probe-x
  [ "$status" -eq 0 ]
  grep -q "^beacon: $CB_HOME/tasks/probe-x/status" "$CB_HOME/tasks/probe-x/brief.md"
}
@test "--research brief instructs the agent to append the sparse beacon incl. paused:" {
  run scripts/cerebro/cb-brief --research probe-x
  local b="$CB_HOME/tasks/probe-x/brief.md"
  grep -qi 'beacon' "$b"                       # a Status beacon instruction section exists
  grep -q 'paused:' "$b"                        # the paused convention (R6) is documented for the agent
}

# --- step 8 brief-contract: R8 isolation + R11 same-obstacle-twice ---
@test "--research brief carries the read-only worktree-isolation self-check (R8)" {
  run scripts/cerebro/cb-brief --research probe-x
  local b="$CB_HOME/tasks/probe-x/brief.md"
  grep -q 'git rev-parse --show-toplevel' "$b"   # the pwd/top-level self-check
  grep -qi 'read-only' "$b"                        # never write into a shared checkout
}
@test "--research brief carries the same-obstacle-twice rule (R11)" {
  run scripts/cerebro/cb-brief --research probe-x
  grep -qi 'same obstacle' "$CB_HOME/tasks/probe-x/brief.md"
}

@test "--code context.md carries the worktree-isolation self-check + primary-checkout stop (R8)" {
  local wt="$BATS_TEST_TMPDIR/wt-r8"; mkdir -p "$wt"; git -C "$wt" init -q
  run scripts/cerebro/cb-brief --code fix-x --target ultron --jira EJA-1 --worktree "$wt"
  [ "$status" -eq 0 ]
  local c="$wt/.ai/specs/fix-x/context.md"
  grep -q 'git rev-parse --show-toplevel' "$c"
  grep -q 'blocked: launched in primary checkout' "$c"
}
@test "--code context.md carries same-obstacle-twice (R11) + the paused/blocked status vocabulary (R9)" {
  local wt="$BATS_TEST_TMPDIR/wt-r11"; mkdir -p "$wt"; git -C "$wt" init -q
  run scripts/cerebro/cb-brief --code fix-x --target ultron --worktree "$wt"
  local c="$wt/.ai/specs/fix-x/context.md"
  grep -qi 'same obstacle' "$c"
  grep -q 'paused:' "$c"
  grep -q 'blocked:' "$c"
}

@test "--code context.md teaches the manifest gate: field, not the current_task overwrite" {
  local wt="$BATS_TEST_TMPDIR/wt-gate"; mkdir -p "$wt"; git -C "$wt" init -q
  run scripts/cerebro/cb-brief --code fix-x --target ultron --worktree "$wt"
  local c="$wt/.ai/specs/fix-x/context.md"
  grep -q 'gate_question' "$c"
  grep -q 'gate_options' "$c"
  grep -q 'gate_since' "$c"      # the pause clock — mtime resets, this does not
  # the deprecated convention must not come back: it overwrote the resume pointer
  ! grep -q 'awaiting-approval' "$c"
}

@test "--research with no value gives usage exit 2, not unbound-variable error" {
  run scripts/cerebro/cb-brief --research
  [ "$status" -eq 2 ]
}

@test "--target with no value gives usage exit 2, not unbound-variable error" {
  run scripts/cerebro/cb-brief --research probe-x --target
  [ "$status" -eq 2 ]
}

@test "unknown arg errors exit 2, not a silent shift" {
  run scripts/cerebro/cb-brief --research probe-x --bogus
  [ "$status" -eq 2 ]
}

# --- cb-brief --code (T19): context.md into the conductor run dir ---

@test "--code writes context.md under <worktree>/.ai/specs/<slug>/ with jira + meta" {
  local wt="$BATS_TEST_TMPDIR/wt-code"; mkdir -p "$wt"
  run scripts/cerebro/cb-brief --code fix-x --target ultron --jira EJA-123 --worktree "$wt"
  [ "$status" -eq 0 ]
  [ -f "$wt/.ai/specs/fix-x/context.md" ]
  grep -q '^jira: EJA-123' "$wt/.ai/specs/fix-x/context.md"
  grep -q '^type: code' "$wt/.ai/specs/fix-x/context.md"
  grep -q '^# Objective' "$wt/.ai/specs/fix-x/context.md"
  grep -q '^# Scope' "$wt/.ai/specs/fix-x/context.md"
  # task-dir meta for the classifier
  grep -q '^kind=code' "$CB_HOME/tasks/fix-x/meta"
  grep -q "^worktree=$wt" "$CB_HOME/tasks/fix-x/meta"
  grep -q '^jira=EJA-123' "$CB_HOME/tasks/fix-x/meta"
  grep -q '^session=fix-x' "$CB_HOME/tasks/fix-x/meta"
}

@test "--code refuses when the worktree does not exist (cb-start --code runs first)" {
  run scripts/cerebro/cb-brief --code fix-x --target ultron --worktree "$BATS_TEST_TMPDIR/absent"
  [ "$status" -ne 0 ]
  [[ "$output" == *"worktree"* ]]
  [ ! -d "$BATS_TEST_TMPDIR/absent" ]
}

@test "--code requires --target (no blank meta target)" {
  local wt="$BATS_TEST_TMPDIR/wt-nt"; mkdir -p "$wt"
  run scripts/cerebro/cb-brief --code fix-x --worktree "$wt"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--target"* ]]
  [ ! -f "$CB_HOME/tasks/fix-x/meta" ]
}

@test "--code default worktree path is ~/code/worktrees/<slug>" {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/code/worktrees/fix-y"
  run scripts/cerebro/cb-brief --code fix-y --target ultron --jira EJA-9
  [ "$status" -eq 0 ]
  [ -f "$HOME/code/worktrees/fix-y/.ai/specs/fix-y/context.md" ]
}

@test "--code does not touch the vault (no dev-item writes — dispatch skill's job)" {
  local wt="$BATS_TEST_TMPDIR/wt-vault"; mkdir -p "$wt"
  run scripts/cerebro/cb-brief --code fix-z --target ultron --worktree "$wt"
  [ "$status" -eq 0 ]
  # nothing written outside the worktree run dir + the task dir
  [ ! -e "$BATS_TEST_TMPDIR/02 Areas" ]
}

# --- T39: research frontmatter worktree: records the RESOLVED workdir ---

@test "--research --target with a registry checkout records that checkout, not the scratch path" {
  export CB_REGISTRY="$BATS_TEST_TMPDIR/projects.md"
  printf -- '- project: cerebro\n  checkout: %s/the-checkout\n  delivery: research-only\n' "$BATS_TEST_TMPDIR" > "$CB_REGISTRY"
  run scripts/cerebro/cb-brief --research probe-x --target cerebro
  [ "$status" -eq 0 ]
  grep -q "^worktree: $BATS_TEST_TMPDIR/the-checkout" "$CB_HOME/tasks/probe-x/brief.md"
}

@test "--research without --target still records the scratch dir" {
  run scripts/cerebro/cb-brief --research probe-x
  grep -q "^worktree: $CB_HOME/worktrees/probe-x" "$CB_HOME/tasks/probe-x/brief.md"
}

@test "--research path unchanged by the --code branch" {
  run scripts/cerebro/cb-brief --research probe-x
  [ "$status" -eq 0 ]
  [ -f "$CB_HOME/tasks/probe-x/brief.md" ]
  grep -q '^type: research' "$CB_HOME/tasks/probe-x/brief.md"
  # research writes its OWN meta now (see the deliverable= block below); what
  # must never happen is the code meta leaking into the research lane.
  ! grep -q '^kind=code' "$CB_HOME/tasks/probe-x/meta"
}

@test "--target resolves the registry checkout into worktree: frontmatter" {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"
  export CB_REGISTRY="$BATS_TEST_TMPDIR/projects.md"
  printf -- '- project: demo\n  checkout: %s\n  delivery: research-only\n' "$BATS_TEST_TMPDIR/demo-co" > "$CB_REGISTRY"
  run scripts/cerebro/cb-brief --research probe-t --target demo
  [ "$status" -eq 0 ]
  grep -q "worktree: $BATS_TEST_TMPDIR/demo-co" "$CB_HOME/tasks/probe-t/brief.md"
  grep -q "report: $CB_HOME/tasks/probe-t/report.md" "$CB_HOME/tasks/probe-t/brief.md"
}

@test "no --target keeps the scratch worktree + still stamps report: path" {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"
  run scripts/cerebro/cb-brief --research probe-s
  [ "$status" -eq 0 ]
  grep -q "worktree: $CB_HOME/worktrees/probe-s" "$CB_HOME/tasks/probe-s/brief.md"
  grep -q "report: $CB_HOME/tasks/probe-s/report.md" "$CB_HOME/tasks/probe-s/brief.md"
}

# --- R14 (audit): keep context.md out of git's view so cb-cleanup can reap ---

@test "--code excludes .ai/specs/<slug>/ via the worktree info/exclude (unblocks reap)" {
  local wt="$BATS_TEST_TMPDIR/wt-git"; mkdir -p "$wt"; git -C "$wt" init -q
  run scripts/cerebro/cb-brief --code fix-r14 --target ultron --jira EJA-1 --worktree "$wt"
  [ "$status" -eq 0 ]
  [ -f "$wt/.ai/specs/fix-r14/context.md" ]
  grep -qxF ".ai/specs/fix-r14/" "$wt/.git/info/exclude"       # exclude entry written
  [ -z "$(git -C "$wt" status --porcelain)" ]                  # context.md no longer untracked → reap won't refuse
}

@test "--code exclude is idempotent across a re-brief (no duplicate line)" {
  local wt="$BATS_TEST_TMPDIR/wt-git2"; mkdir -p "$wt"; git -C "$wt" init -q
  scripts/cerebro/cb-brief --code fix-idem --target ultron --worktree "$wt"
  scripts/cerebro/cb-brief --code fix-idem --target ultron --worktree "$wt"
  [ "$(grep -cxF ".ai/specs/fix-idem/" "$wt/.git/info/exclude")" -eq 1 ]
}

# --- P1: the declared-gate verb has to reach the worker's context ---
@test "--research brief teaches cb-ask with its absolute path" {
  run scripts/cerebro/cb-brief --research probe-x
  local b="$CB_HOME/tasks/probe-x/brief.md"
  grep -q 'cb-ask' "$b"
  grep -q "$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/cb-ask" "$b"
  grep -qi 'options' "$b"
}
@test "--code context.md teaches cb-ask too" {
  local wt="$BATS_TEST_TMPDIR/wt-ask"; mkdir -p "$wt"; git -C "$wt" init -q
  run scripts/cerebro/cb-brief --code fix-a --target ultron --jira EJA-2 --worktree "$wt"
  [ "$status" -eq 0 ]
  grep -q 'cb-ask' "$wt/.ai/specs/fix-a/context.md"
}

# --- T39: --code resolves the worktree from the target's row --------------------
# cb-brief defaulted to $HOME/code/worktrees/<slug> while cb-start (since T39)
# creates a vault-row worktree under the row's own root. Left unfixed, the
# dispatch path breaks in the middle: cb-start puts the worktree in
# .claude/worktrees, then cb-brief looks under ~/code/worktrees, finds nothing,
# and exits 1 — so the brief never lands.
@test "T39: --code finds a vault-row worktree under the row's worktree_root" {
  export HOME="$BATS_TEST_TMPDIR/home"
  export CB_REGISTRY="$BATS_TEST_TMPDIR/projects.md"
  printf -- '- project: cerebro\n  checkout: %s/vault\n  delivery: local-only\n  worktree_root: %s/vault/.claude/worktrees\n' "$HOME" "$HOME" > "$CB_REGISTRY"
  local wt="$HOME/vault/.claude/worktrees/vault-b"
  mkdir -p "$wt" "$CB_HOME/tasks/vault-b"
  run scripts/cerebro/cb-brief --code vault-b --target cerebro
  [ "$status" -eq 0 ]
  [ -f "$wt/.ai/specs/vault-b/context.md" ]
}

@test "T39: --code still defaults to ~/code/worktrees for a row without a root" {
  export HOME="$BATS_TEST_TMPDIR/home"
  export CB_REGISTRY="$BATS_TEST_TMPDIR/projects.md"
  printf -- '- project: ultron\n  checkout: %s/co\n  delivery: bitbucket-pr\n' "$HOME" > "$CB_REGISTRY"
  local wt="$HOME/code/worktrees/fix-b"
  mkdir -p "$wt" "$CB_HOME/tasks/fix-b"
  run scripts/cerebro/cb-brief --code fix-b --target ultron
  [ "$status" -eq 0 ]
  [ -f "$wt/.ai/specs/fix-b/context.md" ]
}

# --- the supersede trigger (2026-08-03) --------------------------------------
# The mechanism (cb-ask --supersedes) is worthless if no agent is told to use it.
# Three duplicate question pairs were live on the board the day this shipped,
# each a sharpened restatement sitting next to the question it restated.
@test "--research brief tells the agent to supersede a question it re-asks" {
  run scripts/cerebro/cb-brief --research probe-x
  local b="$CB_HOME/tasks/probe-x/brief.md"
  grep -q -- '--supersedes' "$b"
  grep -qi 'both questions sit on the board' "$b"
}

@test "--code context.md tells the agent to supersede a question it re-asks" {
  local wt="$BATS_TEST_TMPDIR/wt-sup"; mkdir -p "$wt"; git -C "$wt" init -q
  run scripts/cerebro/cb-brief --code fix-sup --target ultron --worktree "$wt"
  [ "$status" -eq 0 ]
  local c="$wt/.ai/specs/fix-sup/context.md"
  grep -q -- '--supersedes' "$c"
  grep -qi 'both questions sit on the board' "$c"
}

# CB_SPECS_ROOT was honoured by conductor.sh's resolve_run, cb-start's adopt
# marker and cb-resume, but NOT by cb-brief — the one writer. Setting it would
# have put context.md where nobody reads it: cb-resume would see a permanently
# missing context.md, re-brief every resume, and splice into a dead file.
@test "code: CB_SPECS_ROOT overrides the .ai/specs default for context.md" {
  local wt="$BATS_TEST_TMPDIR/wt-specsroot"; mkdir -p "$wt"
  CB_SPECS_ROOT="custom/specs" run scripts/cerebro/cb-brief --code sr-slug \
    --target ultron --worktree "$wt"
  [ "$status" -eq 0 ]
  [ -f "$wt/custom/specs/sr-slug/context.md" ]
  [ ! -e "$wt/.ai/specs/sr-slug/context.md" ]
}

# --- §1: the COMPUTED deliverable path, stamped into task meta at scaffold time
# The destination used to come from the agent's own `deliverable:` in its report,
# so an agent that wrote a wrong path (or none) stranded its finding for good.
# It is now derived from local-date + kind + slug before the agent ever runs.

@test "--code meta carries the computed deliverable path" {
  local wt="$BATS_TEST_TMPDIR/wt-deliv"; mkdir -p "$wt"
  run scripts/cerebro/cb-brief --code fix-d --target ultron --jira EJA-7 --worktree "$wt"
  [ "$status" -eq 0 ]
  grep -qx "deliverable=00 Inbox/$(TZ=America/Denver date +%F)-code-fix-d.md" "$CB_HOME/tasks/fix-d/meta"
}

@test "--code meta keeps every pre-existing field alongside deliverable=" {
  local wt="$BATS_TEST_TMPDIR/wt-deliv2"; mkdir -p "$wt"
  run scripts/cerebro/cb-brief --code fix-e --target ultron --jira EJA-8 --worktree "$wt"
  local m="$CB_HOME/tasks/fix-e/meta"
  grep -q '^kind=code' "$m"
  grep -q "^worktree=$wt" "$m"
  grep -q '^jira=EJA-8' "$m"
  grep -q '^session=fix-e' "$m"
  grep -q '^target=ultron' "$m"
}

@test "--research writes a meta file: kind=research, session, computed deliverable" {
  run scripts/cerebro/cb-brief --research probe-x
  [ "$status" -eq 0 ]
  local m="$CB_HOME/tasks/probe-x/meta"
  [ -f "$m" ]
  grep -qx 'kind=research' "$m"
  grep -qx 'session=probe-x' "$m"
  grep -qx "deliverable=00 Inbox/$(TZ=America/Denver date +%F)-research-probe-x.md" "$m"
}

@test "--research meta does not disturb the kind=code classifier gate" {
  run scripts/cerebro/cb-brief --research probe-x
  # classify() routes anything that is not kind=code to classify_research —
  # a `kind=research` line must not match that guard.
  ! grep -q '^kind=code$' "$CB_HOME/tasks/probe-x/meta"
}

@test "--research brief frontmatter shows the agent its own computed destination" {
  run scripts/cerebro/cb-brief --research probe-x
  grep -qx "deliverable: 00 Inbox/$(TZ=America/Denver date +%F)-research-probe-x.md" \
    "$CB_HOME/tasks/probe-x/brief.md"
}

# §1 is explicit that the `# Deliverable` body section stays as-is — the
# frontmatter field is informational and replaces nothing.
@test "--research brief keeps its # Deliverable body section" {
  run scripts/cerebro/cb-brief --research probe-x
  grep -q '^# Deliverable' "$CB_HOME/tasks/probe-x/brief.md"
  grep -qx 'report.md' "$CB_HOME/tasks/probe-x/brief.md"
}

# --- §5: `cb-brief --ops` -----------------------------------------------------
# The ops lane hand-wrote its briefs for months, and a hand-written brief loses
# the frontmatter: `cerebro-charter-review`, `env-error-monitor-tick` and
# `failed-qe-triage-kyle-batch` all begin at `# Objective` with none at all, so
# nothing downstream can read a clearance, a beacon or a destination off them.
# The frontmatter block is the part that must not be lost.

@test "--ops writes the full frontmatter block (all eight fields)" {
  run scripts/cerebro/cb-brief --ops sweep-x
  [ "$status" -eq 0 ]
  local b="$CB_HOME/tasks/sweep-x/brief.md"
  grep -qx 'task: sweep-x' "$b"
  grep -qx 'type: ops' "$b"
  grep -qx 'clearance: standard' "$b"
  grep -qx 'status: running' "$b"
  grep -q '^worktree: ' "$b"
  grep -qx "report: $CB_HOME/tasks/sweep-x/report.md" "$b"
  grep -qx "beacon: $CB_HOME/tasks/sweep-x/status" "$b"
  grep -q '^started: ' "$b"
  grep -qx "deliverable: 00 Inbox/$(TZ=America/Denver date +%F)-ops-sweep-x.md" "$b"
}

@test "--ops meta: kind=ops, session, the computed deliverable" {
  run scripts/cerebro/cb-brief --ops sweep-m
  [ "$status" -eq 0 ]
  local m="$CB_HOME/tasks/sweep-m/meta"
  grep -qx 'kind=ops' "$m"
  grep -qx 'session=sweep-m' "$m"
  grep -qx "deliverable=00 Inbox/$(TZ=America/Denver date +%F)-ops-sweep-m.md" "$m"
  # classify() routes anything that is not kind=code to classify_research
  ! grep -q '^kind=code$' "$m"
}

# The failure this catches is a copy-paste of the research contract into the ops
# body: an ops X-Man exists to WRITE, so a brief telling it it is read-only
# everywhere contradicts the launch prompt cb-start wraps around it.
@test "--ops carries the write-scope contract, NOT the read-only research one" {
  run scripts/cerebro/cb-brief --ops sweep-c
  local b="$CB_HOME/tasks/sweep-c/brief.md"
  grep -q '^# Write scope' "$b"
  grep -q '^# Approved outward writes' "$b"
  grep -q '^# Landing' "$b"
  ! grep -qi 'read-only everywhere' "$b"
}

# cb-start:539 reads `# Landing` to decide whether the agent may commit; an
# unfilled scaffold must fall through to the no-commit default, so the
# placeholder must not contain the words that grep matches.
@test "--ops Landing placeholder does not accidentally license a commit" {
  run scripts/cerebro/cb-brief --ops sweep-l
  local landing; landing="$(sed -n '/^# Landing/,/^# /p' "$CB_HOME/tasks/sweep-l/brief.md")"
  ! printf '%s' "$landing" | grep -qiE 'commit and push|commit \+ push|push to'
  ! printf '%s' "$landing" | grep -qiE 'commit locally|do not push|local'
}

# cb-start --ops defaults its workdir to the vault; a brief recording the
# research lane's scratch dir would tell the agent it is somewhere it is not.
@test "--ops workdir defaults to the vault, and --target still wins" {
  export CB_VAULT="$BATS_TEST_TMPDIR/thevault"
  run scripts/cerebro/cb-brief --ops sweep-w
  grep -qx "worktree: $CB_VAULT" "$CB_HOME/tasks/sweep-w/brief.md"
  export CB_REGISTRY="$BATS_TEST_TMPDIR/projects.md"
  printf -- '- project: demo\n  checkout: %s\n  delivery: research-only\n' "$BATS_TEST_TMPDIR/demo-co" > "$CB_REGISTRY"
  run scripts/cerebro/cb-brief --ops sweep-t --target demo
  grep -qx "worktree: $BATS_TEST_TMPDIR/demo-co" "$CB_HOME/tasks/sweep-t/brief.md"
}

@test "--ops with no value gives usage exit 2, not unbound-variable error" {
  run scripts/cerebro/cb-brief --ops
  [ "$status" -eq 2 ]
}

@test "--ops does not disturb the research lane's own shape" {
  run scripts/cerebro/cb-brief --research probe-x
  [ "$status" -eq 0 ]
  grep -qx 'type: research' "$CB_HOME/tasks/probe-x/brief.md"
  grep -qx 'kind=research' "$CB_HOME/tasks/probe-x/meta"
  ! grep -q '^# Write scope' "$CB_HOME/tasks/probe-x/brief.md"
}

@test "deliverable path is repo-relative under 00 Inbox/ in both lanes" {
  local wt="$BATS_TEST_TMPDIR/wt-rel"; mkdir -p "$wt"
  scripts/cerebro/cb-brief --code fix-rel --target ultron --worktree "$wt"
  scripts/cerebro/cb-brief --research probe-rel
  grep -q '^deliverable=00 Inbox/' "$CB_HOME/tasks/fix-rel/meta"
  grep -q '^deliverable=00 Inbox/' "$CB_HOME/tasks/probe-rel/meta"
  ! grep -q '^deliverable=/' "$CB_HOME/tasks/fix-rel/meta"
  ! grep -q '^deliverable=/' "$CB_HOME/tasks/probe-rel/meta"
}
