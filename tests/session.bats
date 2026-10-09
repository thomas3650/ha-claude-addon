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
