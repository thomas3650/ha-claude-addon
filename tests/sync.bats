load helpers

make_fixture_repo() {
  FIXTURE="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$FIXTURE/assistant/.claude" "$FIXTURE/docs"
  echo "assistant rules" > "$FIXTURE/assistant/CLAUDE.md"
  echo '{}' > "$FIXTURE/assistant/.claude/settings.json"
  echo "private spec" > "$FIXTURE/docs/spec.md"
  echo "dev rules" > "$FIXTURE/CLAUDE.md"
  git -C "$FIXTURE" init -q -b main
  git -C "$FIXTURE" -c user.name=t -c user.email=t@example.com add -A
  git -C "$FIXTURE" -c user.name=t -c user.email=t@example.com commit -q -m init
}

@test "sync copies only assistant/ and no git history" {
  load_lib options layout sync
  make_fixture_repo
  set_options "{\"repo_url\":\"file://$FIXTURE\"}"
  ensure_layout
  run sync_workspace
  [ "$status" -eq 0 ]
  [ "$(cat "$HC_WORKSPACE/CLAUDE.md")" = "assistant rules" ]
  [ -f "$HC_WORKSPACE/.claude/settings.json" ]
  [ ! -e "$HC_WORKSPACE/.git" ]
  [ ! -e "$HC_WORKSPACE/docs" ]
  [ ! -e "$(dirname "$HC_WORKSPACE")/CLAUDE.md" ]
  [ ! -e "$HC_DATA/CLAUDE.md" ]
  [ "$(cat "$HC_STATE/last_sync_status")" = "ok" ]
}

@test "a second sync picks up a new commit" {
  load_lib options layout sync
  make_fixture_repo
  set_options "{\"repo_url\":\"file://$FIXTURE\"}"
  ensure_layout
  sync_workspace
  echo "new rules" > "$FIXTURE/assistant/CLAUDE.md"
  git -C "$FIXTURE" -c user.name=t -c user.email=t@example.com commit -q -am change
  sync_workspace
  [ "$(cat "$HC_WORKSPACE/CLAUDE.md")" = "new rules" ]
}

@test "a failed fetch keeps the previous copy and returns 0" {
  load_lib options layout sync
  make_fixture_repo
  set_options "{\"repo_url\":\"file://$FIXTURE\"}"
  ensure_layout
  sync_workspace
  rm -rf "$FIXTURE"
  run sync_workspace
  [ "$status" -eq 0 ]
  [ "$(cat "$HC_WORKSPACE/CLAUDE.md")" = "assistant rules" ]
  [[ "$(cat "$HC_STATE/last_sync_status")" == failed:* ]]
}

@test "first boot with no repo_url leaves an empty workspace" {
  load_lib options layout sync
  ensure_layout
  run sync_workspace
  [ "$status" -eq 0 ]
  [ -d "$HC_WORKSPACE" ]
  [ "$(cat "$HC_STATE/last_sync_status")" = "none" ]
}

@test "a repo without assistant/ keeps the previous copy" {
  load_lib options layout sync
  make_fixture_repo
  set_options "{\"repo_url\":\"file://$FIXTURE\"}"
  ensure_layout
  sync_workspace
  git -C "$FIXTURE" rm -q -r assistant
  git -C "$FIXTURE" -c user.name=t -c user.email=t@example.com commit -q -m drop
  run sync_workspace
  [ "$status" -eq 0 ]
  [ "$(cat "$HC_WORKSPACE/CLAUDE.md")" = "assistant rules" ]
}

@test "an ssh repo with an empty deploy key logs one clear line and returns 0" {
  load_lib options layout sync
  set_options '{"repo_url":"git@github.com:example/private.git","deploy_key":""}'
  ensure_layout
  run sync_workspace
  [ "$status" -eq 0 ]
  [[ "$output" == *"deploy key is empty"* ]]
}

@test "an ssh repo with a malformed deploy key logs one clear line and returns 0" {
  load_lib options layout sync
  set_options '{"repo_url":"git@github.com:example/private.git","deploy_key":"not a key"}'
  ensure_layout
  run sync_workspace
  [ "$status" -eq 0 ]
  [[ "$output" == *"deploy key is not a valid private key"* ]]
  [ ! -e "$HC_STATE/deploy_key" ]
}
