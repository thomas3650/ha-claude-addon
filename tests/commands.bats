load helpers

stub_actions() {
  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  raise_outcome() { echo "outcome $1 $2" >> "$CALLS"; }
  sync_workspace() { echo "sync" >> "$CALLS"; }
  install_managed_settings() { echo "managed" >> "$CALLS"; }
  ensure_layout() { :; }
  restart_chat() { echo "restart${1:+ $1}" >> "$CALLS"; }
  MORNING_OUTCOME=ok
  run_morning() { echo "run" >> "$CALLS"; printf -v "$1" '%s' "$MORNING_OUTCOME"; }
}

@test "parse_command reads a JSON string, a plain word and an object" {
  load_lib commands
  [ "$(parse_command '"ping"')" = "ping" ]
  [ "$(parse_command 'ping')" = "ping" ]
  [ "$(parse_command '{"command":"sync"}')" = "sync" ]
  [ "$(parse_command $'ping\r')" = "ping" ]
}

@test "ping reports ok" {
  load_lib commands; stub_actions
  handle_command '"ping"'
  [ "$(cat "$CALLS")" = "outcome ping ok" ]
}

@test "sync syncs, installs the managed settings, restarts the chat and reports ok" {
  load_lib commands; stub_actions
  handle_command 'sync'
  [ "$(cat "$CALLS")" = $'sync\nmanaged\nrestart\noutcome sync ok' ]
}

@test "an unknown command is ignored and logged" {
  load_lib commands; stub_actions
  run handle_command '"rm -rf /"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignoring unknown command"* ]]
  [ ! -s "$CALLS" ]
}

@test "an empty or malformed line is ignored" {
  load_lib commands; stub_actions
  run handle_command ''
  [ "$status" -eq 0 ]
  run handle_command '{"broken'
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
}

@test "raise_outcome keeps the Supervisor token off the command line" {
  load_lib outcome
  export SUPERVISOR_TOKEN=tok-123
  curl() { printf '%s\n' "$*" > "$BATS_TEST_TMPDIR/curl-args"; cat > "$BATS_TEST_TMPDIR/curl-stdin"; }
  raise_outcome ping ok
  ! grep -q "tok-123" "$BATS_TEST_TMPDIR/curl-args"
  grep -q "Bearer tok-123" "$BATS_TEST_TMPDIR/curl-stdin"
}

@test "a malformed command is ignored with a log line, an empty one silently" {
  load_lib commands; stub_actions
  run handle_command '{"broken'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignoring malformed command"* ]]
  run handle_command ''
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$CALLS" ]
}

@test "read_command returns a whole line" {
  load_lib commands
  read_command 2 got <<<'"ping"'
  [ "$got" = '"ping"' ]
}

@test "a command that arrives in two parts across a timeout is put together" {
  load_lib commands
  exec 9< <(printf '"pi'; sleep 2; printf 'ng"\n'; sleep 1)
  read_command 1 got <&9 && rc=0 || rc=$?
  [ "$rc" -eq 2 ]
  [ "$HC_PARTIAL" = '"pi' ]
  read_command 4 got <&9
  [ "$got" = '"ping"' ]
  exec 9<&-
}

@test "a part whose rest never arrives is dropped after one quiet wait, with a log line" {
  load_lib commands
  exec 9< <(printf '"pi'; sleep 4)
  read_command 1 got <&9 && rc=0 || rc=$?
  [ "$HC_PARTIAL" = '"pi' ]
  read_command 1 got <&9 2>"$BATS_TEST_TMPDIR/err" && rc=0 || rc=$?
  [ "$rc" -eq 2 ]
  [ -z "$HC_PARTIAL" ]
  grep -q "dropping an unfinished command" "$BATS_TEST_TMPDIR/err"
  exec 9<&-
}

@test "a command without a line ending is handled when standard input closes" {
  load_lib commands
  exec 9< <(printf 'ping')
  read_command 2 got <&9
  [ "$got" = 'ping' ]
  read_command 1 got <&9 && rc=0 || rc=$?
  [ "$rc" -eq 1 ]
  exec 9<&-
}

@test "a timeout with nothing read reports a timeout and keeps nothing" {
  load_lib commands
  exec 9< <(sleep 3)
  read_command 1 got <&9 && rc=0 || rc=$?
  [ "$rc" -eq 2 ]
  [ -z "$HC_PARTIAL" ]
  exec 9<&-
}

@test "morning runs the briefing, starts a new chat that presents the summary, and reports ok" {
  load_lib morning commands; stub_actions
  handle_command 'morning'
  [ "$(sed -n 1p "$CALLS")" = "run" ]
  [ "$(sed -n 2p "$CALLS")" = "restart $(opening_prompt ok)" ]
  [ "$(sed -n 3p "$CALLS")" = "outcome morning ok" ]
}

@test "a failed morning run still starts a new chat, which says so, and reports the outcome" {
  load_lib morning commands; stub_actions
  MORNING_OUTCOME=timeout
  handle_command 'morning'
  [ "$(sed -n 2p "$CALLS")" = "restart $(opening_prompt timeout)" ]
  [ "$(sed -n 3p "$CALLS")" = "outcome morning timeout" ]
}

@test "without the agent the chat session is left alone" {
  load_lib morning commands; stub_actions
  MORNING_OUTCOME=not_configured
  handle_command 'morning'
  [ "$(cat "$CALLS")" = $'run\noutcome morning not_configured' ]
}

@test "a stop signal during a morning run ends the main process at once" {
  STUB="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB" "$HC_DATA/workspace/assistant/.claude/agents"
  touch "$HC_DATA/workspace/assistant/.claude/agents/morning-briefing.md"
  printf '#!/usr/bin/env bash\nsleep 30 &\ntrap "kill $!" TERM\nwait\n' > "$STUB/claude"
  chmod +x "$STUB/claude"
  cat > "$BATS_TEST_TMPDIR/main" <<EOT
for f in paths log options env morning commands; do . "$LIB/\$f.sh"; done
raise_outcome() { :; }
restart_chat() { :; }
trap 'echo stopped; exit 0' TERM
handle_command morning
echo finished
EOT
  HC_CLAUDE_BIN="$STUB/claude" \
  HC_LIMIT_BIN="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/ha-claude-limit" \
    bash "$BATS_TEST_TMPDIR/main" > "$BATS_TEST_TMPDIR/out" 2>&1 3>&- &
  pid=$!
  sleep 2
  kill -TERM "$pid"
  for _ in 1 2 3 4 5; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  pkill -f "$STUB/claude" 2>/dev/null || true
  run kill -0 "$pid"
  [ "$status" -ne 0 ]
  grep -qx "stopped" "$BATS_TEST_TMPDIR/out"
  run grep "finished" "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 1 ]
}
