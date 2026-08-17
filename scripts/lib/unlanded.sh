# unlanded.sh — decide whether a finished X-Man report's finding is represented
# in the vault, and keep a register of the ones that are not.
#
# WHY THIS IS NOT A GREP. The prose sweep this replaces decided landedness by
# grepping the vault for the task slug and testing whether any match had an
# mtime >= the report's. That proxy failed in both directions, and both failures
# were reproduced against the live corpus on 2026-07-31:
#
#   * Every one of the 7 vault files naming `cerebro-charter-review` is a process
#     log (board.md, three ratify worklists, scheduled-tasks-log, Daily/,
#     reaped-sessions). Six were newer than its report, so the slug-grep returned
#     LANDED — certified by the very log entry recording that it is BLOCKED. Its
#     actual 48KB deliverable never names its own slug, so the grep could not see
#     the one file that mattered.
#   * `delivery-comparison-refresh-0729` genuinely landed in
#     `02 Areas/Org-Performance/metrics/` — outside the scan's root list, so
#     widening the exclusion list without widening the path would have turned a
#     real landing into a false positive.
#
# The response had been an exclusion list, five surfaces long and growing. That
# treats the symptom. A slug mention was never evidence in the first place, so
# this decides by DECLARATION and CONTENT and greps for nothing. With no
# slug-grep there is no process-log class to exclude and no root list to widen —
# defects (1) and (2) are the same defect, and both dissolve.
#
# THE RULE, in precedence order. Each stage is decisive; there is no fallthrough
# to a heuristic.
#   1. terminal?      report `status:` in complete|done|partial, else `skip`
#   2. clearance      DECLARED and not `standard` (`confidential`, or a value
#                     nobody recognises) -> `blocked-ingest`, regardless of what
#                     is in the vault. An ABSENT clearance falls through and is
#                     read as `standard` — see the stage 2 comment for why that
#                     inverted on 2026-08-14.
#   3. cb-ingest blk  declared -> cb-ingest's own content test (cb-ingest:105-112)
#   4. deliverable:   declared -> every path must EXIST. No mtime test: the
#                     ops/research lane writes its deliverable BEFORE report.md
#                     (measured: 11 of 15 resolvable cases older, the 4 newer all
#                     from later hand-edits), so `mtime >= report.md` can never
#                     pass and would mark every self-filing task unlanded forever.
#   5. otherwise      `unknown` — no declared destination. Say so and stop.
#                     Guessing a destination is worse than admitting we cannot.
#
# WHAT IT WILL NOT DO. It does not write the vault, does not ingest, does not
# guess a destination, and does not commit. Detecting an unlanded report is not
# permission to land it — the destination is a judgment call and stays with
# /ingest, exactly as the operating contract reserves it.

: "${CB_HOME:=$HOME/.cerebro}"

# ul_report_field FILE NAME — a frontmatter field, from the FIRST `---` block
# only. A body line of the same name is not frontmatter and must not win.
ul_report_field() {
  awk -v want="$2" '
    /^---[[:space:]]*$/ { n++; if (n==2) exit; next }
    n==1 {
      if ($0 ~ "^" want ":") {
        sub("^" want ":[[:space:]]*", ""); sub(/[[:space:]]*$/, ""); sub(/\r$/, "")
        print; exit
      }
    }
  ' "$1" 2>/dev/null
}

# ul_clearance BRIEF — the brief's clearance, empty when absent or unreadable.
# Empty is returned as empty and is deliberately NOT defaulted here: what an
# absent field MEANS is a policy call, and it belongs to the caller. Both
# callers now read it as `standard` (ul_classify's stage 2 below, and
# cb-land:155), but they say so themselves — keeping the default out of this
# function is what let that policy change per caller instead of silently for
# everything that reads a clearance.
ul_clearance() { [ -f "$1" ] && ul_report_field "$1" clearance; }

