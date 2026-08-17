#!/usr/bin/env bats
# delivery adapters (T16): create_pr / pr_status / merge — curl mocked via
# CB_CURL_CMD (receives the real curl argv; auth config arrives on its stdin).

setup() {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME"
  export BB_EMAIL="a@b" BB_API_TOKEN="sekrit-token"
  export CB_BB_WORKSPACE="porchsoftware" CB_BB_REPO="ultron"
  export MOCK_DIR="$BATS_TEST_TMPDIR/mock"; mkdir -p "$MOCK_DIR"
  # curl mock: records argv + stdin + any @payload file, replays $MOCK_DIR/response
  cat > "$MOCK_DIR/curlmock" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_DIR/argv"
cat > "$MOCK_DIR/stdin"
for a in "$@"; do case "$a" in @*) cp "${a#@}" "$MOCK_DIR/payload";; esac; done
cat "$MOCK_DIR/response"
EOF
  chmod +x "$MOCK_DIR/curlmock"
  export CB_CURL_CMD="$MOCK_DIR/curlmock"
  BODY="$BATS_TEST_TMPDIR/body.md"
  printf '## Summary\nA `fix` with "quotes" and\nnewlines.\n' > "$BODY"
}

@test "create_pr posts jq-escaped body and prints url+id" {
  printf '{"id":7,"state":"OPEN","links":{"html":{"href":"https://bb/pr/7"}}}\n201' > "$MOCK_DIR/response"
  run scripts/cerebro/delivery/bitbucket.sh create_pr "T: a title" fe/x main "$BODY" '[{"uuid":"a1"}]'
  [ "$status" -eq 0 ]
  [ "$output" = "https://bb/pr/7 7" ]
  run jq -r '.source.branch.name' "$MOCK_DIR/payload"; [ "$output" = "fe/x" ]
  run jq -r '.destination.branch.name' "$MOCK_DIR/payload"; [ "$output" = "main" ]
  run jq -r '.title' "$MOCK_DIR/payload"; [ "$output" = "T: a title" ]
  run jq -r '.reviewers[0].uuid' "$MOCK_DIR/payload"; [ "$output" = "a1" ]
  # body survives quotes/backticks/newlines via jq --rawfile escaping
  run jq -r '.description' "$MOCK_DIR/payload"
  [[ "$output" == *'"quotes"'* ]]
}

@test "create_pr auth goes via --config on stdin, never argv" {
  printf '{"id":7,"state":"OPEN","links":{"html":{"href":"https://bb/pr/7"}}}\n201' > "$MOCK_DIR/response"
  run scripts/cerebro/delivery/bitbucket.sh create_pr "T" fe/x main "$BODY" '[]'
  [ "$status" -eq 0 ]
  ! grep -q "sekrit-token" "$MOCK_DIR/argv"
  grep -q 'header = "Authorization: Bearer sekrit-token"' "$MOCK_DIR/stdin"
  grep -qx -- '--config' "$MOCK_DIR/argv"
}

# A sequencing curl mock: replays $MOCK_DIR/response.1, .2, … in call order, and
# records each payload as payload.N. The shared single-response mock cannot express
# "GET default-reviewers, then POST", which is what create_pr now does.
_seq_mock() {
  cat > "$MOCK_DIR/seqmock" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$MOCK_DIR/calls" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$n" > "$MOCK_DIR/calls"
printf '%s\n' "$@" > "$MOCK_DIR/argv.$n"
cat > "$MOCK_DIR/stdin.$n"
for a in "$@"; do case "$a" in @*) cp "${a#@}" "$MOCK_DIR/payload.$n";; esac; done
cat "$MOCK_DIR/response.$n"
EOF
  chmod +x "$MOCK_DIR/seqmock"
  export CB_CURL_CMD="$MOCK_DIR/seqmock"
}

