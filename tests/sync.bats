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
  [ "$(cat "$HC_STATUS/last_sync_status")" = "ok" ]
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
  [[ "$(cat "$HC_STATUS/last_sync_status")" == failed:* ]]
}

@test "first boot with no repo_url leaves an empty workspace" {
  load_lib options layout sync
  ensure_layout
  run sync_workspace
  [ "$status" -eq 0 ]
  [ -d "$HC_WORKSPACE" ]
  [ "$(cat "$HC_STATUS/last_sync_status")" = "none" ]
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
  [[ "$output" == *"deploy key is not a valid private key without a passphrase"* ]]
  [ ! -e "$HC_STATE/deploy_key" ]
}

@test "a deploy key with a passphrase is refused without reading standard input" {
  load_lib options layout sync
  ssh-keygen -q -t ed25519 -N "pw" -f "$BATS_TEST_TMPDIR/k"
  jq -n --arg k "$(cat "$BATS_TEST_TMPDIR/k")" '{repo_url:"git@github.com:example/private.git",deploy_key:$k}' > "$HC_DATA/options.json"
  ensure_layout
  run _write_deploy_key <<<"pw"
  [ "$status" -eq 2 ]
  [ ! -e "$HC_STATE/deploy_key" ]
}

@test "an emptied deploy key option removes the old key file" {
  load_lib options layout sync
  ensure_layout
  echo old > "$HC_STATE/deploy_key"
  set_options '{"repo_url":"git@github.com:example/private.git","deploy_key":""}'
  run sync_workspace
  [ ! -e "$HC_STATE/deploy_key" ]
}

@test "ssh never prompts and gives up on a dead network" {
  load_lib options layout sync
  run _git_ssh_command
  [[ "$output" == *"BatchMode=yes"* ]]
  [[ "$output" == *"ConnectTimeout=15"* ]]
  [[ "$output" == *"-i $HC_STATE/deploy_key"* ]]
}

make_key() {
  KEYFILE="$BATS_TEST_TMPDIR/k"
  ssh-keygen -q -t ed25519 -N "" -f "$KEYFILE"
}

@test "a key pasted into a one-line field, line breaks turned to spaces, is accepted" {
  load_lib options sync
  make_key
  mangled="$(tr '\n' ' ' < "$KEYFILE")"
  set_options "$(jq -cn --arg k "$mangled" '{deploy_key:$k}')"
  run _write_deploy_key
  [ "$status" -eq 0 ]
  ssh-keygen -y -P '' -f "$HC_STATE/deploy_key" </dev/null >/dev/null
}

@test "a key pasted with its line breaks removed is accepted" {
  load_lib options sync
  make_key
  mangled="$(tr -d '\n' < "$KEYFILE")"
  set_options "$(jq -cn --arg k "$mangled" '{deploy_key:$k}')"
  run _write_deploy_key
  [ "$status" -eq 0 ]
  ssh-keygen -y -P '' -f "$HC_STATE/deploy_key" </dev/null >/dev/null
}

@test "a key pasted as it is, with line breaks, is still accepted" {
  load_lib options sync
  make_key
  set_options "$(jq -cn --arg k "$(cat "$KEYFILE")" '{deploy_key:$k}')"
  run _write_deploy_key
  [ "$status" -eq 0 ]
  ssh-keygen -y -P '' -f "$HC_STATE/deploy_key" </dev/null >/dev/null
}

@test "a key pasted with carriage returns is accepted" {
  load_lib options sync
  make_key
  mangled="$(sed 's/$/\r/' "$KEYFILE" | tr '\n' ' ')"
  set_options "$(jq -cn --arg k "$mangled" '{deploy_key:$k}')"
  run _write_deploy_key
  [ "$status" -eq 0 ]
  ssh-keygen -y -P '' -f "$HC_STATE/deploy_key" </dev/null >/dev/null
}

@test "a restored key has no line longer than 70 characters in its body" {
  load_lib options sync
  make_key
  run _key_text "$(tr -d '\n' < "$KEYFILE")"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "-----BEGIN OPENSSH PRIVATE KEY-----" ]
  for line in "${lines[@]}"; do
    [[ "$line" == -----* ]] || [ "${#line}" -le 70 ]
  done
}

@test "sync says in HC_SYNC_RESULT whether the working folder is new, kept, or not configured" {
  load_lib options layout sync
  make_fixture_repo
  set_options "{\"repo_url\":\"file://$FIXTURE\"}"
  ensure_layout
  sync_workspace
  [ "$HC_SYNC_RESULT" = "ok" ]
  set_options '{"repo_url":"file:///nonexistent/repo"}'
  sync_workspace 2>/dev/null
  [ "$HC_SYNC_RESULT" = "kept" ]
  set_options '{}'
  sync_workspace 2>/dev/null
  [ "$HC_SYNC_RESULT" = "none" ]
}

@test "the host keys of GitHub come with the add-on, and a changed key there is refused" {
  load_lib options sync
  hosts="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/share/ha-claude/known_hosts"
  [ "$(grep -c '^github.com ' "$hosts")" -eq 3 ]
  grep -q '^github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl$' "$hosts"
  cmd="$(_git_ssh_command)"
  [[ "$cmd" == *"UserKnownHostsFile=$HC_STATE/known_hosts $HC_KNOWN_HOSTS'"* ]]
  [[ "$cmd" == *"StrictHostKeyChecking=accept-new"* ]]
  [[ "$cmd" != *"StrictHostKeyChecking=no"* ]]
}