# ul_paths DECLARED VAULT — the declared deliverable as zero or more repo-
# relative paths, one per line. Four shapes appear in the live corpus:
#   `00 Inbox/x.md`                      -> as-is
#   `/home/kyle/vault/00 Inbox/x.md`     -> strip the absolute vault prefix
#   `a.md, b.md`                         -> one path per line, all required
#   `01 Projects/…/  (three files — …)`  -> prose; emits `!prose`, never a guess
#   `02 Areas/…/log.md (trend line, <ts>)` -> path + human locator; resolved, but
#      ONLY because the text before the parenthetical is an existing vault file.
#
# WHY THE LOCATOR SHAPE IS NOT A RELAXATION (added 2026-08-05). Any `(` used to
# force `!prose`, so a report declaring a real file plus a "which line" locator
# was classified `unknown — no declared destination`. The env-error-monitor
# declares exactly that shape on EVERY run, and its deliverable is a trend line
# it has already written itself — so the register was set to cry wolf hourly on
# the one task class that reliably lands its own output. The gate here is
# file EXISTENCE, not a parse guess: if stripping the trailing parenthetical
# does not leave a path that is actually on disk, it still emits `!prose`. That
# is evidence, not a loosened spec. (A report SHOULD declare a bare path — the
# runbook is the place to say so — but the parser cannot retrofit past reports.)
ul_paths() {
  local declared="$1" vault="${2:-$HOME/vault}" stripped
  case "$declared" in ''|none|None|NONE|-) return 0;; esac
  case "$declared" in
    *'('*)
      # Try path-plus-locator before falling back to prose.
      stripped="${declared%%(*}"
      stripped="${stripped#"${stripped%%[![:space:]]*}"}"
      stripped="${stripped%"${stripped##*[![:space:]]}"}"
      stripped="${stripped#\"}"; stripped="${stripped%\"}"
      stripped="${stripped#"$vault"/}"; stripped="${stripped#/home/kyle/vault/}"
      case "$stripped" in *','*|'') : ;; *)
        if [ -f "$vault/$stripped" ]; then printf '%s\n' "$stripped"; return 0; fi ;;
      esac
      printf '!prose\n'; return 0;;
  esac
  case "$declared" in *' — '*|*' -- '*) printf '!prose\n'; return 0;; esac
  printf '%s\n' "$declared" | tr ',' '\n' | while IFS= read -r p; do
    p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
    # Strip surrounding quotes BEFORE the prefix strip and the existence test.
    # A YAML-quoted deliverable (`deliverable: "02 Areas/…/log.md"`) otherwise
    # keeps its literal quotes and can never match a file on disk, so a report
    # that declared its destination perfectly read as `not-represented`. Caught
    # 2026-08-05 on the env-error-monitor's very next run, which had just been
    # corrected to declare a bare path — the quoting alone was enough to re-break
    # it. Trim whitespace again afterwards: `" path "` is two layers.
    case "$p" in '"'*'"') p="${p#\"}"; p="${p%\"}";; "'"*"'") p="${p#\'}"; p="${p%\'}";; esac
    p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
    p="${p#"$vault"/}"; p="${p#/home/kyle/vault/}"; p="${p#\~/vault/}"
    [ -n "$p" ] && printf '%s\n' "$p"
  done
}

# ul_block_landed REPORT VAULT — cb-ingest's own idempotency test, read-only:
# a declared block has landed when its content's first non-blank line is already
# present verbatim in its declared target. Returns 0 when EVERY declared block
# has landed, 1 when any has not, 2 when the report declares no block at all.
ul_block_landed() {
  local rep="$1" vault="$2" n i blk target content first
  n="$(grep -c '^```cb-ingest[[:space:]]*$' "$rep" 2>/dev/null || true)"
  [ "${n:-0}" -gt 0 ] || return 2
  i=1
  while [ "$i" -le "$n" ]; do
    blk="$(awk -v want="$i" '
      /^```cb-ingest[[:space:]]*$/ { c++; if (c==want) { inb=1; next } }
      inb && /^```[[:space:]]*$/   { exit }
      inb                          { print }
    ' "$rep")"
    target="$(printf '%s\n' "$blk" | awk '/^target:/{sub(/^target:[[:space:]]*/,"");print;exit}')"
    content="$(printf '%s\n' "$blk" | awk 'f{print} /^---[[:space:]]*$/{f=1}')"
    first="$(printf '%s\n' "$content" | grep -m1 -v '^[[:space:]]*$' || true)"
    [ -n "$target" ] && [ -n "$first" ] || return 1
    grep -qxF "$first" "$vault/$target" 2>/dev/null || return 1
    i=$(( i + 1 ))
  done
  return 0
}