# ⚠️ REGRESSION GUARD. This test previously asserted the OPPOSITE — that empty
# reviewers should OMIT the field "so repo default reviewers apply". That was wrong:
# Bitbucket applies repo defaults in the web UI only, so omitting the field created
# PRs with ZERO reviewers, which made them unreviewable and undiscoverable until
# Kyle hand-shared links in #ultron-prs (verified live 2026-08-04).
@test "create_pr with empty reviewers FETCHES repo defaults and sends them" {
  _seq_mock
  # call 1: GET /default-reviewers ; call 2: POST /pullrequests
  printf '{"values":[{"uuid":"{aaa}"},{"uuid":"{bbb}"}]}\n200' > "$MOCK_DIR/response.1"
  printf '{"id":7,"state":"OPEN","links":{"html":{"href":"https://bb/pr/7"}}}\n201' > "$MOCK_DIR/response.2"
  run scripts/cerebro/delivery/bitbucket.sh create_pr "T" fe/x main "$BODY" '[]'
  [ "$status" -eq 0 ]
  grep -q 'default-reviewers' "$MOCK_DIR/argv.1"
  run jq -r '[.reviewers[].uuid]|join(",")' "$MOCK_DIR/payload.2"
  [ "$output" = "{aaa},{bbb}" ]
}

@test "create_pr keeps an explicit reviewers list and does NOT fetch defaults" {
  _seq_mock
  printf '{"id":7,"state":"OPEN","links":{"html":{"href":"https://bb/pr/7"}}}\n201' > "$MOCK_DIR/response.1"
  run scripts/cerebro/delivery/bitbucket.sh create_pr "T" fe/x main "$BODY" '[{"uuid":"{explicit}"}]'
  [ "$status" -eq 0 ]
  # only one call — no default-reviewers lookup when the caller supplied a list
  [ "$(cat "$MOCK_DIR/calls")" = "1" ]
  run jq -r '.reviewers[0].uuid' "$MOCK_DIR/payload.1"; [ "$output" = "{explicit}" ]
}

@test "create_pr strips author-as-reviewer and retries once" {
  _seq_mock
  AUTHOR='{789b8579-5879-4a55-bc17-2e30bc242cfb}'
  OTHER='{a8423eb5-e873-43c5-8053-244a09f1df1e}'
  printf '{"values":[{"uuid":"%s"},{"uuid":"%s"}]}\n200' "$AUTHOR" "$OTHER" > "$MOCK_DIR/response.1"
  # Bitbucket rejects the author appearing in its own reviewer list. Real uuids are
  # 36 hex chars in braces, which is what the adapter's strip regex matches.
  printf '{"error":{"message":"reviewers: the author %s cannot be a reviewer"}}\n400' "$AUTHOR" > "$MOCK_DIR/response.2"
  printf '{"id":9,"state":"OPEN","links":{"html":{"href":"https://bb/pr/9"}}}\n201' > "$MOCK_DIR/response.3"
  run scripts/cerebro/delivery/bitbucket.sh create_pr "T" fe/x main "$BODY" '[]'
  [ "$status" -eq 0 ]
  # containment: the retry emits a stderr notice, which `run` folds into $output
  [[ "$output" == *"https://bb/pr/9 9"* ]]
  [[ "$output" == *"retrying create_pr without author-as-reviewer"* ]]
  run jq -r '[.reviewers[].uuid]|join(",")' "$MOCK_DIR/payload.3"
  [ "$output" = "$OTHER" ]
}

@test "create_pr still succeeds when the repo has no default reviewers" {
  _seq_mock
  printf '{"values":[]}\n200' > "$MOCK_DIR/response.1"
  printf '{"id":7,"state":"OPEN","links":{"html":{"href":"https://bb/pr/7"}}}\n201' > "$MOCK_DIR/response.2"
  run scripts/cerebro/delivery/bitbucket.sh create_pr "T" fe/x main "$BODY" '[]'
  [ "$status" -eq 0 ]
  run jq 'has("reviewers")' "$MOCK_DIR/payload.2"; [ "$output" = "false" ]
}

@test "create_pr omits draft unless CB_BB_DRAFT is set" {
  printf '{"id":7,"state":"OPEN","draft":false,"links":{"html":{"href":"https://bb/pr/7"}}}\n201' > "$MOCK_DIR/response"
  run scripts/cerebro/delivery/bitbucket.sh create_pr "T" fe/x main "$BODY" '[]'
  [ "$status" -eq 0 ]
  run jq 'has("draft")' "$MOCK_DIR/payload"; [ "$output" = "false" ]
}

