load helpers

stub_actions() {
  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  raise_outcome() { echo "outcome $1 $2" >> "$CALLS"; }
  sync_workspace() { echo "sync" >> "$CALLS"; }
  ensure_layout() { :; }
  restart_chat() { echo "restart" >> "$CALLS"; }
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

@test "sync syncs, restarts the chat and reports ok" {
  load_lib commands; stub_actions
  handle_command 'sync'
  [ "$(cat "$CALLS")" = $'sync\nrestart\noutcome sync ok' ]
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

@test "a second morning command while one runs is refused as busy" {
  load_lib commands; stub_actions
  mkdir -p "$HC_STATE/morning.lock"
  handle_command 'morning'
  [ "$(cat "$CALLS")" = "outcome morning busy" ]
  [ -d "$HC_STATE/morning.lock" ]
}

@test "morning is a stub that reports not_implemented and releases its lock" {
  load_lib commands; stub_actions
  handle_command 'morning'
  [ "$(cat "$CALLS")" = "outcome morning not_implemented" ]
  [ ! -e "$HC_STATE/morning.lock" ]
}
