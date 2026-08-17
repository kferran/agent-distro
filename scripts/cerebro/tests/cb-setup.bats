setup() { export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; }
@test "refuses cleanly when env missing" {
  export CB_ENV="$BATS_TEST_TMPDIR/noenv"
  run scripts/cerebro/cb-setup
  [ "$status" -ne 0 ]; [[ "$output" == *"BB_EMAIL"* ]]
}
@test "creates tree and passes with a mocked-good probe" {
  export CB_ENV="$BATS_TEST_TMPDIR/env"; printf 'BB_EMAIL=a@b\nBB_API_TOKEN=t\n' > "$CB_ENV"
  export CB_PROBE_CMD="printf '200'"     # mock: HTTP 200
  run scripts/cerebro/cb-setup
  [ "$status" -eq 0 ]; [ -d "$CB_HOME/tasks" ]; [ -d "$CB_HOME/beacons" ]
}
@test "fails on a mocked-401 probe" {
  export CB_ENV="$BATS_TEST_TMPDIR/env"; printf 'BB_EMAIL=a@b\nBB_API_TOKEN=t\n' > "$CB_ENV"
  export CB_PROBE_CMD="printf '401'"
  run scripts/cerebro/cb-setup
  [ "$status" -ne 0 ]; [[ "$output" == *"token"* ]]
}
@test "probe passes token via stdin config, not argv (T16 retrofit)" {
  export CB_ENV="$BATS_TEST_TMPDIR/env"
  printf 'BB_EMAIL=a@b\nBB_API_TOKEN=sekrit-token\n' > "$CB_ENV"
  # fake curl on PATH; default probe command (CB_PROBE_CMD unset) must call it
  # with the auth config on stdin, never the token in argv.
  local fakebin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$fakebin"
  cat > "$fakebin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$BATS_TEST_TMPDIR/curl.argv"
cat > "$BATS_TEST_TMPDIR/curl.stdin"
printf '200'
EOF
  chmod +x "$fakebin/curl"
  unset CB_PROBE_CMD 2>/dev/null || true
  PATH="$fakebin:$PATH" run scripts/cerebro/cb-setup
  [ "$status" -eq 0 ]
  ! grep -q 'sekrit-token' "$BATS_TEST_TMPDIR/curl.argv"
  grep -q 'header = "Authorization: Bearer sekrit-token"' "$BATS_TEST_TMPDIR/curl.stdin"
}