# ul_classify TASKDIR VAULT [REPORT] — `class<TAB>reason` for one task. REPORT
# overrides the task-dir report path: code conductors write `report.md` into
# their WORKTREE, not the task dir (verified across four tasks on 2026-07-31 —
# none had a task-dir report), so the caller resolves the path and the clearance
# still comes from the task dir's brief.
# Classes: skip | landed | blocked-ingest | not-represented | unknown
ul_classify() {
  local td="$1" vault="${2:-$HOME/vault}" rep="${3:-$1/report.md}"
  local st cl declared any=0 prose=0 p
  [ -f "$rep" ] || { printf 'skip\tno report.md\n'; return 0; }

  st="$(ul_report_field "$rep" status)"
  case "$st" in
    complete|done|partial) : ;;
    *) printf 'skip\tstatus=%s (not terminal)\n' "${st:-<none>}"; return 0;;
  esac

  # The CODE lane is not an ingest candidate at all: a conductor's deliverable is
  # a PR, and /ingest was never going to run on it. Without this it falls through
  # to the clearance gate — code task dirs usually carry no brief.md — and gets
  # reported as `blocked-ingest: brief has no clearance:`, which is confidently
  # false. A wrong reason discredits the sweep faster than a missed item.
  # `kind=code` in the task meta is the established lane signal (the fleet-tick
  # load guard reads the same field for the same question).
  if grep -q '^kind=code' "$td/meta" 2>/dev/null; then
    printf 'skip\tcode lane — deliverable is a PR, not a vault landing\n'; return 0
  fi

  # Stage 2 — the structural gate: a DECLARED clearance that is not `standard`.
  # Still checked BEFORE any content test, because a present deliverable does
  # not unblock a report nobody may file; reporting such a task as `landed`
  # would hide the one thing Kyle can act on.
  #
  # AN ABSENT CLEARANCE NO LONGER BLOCKS (2026-08-14) — a deliberate inversion
  # of what this stage did. Failing closed on empty was right while /ingest, a
  # human step that fails closed on the same field (ingest SKILL.md:38), was the
  # only way a finding could land. cb-land is that step now: `clearance:` is
  # script-written (cb-brief stamps it), so an absent one is a scaffold bug —
  # a hand-written or pre-cb-brief task — and cb-land reads it as `standard` and
  # files the report into 00 Inbox/. A register that still blocked on empty
  # would then read `blocked-ingest` for reports demonstrably sitting in the
  # vault, crying wolf on exactly the class the lander fixes
  # (`rca-eja-4065-failed-qe` is that case). A sweep that cries wolf gets
  # ignored, which is the same outcome as not having one.
  #
  # A DECLARED value still decides, and still decides first: `confidential` is
  # never proposed for landing, and an unrecognised value is a mistake nobody
  # should be filing against.
  cl="$(ul_clearance "$td/brief.md")"
  if [ -n "$cl" ] && [ "$cl" != standard ]; then
    # Say whether the output actually reached the vault as well as why the gate
    # is shut — the two cases need different handling and cost Kyle differently.
    # `deliverable present` means the finding IS filed and only the gate is
    # shut, so the whole cost is one sensitivity glance. `deliverable ABSENT`
    # means it is not in the vault at all and nothing automatic will put it
    # there — that one needs Kyle.
    local dstate="no deliverable declared"
    declared="$(ul_report_field "$rep" deliverable)"
    if [ -n "$declared" ]; then
      dstate="deliverable present"
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        [ "$p" = '!prose' ] && { dstate="deliverable declared as prose"; break; }
        [ -e "$vault/$p" ] || { dstate="deliverable ABSENT: $p"; break; }
      done <<EOF
