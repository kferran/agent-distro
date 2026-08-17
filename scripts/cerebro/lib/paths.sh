: "${CB_HOME:=$HOME/.cerebro}"
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
