setup() { export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME"; load ../lib/paths.sh; }

@test "cb_task_dir composes under CB_HOME" {
  run cb_task_dir eja-foo
  [ "$output" = "$CB_HOME/tasks/eja-foo" ]
}

@test "cb_require_slug accepts real slugs (ticket + date-prefixed forms)" {
  run cb_require_slug eja-3488-ma-replacement-questions-gate; [ "$status" -eq 0 ]
  run cb_require_slug 2026-05-08-annuity-summary-custodial-owner-flag; [ "$status" -eq 0 ]
}

@test "cb_require_slug refuses shell metacharacters, spaces, and empties" {
  run cb_require_slug 'x";touch /tmp/pwn;"'; [ "$status" -eq 2 ]
  run cb_require_slug 'a b';                 [ "$status" -eq 2 ]
  run cb_require_slug '$(whoami)';           [ "$status" -eq 2 ]
  run cb_require_slug '-leading-dash';       [ "$status" -eq 2 ]
  run cb_require_slug '';                     [ "$status" -eq 2 ]
}

@test "atomic_write leaves no temp file and writes full content" {
  printf 'hello\n' | atomic_write "$CB_HOME/x"
  [ "$(cat "$CB_HOME/x")" = "hello" ]
  run bash -c "ls $CB_HOME/.x.* 2>/dev/null | wc -l"
  [ "$output" = "0" ]
}

@test "atomic_write returns non-zero and leaves dest unchanged on write failure" {
  local readonly_dir="$CB_HOME/readonly"
  mkdir -p "$readonly_dir"
  # Create an existing file so we can verify it's not corrupted
  printf 'original\n' > "$readonly_dir/target"

  # Make directory read-only to force mktemp to fail
  chmod a-w "$readonly_dir" || skip "Cannot set read-only permissions"

  # Try to write to the readonly dir; should fail
  # Run in a way that captures the exit status without failing the test
  set +e
  printf 'new data\n' | atomic_write "$readonly_dir/target" 2>/dev/null
  local atomic_status=$?
  set -e

  # Cleanup: restore perms so we can verify state
  chmod u+w "$readonly_dir"

  # atomic_write should have returned non-zero
  [ $atomic_status -ne 0 ]

  # Original content should be unchanged
  [ "$(cat "$readonly_dir/target")" = "original" ]

  # No temp files should be left behind
  run bash -c "ls $readonly_dir/.target.* 2>/dev/null | wc -l"
  [ "$output" = "0" ]
}