$(ul_paths "$declared" "$vault")
EOF
    fi
    case "$cl" in
      confidential) printf 'blocked-ingest\tclearance: confidential — surface only, never auto-filed (%s)\n' "$dstate";;
      *)            printf 'blocked-ingest\tunrecognised clearance `%s` (%s)\n' "$cl" "$dstate";;
    esac
    return 0
  fi

  # Stage 3 — a machine-applicable block is the strongest signal there is: the
  # report named its own target AND its own content, so the test is exact.
  if ul_block_landed "$rep" "$vault"; then
    printf 'landed\tdeclared cb-ingest block(s) present in target\n'; return 0
  elif [ $? -eq 1 ]; then
    printf 'not-represented\tdeclared cb-ingest block not applied — run cb-ingest --drain\n'; return 0
  fi

  # Stage 3b — THE `landed` MARKER OUTRANKS THE DECLARATION, and it has to be
  # checked first or stage 4 calls a filed report `not-represented`.
  #
  # `cb-land` writes `<task>/landed` with the path it ACTUALLY filed to. The
  # report's own `deliverable:` is what the agent *declared*, and the two diverge
  # for two measured reasons (2026-08-16):
  #   1. The agent invents a destination. `rca-asd-1145-attestation-packet-fourth-bounce`
  #      declared `00 Inbox/2026-08-14-asd-1145-attestation-gate-rca.md`; cb-land
  #      filed it as `…-research-rca-asd-1145-…`. Both name the same landing. The
  #      dispatch skill already tells briefs not to name a vault path for exactly
  #      this reason; reports do it anyway.
  #   2. The declaration is ABSOLUTE. `eja-3928-retarget-pr-to-release` declared
  #      `/home/kyle/.cerebro/tasks/…/report.md`, which stage 4 resolves as
  #      vault-relative and never finds.
  # Either way the file is on disk and nothing needs ingesting, but the sweep said
  # `declared deliverable absent` — three tasks, **27 surfacings each**, ~81 false
  # positives over 56h. A sweep that cries wolf is worse than one that misses:
  # the whole register exists to make an unlanded report impossible to ignore.
  #
  # Deliberately AFTER stages 2 and 3: a clearance block still outranks this (a
  # filed report does not unblock one nobody may file), and a declared cb-ingest
  # block is a stronger, content-exact test than mere file existence.
  if [ -s "$td/landed" ]; then
    p="$(head -n1 "$td/landed" | tr -d '\r')"
    case "$p" in
      /*) [ -e "$p" ]          && { printf 'landed\tcb-land filed it: %s\n' "$p"; return 0; };;
      ?*) [ -e "$vault/$p" ]   && { printf 'landed\tcb-land filed it: %s\n' "$p"; return 0; };;
    esac
    # Marker present but its target is gone — that IS worth surfacing, and it is a
    # different failure from never having landed. Say which.
    printf 'not-represented\tcb-land filed it and the file is GONE: %s\n' "$p"; return 0
  fi

  # Stage 4 — the declared deliverable. Existence only; see the mtime note above.
  declared="$(ul_report_field "$rep" deliverable)"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ "$p" = '!prose' ]; then prose=1; continue; fi
    any=1
    [ -e "$vault/$p" ] || { missing=1; printf 'not-represented\tdeclared deliverable absent: %s\n' "$p"; return 0; }
  done <<EOF
$(ul_paths "$declared" "$vault")
EOF
  [ "$prose" = 1 ] && { printf 'unknown\tdeliverable declared as prose, not a resolvable path: %s\n' "$declared"; return 0; }
  [ "$any" = 1 ] && { printf 'landed\tdeclared deliverable present: %s\n' "$declared"; return 0; }

  printf 'unknown\tno declared destination — /ingest must decide it\n'
}

# --- the register -----------------------------------------------------------
# WHY A REGISTER. The 48h window is right for noise control and wrong as a
# disappearance rule: `e2e-product-findings-tickets` was surfaced at 46h and 47h,
# crossed 48h, and vanished permanently while still unlanded;
# `env-error-monitor-tick` was one tick from the same fate. So age QUIETS an item
# (it moves out of the in-window section) but never removes it. A line leaves the
# register on exactly two events — it lands, or Kyle resolves it by hand.
# Format: `SLUG<TAB>class=C<TAB>first=EPOCH<TAB>last=EPOCH<TAB>surfaces=N`

# ul_register_note REG SLUG CLASS NOW [INWINDOW] — upsert. INWINDOW (default 1)
# sets `origin=` on a NEW entry only, and it is what keeps the aged section
# honest. `watched` = the sweep saw it inside the window and it then aged out;
# that is the `e2e-product-findings-tickets` disappearance the section exists to
# prevent, and it must never drop off. `backlog` = it was already past the
# window the first time the sweep ever ran, so it was never being watched.
# Without this split the first run back-fills every historical report into the
# never-drops-off section — 85 lines on the live corpus — and a sweep that cries
# wolf gets ignored, which is the same outcome as not having it.
ul_register_note() {
  local reg="$1" slug="$2" class="$3" now="$4" inwin="${5:-1}"
  local first="$4" surf=1 origin old tmp
  origin=watched; [ "$inwin" = 0 ] && origin=backlog
  mkdir -p "$(dirname "$reg")"; [ -f "$reg" ] || : > "$reg"
  old="$(grep "^$slug	" "$reg" 2>/dev/null || true)"
  if [ -n "$old" ]; then
    first="$(printf '%s' "$old" | sed -n 's/.*first=\([0-9]*\).*/\1/p')"
    surf="$(printf '%s' "$old" | sed -n 's/.*surfaces=\([0-9]*\).*/\1/p')"
    surf=$(( surf + 1 ))
    # origin is set once, at first sight, and never re-derived: a backlog item
    # must not promote itself to `watched` just by being re-seen every hour.
    origin="$(printf '%s' "$old" | sed -n 's/.*origin=\([a-z]*\).*/\1/p')"
    [ -n "$origin" ] || origin=watched
  fi
  tmp="$(mktemp)"
  grep -v "^$slug	" "$reg" 2>/dev/null > "$tmp" || true
  printf '%s\tclass=%s\tfirst=%s\tlast=%s\tsurfaces=%s\torigin=%s\n' \
    "$slug" "$class" "$first" "$now" "$surf" "$origin" >> "$tmp"
  sort -o "$tmp" "$tmp"; mv -f "$tmp" "$reg"
}

# ul_register_origin REG SLUG — `watched` | `backlog` | empty when unregistered.
ul_register_origin() {
  [ -f "$1" ] || return 0
  grep "^$2	" "$1" 2>/dev/null | sed -n 's/.*origin=\([a-z]*\).*/\1/p'
}

ul_register_clear() {
  local reg="$1" slug="$2" tmp
  [ -f "$reg" ] || return 0
  tmp="$(mktemp)"; grep -v "^$slug	" "$reg" > "$tmp" || true; mv -f "$tmp" "$reg"
}

# ul_register_aged REG WINDOW NOW — register lines whose first_seen is older than
# WINDOW. These are the ones the old sweep dropped on the floor.
ul_register_aged() {
  local reg="$1" window="$2" now="$3"
  [ -f "$reg" ] || return 0
  awk -F'\t' -v w="$window" -v now="$now" '
    { f=$3; sub(/^first=/,"",f); if (now - f > w) print }
  ' "$reg"
}
