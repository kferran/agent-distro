: "${CB_HOME:=$HOME/.cerebro}"

# --- host workspace resolution (Phase 0a) ------------------------------------
# ONE place computes the host root. Before this, `: "${CB_VAULT:=$HOME/vault}"`
# was re-declared independently in eight files and VAULT_DIR in seven more —
# two names for one thing with no file owning either, so setting one and not
# the other made the engine half-redirect: some paths moved, the rest silently
# kept writing to ~/vault.
#
# PRECEDENCE: CB_VAULT > VAULT_DIR > CB_HOST > $HOME/vault.
#
# CB_VAULT and VAULT_DIR are the DEPRECATED names and they deliberately win,
# because ~20 call sites and the whole test suite set them. CB_HOST is the name
# for new code and is the fallback, not the override.
#
# ⚠️ NOTHING HERE IS EXPORTED, and that is load-bearing rather than an omission.
# The first version of this block exported CB_HOST and derived the layout with
# `:=`. Both broke re-sourcing: an exported CB_HOST made the next `. paths.sh`
# take the CB_HOST branch, ignore a freshly-set CB_VAULT, and then OVERWRITE it
# with the stale value — silently reverting an explicit override, and leaking
# across process boundaries. 87 tests caught it. A value that is both an input
# and an exported output cannot be resolved idempotently, so this one is not.
CB_HOST="${CB_VAULT:-${VAULT_DIR:-${CB_HOST:-$HOME/vault}}}"
CB_VAULT="$CB_HOST"
VAULT_DIR="$CB_HOST"

# cb_host_path SUBPATH — join a host-relative path onto the resolved root, in
# one place, so a trailing slash cannot produce a doubled separator.
cb_host_path() { printf '%s/%s' "${CB_HOST%/}" "${1#/}"; }

# --- host layout -------------------------------------------------------------
# The subpaths the engine hardcoded: "00 Inbox" (9 sites), board.md (2),
# "02 Areas" (2), Daily (1). These are the interfaces the separation design
# named and that appeared in ZERO engine files before this commit.
#
# FUNCTIONS, not variables, for the reason above: a derived value has to be
# recomputed when the root changes, and an assignment cannot be. Each honours
# an explicit override if the caller set one, so a host can declare a layout
# without editing the engine. This mirrors cb_task_dir/cb_beacon below, which
# already worked this way — breaking from that idiom is what cost 87 tests.
cb_items_dir()   { printf '%s' "${CB_ITEMS_DIR:-$(cb_host_path '00 Inbox')}"; }
cb_archive_dir() { printf '%s' "${CB_ARCHIVE_DIR:-$(cb_host_path '02 Areas/development/archive/items')}"; }
cb_daily_dir()   { printf '%s' "${CB_DAILY_DIR:-$(cb_host_path 'Daily')}"; }
cb_board_file()  { printf '%s' "${CB_BOARD_FILE:-$(cb_host_path 'board.md')}"; }

# Knowledge sink: an ALLOWLIST of roots the distiller may write into, colon
# separated because these paths contain spaces. Deny always wins over it —
# see lib/denylist.sh.
cb_knowledge_roots() {
  printf '%s' "${CB_KNOWLEDGE_ROOTS:-$(cb_host_path '03 Resources'):$(cb_host_path '02 Areas/platform')}"
}

cb_task_dir() { printf '%s/tasks/%s' "$CB_HOME" "$1"; }
cb_beacon()   { printf '%s/beacons/%s' "$CB_HOME" "$1"; }
# cb_require_slug SLUG — refuse anything that isn't a plain slug. Slugs are
# also branch names, tmux target names, and dir names, AND several spawn paths
# interpolate the slug into an eval'd CB_*_CMD default string — so a slug with
# shell metacharacters (from a hand-typed or pasted dev-item frontmatter) could
# execute as code. Constrain to lowercase alnum + [-._], leading alnum.
cb_require_slug() {
  case "$1" in
    '' ) echo "cerebro: empty slug" >&2; return 2;;
    [!a-z0-9]* ) echo "cerebro: slug '$1' must start with a lowercase letter or digit" >&2; return 2;;
    *[!a-z0-9._-]* ) echo "cerebro: slug '$1' has invalid characters (allowed: a-z 0-9 . _ -)" >&2; return 2;;
  esac
}
# atomic_write DEST — stdin → temp in DEST's dir → mv into place
atomic_write() {
  local dest="$1" dir tmp
  dir="$(dirname "$dest")"; mkdir -p "$dir" || return 1
  tmp="$(mktemp "$dir/.$(basename "$dest").XXXXXX")" || return 1
  if ! cat > "$tmp"; then rm -f "$tmp"; return 1; fi
  mv -f "$tmp" "$dest"
}
