---
name: board
description: Render and surface the Cerebro task board — cost-ordered status of every research task (needs-you first, then running, then failed), plus the stuck-agent escalation ladder. Triggered by "show the board", "where are we", "board", "what needs my review", "it's stuck", "<slug> is wedged".
allowed-tools: Bash, Read
---

# Board — Cerebro task status

Renders the current state of every Cerebro task into `board.md` at the vault root, then surfaces the queue that actually needs Kyle. Full model: `99 Meta/Cerebro-spec.md` §8.

## Steps

### 1. Drain the wake queue
```bash
scripts/cerebro/cb-wake --drain
```
R4. Escalations are keystrokes into the coordinator pane, and that pane dies —
`cerebro.timer` recreates it every ~2 min, so an event can fire, land in
`logs/events`, and have nothing ever make a coordinator read it. Every
escalation is recorded before its suppression marker advances, and **this drain
is the acknowledgement** — an entry lives until it is read here.

Run it **first**, before rendering. Anything it prints is an escalation that was
never acknowledged: surface those alongside ⚠ Needs you in step 3, with the
timestamp, since they are by definition stale. Silence is the normal case.

The drain has to happen in *this* turn, as a tool call, so the output lands in
your context. `cb-ensure-session` only `--peek`s at session start — that runs in
the pane's init shell before the coordinator exists, where a consuming drain
would delete the queue into scrollback nobody reads.

### 2. Render
```bash
scripts/cerebro/cb-board
```
This reads every task under `~/.cerebro/tasks/` (via `CB_HOME`), classifies each (`scripts/cerebro/lib/classify.sh`), and writes `board.md` to the vault root (`CB_VAULT`, default `$HOME/vault`) via an atomic write.

### 3. Read and surface
Read the freshly written `board.md`. Lead with **⚠ Needs you** — that's the cost-ordered top of the board (`ready-for-review` tasks only), the one section that requires Kyle's attention. **✗ Failed** (including hung tasks) is a separate trailing FYI section, not needs-you — mention its count after Running, but don't imply failed tasks are top-of-queue or need immediate review.

### 4. Report
Keep it scannable: needs-you items first (with a one-line reason if the report/status makes it obvious), then a one-line count for running, then a one-line count for failed (FYI). If needs-you is empty, say so plainly ("board clear — nothing needs review").

## When Kyle says "it's stuck" — the escalation ladder

Cerebro's only automated remediation is the spend-wedge resume. A conductor that
is looping or confused classifies as `running` (live session, fresh manifest) and
nothing happens to it. This is the procedure for that case.

**This ladder is not automated, and should not be.** Deciding an agent is
confused is a judgement call, not a mechanically verifiable signal — it fails the
admission rule in `99 Meta/Cerebro-spec.md` §8.3, so it lives here as a documented
procedure rather than in `cb-watch`. Kyle (or the coordinator, on his say-so)
walks it. Run `scripts/cerebro/cb-stuck <slug>` first — it gathers the evidence
each rung needs and prints this ladder, read-only.

1. **Peek the pane.** `scripts/cerebro/cb-peek <slug>`. Read what it is actually
   doing before touching anything.
2. **Waiting on a question the brief already answers?** Answer it in one line:
   `scripts/cerebro/cb-send <slug> "<the answer>"`.
3. **Confused or looping?** Interrupt with Escape, then redirect with one
   corrective line. Not a relaunch — the context is still worth something.
4. **Genuinely wedged?** Exit the agent and relaunch on the same worktree with
   the same brief plus a "progress so far" note:
   `scripts/cerebro/cb-resume <slug> --target <project>`. The
   worktree and its commits persist, so this is cheap.
5. **Second relaunch fails?** Mark it `failed` and escalate with the evidence —
   what you saw at each rung, not just "it's stuck."

Two things worth keeping in mind before you start climbing:

> A low context reading is not wedging; modern harnesses auto-compact and keep going.

> Do not pkill-and-restart the watcher as a routine operation.

Rung 4 is a real relaunch and rung 5 changes state, so both are Kyle's call.
`cb-stuck` itself never sends keys, never kills a session and never relaunches —
it only shows you what the rungs need.

## Notes

- `cb-watch` also calls `cb-board` at the end of every tick, so `board.md` is normally already fresh; running it here just guarantees a current snapshot before you read it.
- `board.md` is the one sanctioned tracked projection of Cerebro runtime state into the vault — everything else (beacons, locks, PIDs) stays in `~/.cerebro/` and is never read directly by this skill.