@test "CB_BB_DRAFT=1 posts draft:true" {
  printf '{"id":7,"state":"OPEN","draft":true,"links":{"html":{"href":"https://bb/pr/7"}}}\n201' > "$MOCK_DIR/response"
  CB_BB_DRAFT=1 run scripts/cerebro/delivery/bitbucket.sh create_pr "T" fe/x main "$BODY" '[]'
  [ "$status" -eq 0 ]
  # containment, not equality: create_pr may now also emit a stderr warning when the
  # repo reports no default reviewers, and `run` folds stderr into $output
  [[ "$output" == *"https://bb/pr/7 7"* ]]
  run jq -r '.draft' "$MOCK_DIR/payload"; [ "$output" = "true" ]
}

@test "a requested draft that comes back non-draft fails loudly" {
  printf '{"id":7,"state":"OPEN","draft":false,"links":{"html":{"href":"https://bb/pr/7"}}}\n201' > "$MOCK_DIR/response"
  CB_BB_DRAFT=1 run scripts/cerebro/delivery/bitbucket.sh create_pr "T" fe/x main "$BODY" '[]'
  [ "$status" -eq 1 ]
  [[ "$output" == *"asked for a DRAFT"* ]]
}

@test "create_pr targets the workspace/repo pullrequests endpoint" {
  printf '{"id":7,"state":"OPEN","links":{"html":{"href":"https://bb/pr/7"}}}\n201' > "$MOCK_DIR/response"
  run scripts/cerebro/delivery/bitbucket.sh create_pr "T" fe/x main "$BODY" '[]'
  grep -q 'repositories/porchsoftware/ultron/pullrequests' "$MOCK_DIR/argv"
}

@test "401 exits 3 with escalate line" {
  printf '{"error":{"message":"nope"}}\n401' > "$MOCK_DIR/response"
  run scripts/cerebro/delivery/bitbucket.sh create_pr "T" fe/x main "$BODY" '[]'
  [ "$status" -eq 3 ]
  [[ "$output" == *"escalate: token dead"* ]]
}

@test "pr_status prints the PR state" {
  printf '{"id":7,"state":"MERGED"}\n200' > "$MOCK_DIR/response"
  run scripts/cerebro/delivery/bitbucket.sh pr_status 7
  [ "$status" -eq 0 ]
  [ "$output" = "MERGED" ]
}

@test "pr_status 401 exits 3 with escalate line" {
  printf 'x\n401' > "$MOCK_DIR/response"
  run scripts/cerebro/delivery/bitbucket.sh pr_status 7
  [ "$status" -eq 3 ]
  [[ "$output" == *"escalate: token dead"* ]]
}

@test "bitbucket merge refuses — operator merges in Bitbucket" {
  run scripts/cerebro/delivery/bitbucket.sh merge 7
  [ "$status" -ne 0 ]
  [[ "$output" == *"operator"* ]]
}

@test "create_pr non-2xx (not 401) fails non-3 with the code in the message" {
  printf '{"error":"bad"}\n400' > "$MOCK_DIR/response"
  run scripts/cerebro/delivery/bitbucket.sh create_pr "T" fe/x main "$BODY" '[]'
  [ "$status" -ne 0 ]; [ "$status" -ne 3 ]
  [[ "$output" == *"400"* ]]
}

# --- local-only adapter: same interface, no network ---

@test "local-only create_pr records OPEN and prints url+id" {
  run scripts/cerebro/delivery/local-only.sh create_pr "T" fe/x main "$BODY" '[]'
  [ "$status" -eq 0 ]
  id="${output##* }"
  run scripts/cerebro/delivery/local-only.sh pr_status "$id"
  [ "$output" = "OPEN" ]
}

@test "local-only merge ffs via CB_GIT_CMD and flips state to MERGED" {
  export CB_LOCAL_REPO="$BATS_TEST_TMPDIR/repo"; mkdir -p "$CB_LOCAL_REPO"
  cat > "$MOCK_DIR/gitmock" <<'EOF'
#!/usr/bin/env bash
echo "GIT $*" >> "$MOCK_DIR/git.log"
EOF
  chmod +x "$MOCK_DIR/gitmock"
  export CB_GIT_CMD="$MOCK_DIR/gitmock"
  run scripts/cerebro/delivery/local-only.sh create_pr "T" fe/x main "$BODY" '[]'
  id="${output##* }"
  run scripts/cerebro/delivery/local-only.sh merge "$id"
  [ "$status" -eq 0 ]
  grep -q 'merge --ff-only fe/x' "$MOCK_DIR/git.log"
  run scripts/cerebro/delivery/local-only.sh pr_status "$id"
  [ "$output" = "MERGED" ]
}
