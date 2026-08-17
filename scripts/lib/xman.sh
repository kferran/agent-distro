# lib/xman.sh — WHICH X-Man is working a task, as durable state.
#
# It started as an easter egg in cb-start: a random roster name echoed at spawn
# (theme — Cerebro is the machine Professor X uses to locate mutants, then sends
# the X-Men). The name was never written down, so attaching to a session told
# Kyle nothing about who owned it, and a second report of the same task named a
# different mutant than the first. Kyle 2026-08-05: *"if I access a session the
# slug doesn't include the xman working the issue so it's not clear who is
# working what."*
#
# So the name is state now:
#   - persisted at $(cb_task_dir SLUG)/xman, one line
#   - derived from the SLUG, not from RANDOM, when that file is absent
#   - reused for the life of the task, across resume and re-dispatch
#
# STILL NOT AN IDENTIFIER, and that constraint is load-bearing. Sessions and
# windows keep bare slugs: 29 files resolve them by exact name (cb-send,
# cb-resume, cb-reap, cb-watch, cb-board, the dispatch skill's `tmux attach -t`,
# the hourly tick's `has-session -t`, the env-monitor's `list-windows | grep`),
# and any suffix breaks exact-match targeting. The name is therefore shown on the
# surfaces that take no part in lookups — the pane border and a dedicated
# session's status-right — and exposed as a `@xman` tmux option for tooling.
#
# Requires lib/paths.sh (cb_task_dir).

# The roster. Grown from 24 to 79 on 2026-08-05 (Kyle: *"feel free to increase
# the roster of available marvel characters"*) — with the pick now deterministic
# per slug, a short roster makes collisions systematic rather than occasional, so
# size is a real property. Deliberately X-adjacent rather than all-Marvel: every
# skill, brief and doc calls these things X-Men, so Iron Man in that line would
# read as a bug. The original 24 lead the array and are unchanged — they appear
# in today's logs and reports and have to keep resolving. Multi-word names are
# hyphenated or quoted so each stays one array element.
xman_roster=(Wolverine Storm Cyclops "Jean Grey" Nightcrawler Rogue Gambit Beast \
  Colossus Iceman Magneto Mystique Psylocke Bishop Jubilee "Emma Frost" \
  Kitty-Pryde Havok Banshee Forge Dazzler Cannonball "Professor X" Deadpool \
  Archangel Apocalypse Armor Anole Blink Boom-Boom Cable Caliban Cecilia-Reyes \
  Chamber Cypher Domino Dust Elixir Firestar Gentle Hellion Husk Juggernaut \
  Karma Legion Longshot Maggott Magik Marrow Mercury Moonstar Multiple-Man \
  Namor Northstar Omega-Sentinel Onslaught Pixie Polaris Prodigy Quicksilver \
  Rachel-Summers Rictor Rockslide Sabretooth Sage Shatterstar Siryn Strong-Guy \
  Sunfire Sunspot Surge Synch Thunderbird Toad Warlock Warpath Wolfsbane X-23 \
  Xorn)

