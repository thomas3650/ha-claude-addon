load helpers

@test "chat_command names the session and passes today's date and handover file" {
  load_lib options session
  set_options '{"session_name":"Home"}'
  mkdir -p "$HC_WORKSPACE"
  run chat_command
  today="$(date +%F)"
  [[ "${lines[0]}" == "claude" ]]
  [[ "$output" == *"--remote-control=Home"* ]]
  [[ "$output" == *"Today is $today."* ]]
  [[ "$output" == *"$HC_HANDOVER/$today.md"* ]]
  [[ "$output" != *"--agent"* ]]
  [[ "$output" != *"dangerously"* ]]
}

@test "chat_command uses the chat agent only when the workspace defines it" {
  load_lib options session
  mkdir -p "$HC_WORKSPACE/.claude/agents"
  touch "$HC_WORKSPACE/.claude/agents/chat.md"
  run chat_command
  [[ "$output" == *$'--agent\nchat'* ]]
}

@test "chat_command puts an opening prompt last" {
  load_lib options session
  mkdir -p "$HC_WORKSPACE"
  run chat_command "Present today's summary"
  [ "${lines[${#lines[@]}-1]}" = "Present today's summary" ]
}

@test "logged_in follows the credentials file" {
  load_lib options session
  run logged_in
  [ "$status" -ne 0 ]
  mkdir -p "$HC_HOME/.claude" && touch "$HC_HOME/.claude/.credentials.json"
  run logged_in
  [ "$status" -eq 0 ]
}

@test "chat_command takes the session name from HC_SESSION_NAME when it cannot read the options" {
  load_lib options session
  mkdir -p "$HC_WORKSPACE"
  HC_SESSION_NAME=Office run chat_command
  [[ "$output" == *"--remote-control=Office"* ]]
}

@test "start_chat hands the session name from the options to the chat session" {
  load_lib options env session
  set_options '{"session_name":"Office"}'
  as_claude() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/as_claude"; [[ "$*" != *has-session* ]]; }
  start_chat
  grep -q -- "-e HC_SESSION_NAME=Office" "$BATS_TEST_TMPDIR/as_claude"
}

@test "start_chat hands the assistant's variables to the chat session" {
  load_lib options env session
  set_options '{"session_name":"Office","assistant_env":["ASSISTANT_ONE=1","PATH=/tmp/evil"]}'
  as_claude() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/as_claude"; [[ "$*" != *has-session* ]]; }
  start_chat
  grep -q -- "-e ASSISTANT_ONE=1" "$BATS_TEST_TMPDIR/as_claude"
  run grep -- "PATH=/tmp/evil" "$BATS_TEST_TMPDIR/as_claude"
  [ "$status" -eq 1 ]
}

@test "start_chat hands an opening prompt to the chat session, and none when none is given" {
  load_lib options env session
  as_claude() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/as_claude"; [[ "$*" != *has-session* ]]; }
  start_chat "Say hello to the owner"
  grep -q -- "-e HC_OPENING_PROMPT=Say hello to the owner" "$BATS_TEST_TMPDIR/as_claude"
  : > "$BATS_TEST_TMPDIR/as_claude"
  start_chat
  run grep -- "HC_OPENING_PROMPT" "$BATS_TEST_TMPDIR/as_claude"
  [ "$status" -eq 1 ]
}

@test "restart_chat ends the session and passes the opening prompt on" {
  load_lib options env session
  as_claude() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/as_claude"; [[ "$*" != *has-session* ]]; }
  restart_chat "Say hello to the owner"
  grep -q -- "kill-session" "$BATS_TEST_TMPDIR/as_claude"
  grep -q -- "-e HC_OPENING_PROMPT=Say hello to the owner" "$BATS_TEST_TMPDIR/as_claude"
}

@test "the opening prompt is used for the first start only" {
  load_lib options session
  mkdir -p "$HC_WORKSPACE"
  export HC_OPENING_PROMPT="Say hello to the owner"
  next_chat_argv
  [ "${CHAT_ARGV[0]}" = "claude" ]
  [ "${CHAT_ARGV[${#CHAT_ARGV[@]}-1]}" = "Say hello to the owner" ]
  [ -z "${HC_OPENING_PROMPT:-}" ]
  next_chat_argv
  [ "${CHAT_ARGV[0]}" = "claude" ]
  [[ "${CHAT_ARGV[*]}" != *"Say hello"* ]]
}

@test "with an opening prompt a session that appeared in between is ended, so the prompt is not lost" {
  load_lib options env session
  as_claude() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/as_claude"; [[ "$*" != *new-session* ]] || return 0; }
  start_chat "Say hello to the owner"
  [ "$(grep -c -- "kill-session" "$BATS_TEST_TMPDIR/as_claude")" -eq 1 ]
  grep -q -- "-e HC_OPENING_PROMPT=Say hello to the owner" "$BATS_TEST_TMPDIR/as_claude"
  : > "$BATS_TEST_TMPDIR/as_claude"
  start_chat
  run grep -- "new-session\|kill-session" "$BATS_TEST_TMPDIR/as_claude"
  [ "$status" -eq 1 ]
}

@test "a chat session that cannot be started is tried once more, and the failure is logged" {
  load_lib options env session
  as_claude() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/as_claude"; return 1; }
  run start_chat
  [ "$(grep -c -- "new-session" "$BATS_TEST_TMPDIR/as_claude")" -eq 2 ]
  [[ "$output" == *"could not be started"* ]]
}

@test "a new chat session starts from a handover folder with nothing that reads as instructions" {
  load_lib options env retention session
  mkdir -p "$HC_HANDOVER"; touch "$HC_HANDOVER/CLAUDE.md"
  as_claude() { [[ "$*" != *has-session* ]]; }
  start_chat 2>/dev/null
  [ ! -e "$HC_HANDOVER/CLAUDE.md" ]
}