# xman_index SLUG — roster index, derived from the slug's bytes.
#
# Deterministic is the whole point: the old `RANDOM % ${#roster[@]}` meant a
# re-report of one task could name a second mutant and contradict the first.
# LC_ALL=C around the ordinal so the same slug lands on the same name on every
# host regardless of locale. Rolling 31x hash, then an avalanche step — without
# the avalanche, slugs differing only in a trailing digit (eja-3880 / eja-3881)
# landed on ADJACENT roster indices, which reads as a pattern on a board full of
# eja-38xx tasks.
xman_index() {
  local s="$1" i h=0 c
  local LC_ALL=C
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    h=$(( (h * 31 + $(printf '%d' "'$c") ) % 1000003 ))
  done
  h=$(( h ^ (h >> 7) ))
  h=$(( (h * 2246822519) % 1000003 ))
  h=$(( h ^ (h >> 11) ))
  printf '%d' $(( h % ${#xman_roster[@]} ))
}

# xman_read SLUG — the PERSISTED name, or empty. Pure read: never derives, never
# writes. Readers (cb-board, cb-resume) use this so a task that ran before names
# were persisted renders no name rather than a freshly-invented one that
# contradicts what was announced in chat at its spawn.
xman_read() {
  local f; f="$(cb_task_dir "$1")/xman"
  [ -f "$f" ] || return 0
  head -n1 "$f" 2>/dev/null | tr -d '\n'
}

# xman_name SLUG — resolve AND persist. Precedence:
#   1. an existing xman file — a task keeps ONE identity for its whole life, so a
#      resume or re-dispatch never re-picks (this is why the file is checked
#      before CB_XMAN_PICK: a pinned env var must not rewrite a live task's name)
#   2. CB_XMAN_PICK — pins the choice for tests
#   3. the slug hash
# Best-effort on the write: a task dir we cannot write to still yields a name.
xman_name() {
  local slug="$1" name f
  name="$(xman_read "$slug")"
  if [ -z "$name" ]; then
    name="${CB_XMAN_PICK:-${xman_roster[$(xman_index "$slug")]}}"
    f="$(cb_task_dir "$slug")/xman"
    mkdir -p "$(dirname "$f")" 2>/dev/null || true
    printf '%s\n' "$name" > "$f" 2>/dev/null || true
  fi
  printf '%s' "$name"
}

# xman_tmux_mark TARGET NAME [OWN_SESSION] — show the name on an attached
# session WITHOUT renaming anything.
#   TARGET      a tmux target — "<slug>" for a standalone --code session,
#               "cb:<slug>" for an --ops/--research window in the shared session
#   OWN_SESSION non-empty when TARGET's session belongs to this task alone, so
#               session-scoped options are safe. The `cb` session is SHARED —
#               setting status-right there would repaint the chrome of every
#               running task, which is exactly the "don't disturb what's already
#               running" line.
#
# The name is baked into pane-border-format as a LITERAL, not as `#{@xman}`: the
# display must not depend on how tmux resolves a user option through the
# option hierarchy. `@xman` is set separately, for tooling that wants to read it
# off tmux instead of parsing a title.
#
# pane-border-status / pane-border-format are WINDOW options in tmux, so setting
# them touches only this task's window even inside the shared `cb` session.
#
# `@xman` goes on the WINDOW (`-w`), and only additionally on the session when the
# session is the task's own. Measured 2026-08-05: a bare `set-option -t cb:<slug>`
# sets a SESSION option, so every ops spawn was overwriting one shared `@xman` on
# `cb` — last writer wins, and no per-task value survived. Read it back with
# `tmux show-options -w -t cb:<slug> @xman`.
#
# EVERY command is individually `|| true` and the function always returns 0.
# cb-start runs under `set -euo pipefail` and calls this AFTER a successful
# launch; a nonzero here would exit with a live agent already spawned, and
# cb-resume maps any nonzero cb-start status to "adopt failed — no harness,
# nothing briefed or sent". A cosmetic tmux failure must never manufacture that.
# Skipped entirely under a CB_TMUX_CMD override so tests never touch real tmux.
xman_tmux_mark() {
  local target="$1" name="$2" own="${3:-}"
  [ -z "${CB_TMUX_CMD:-}" ] || return 0
  [ -n "$target" ] && [ -n "$name" ] || return 0
  command -v tmux >/dev/null 2>&1 || return 0
  tmux set-option -w -t "$target" @xman "$name" >/dev/null 2>&1 || true
  tmux set-option -w -t "$target" pane-border-status top >/dev/null 2>&1 || true
  tmux set-option -w -t "$target" pane-border-format \
    " #[bold]🦸 $name#[default] · #{window_name} " >/dev/null 2>&1 || true
  # A nicety, and MEASURED to be transient. A real Claude harness emits its own
  # OSC title, so pane_title is overwritten with the agent's status line within
  # seconds — checked 2026-08-05 against two live windows, both reading
  # "⠂ <task headline>" while their pane-border-format still held the name. So
  # this survives only on a non-agent pane, and the border format (a tmux option,
  # which the app cannot touch) is the real surface. Kept because it costs one
  # line and is correct at t=0; never rely on it.
  tmux select-pane -t "$target" -T "🦸 $name · ${target#cb:}" >/dev/null 2>&1 || true
  if [ -n "$own" ]; then
    tmux set-option -t "$target" @xman "$name" >/dev/null 2>&1 || true
    tmux set-option -t "$target" status-right \
      " #[bold]🦸 $name#[default] · %H:%M " >/dev/null 2>&1 || true
  fi
  return 0
}
