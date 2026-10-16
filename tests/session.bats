load helpers

@test "chat_command names the session and passes today's date and handover file" {
  load_lib options session
  export HC_MANAGED_DIR="$BATS_TEST_TMPDIR/managed"
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


@test "a chat run shorter than thirty seconds counts towards giving up, and a longer one starts the count again" {
  load_lib options session
  [ "$(chat_quick_exits 0 3)" = 1 ]
  [ "$(chat_quick_exits 1 29)" = 2 ]
  [ "$(chat_quick_exits 2 0)" = 3 ]
  [ "$(chat_quick_exits 2 30)" = 0 ]
  [ "$(chat_quick_exits 2 4000)" = 0 ]
  # Anything that is not a count or a time is taken as a quick exit from nothing.
  [ "$(chat_quick_exits x y)" = 1 ]
  [ "$(chat_quick_exits '' '')" = 1 ]
}

@test "the chat loop counts with that rule, leaves a shell after three quick exits, and waits before every other restart" {
  chat="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/ha-claude-chat"
  grep -q 'quick_exits="$(chat_quick_exits "$quick_exits" "$((SECONDS - started))")"' "$chat"
  grep -q 'if (( quick_exits >= 3 )); then' "$chat"
  # A count that is no number gives up at once, and nothing else changes it.
  grep -q '\[\[ "$quick_exits" =~ ^\[0-9\]+$ \]\] || quick_exits=3' "$chat"
  [ "$(grep -c 'quick_exits=' "$chat")" -eq 3 ]
  give_up="$(grep -n 'quick_exits >= 3' "$chat" | cut -d: -f1)"
  shell="$(grep -n 'exec bash -l' "$chat" | tail -n 1 | cut -d: -f1)"
  wait="$(grep -n 'sleep 10' "$chat" | cut -d: -f1)"
  [ "$give_up" -lt "$shell" ] && [ "$shell" -lt "$wait" ]
}

# managed JSON - installs managed settings for the test.
managed() { mkdir -p "$HC_MANAGED_DIR"; printf '%s' "$1" > "$HC_MANAGED_DIR/managed-settings.json"; }
HOOKED='{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"x"}]}]}}'

@test "chat_command keeps the default mode and the date line when the managed settings give neither" {
  load_lib options session
  export HC_MANAGED_DIR="$BATS_TEST_TMPDIR/managed"
  mkdir -p "$HC_WORKSPACE"
  managed '{"permissions":{"disableBypassPermissionsMode":"disable"}}'
  run chat_command
  [[ "$output" == *$'--permission-mode\ndefault'* ]]
  [[ "$output" == *"Today is"* ]]
}

@test "chat_command leaves the mode to managed settings that set one, and the date to their SessionStart hook" {
  load_lib options session
  export HC_MANAGED_DIR="$BATS_TEST_TMPDIR/managed"
  mkdir -p "$HC_WORKSPACE"
  managed '{"permissions":{"defaultMode":"auto"},"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"x"}]}]}}'
  run chat_command
  [[ "$output" != *"--permission-mode"* ]]
  [[ "$output" != *"Today is"* ]]
  [[ "$output" == *"--remote-control="* ]]
}

@test "start_chat gives the chat session the path of the session mark" {
  load_lib options env session
  as_claude() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/as_claude"; [[ "$*" != *has-session* ]]; }
  start_chat
  grep -q -- "-e HA_CLAUDE_SESSION_MARK=$HC_SESSION_MARK" "$BATS_TEST_TMPDIR/as_claude"
}

@test "clear_chat restarts, with the opening, when the managed settings have no SessionStart hook" {
  load_lib options env session
  export HC_MANAGED_DIR="$BATS_TEST_TMPDIR/managed"
  chat_alive() { return 0; }
  restart_chat() { echo "restart:${1:-}" > "$BATS_TEST_TMPDIR/r"; }
  as_claude() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/as_claude"; }
  clear_chat "hello"
  [ "$(cat "$BATS_TEST_TMPDIR/r")" = "restart:hello" ]
  [ ! -e "$BATS_TEST_TMPDIR/as_claude" ]
}

@test "clear_chat restarts when no chat session runs" {
  load_lib options env session
  export HC_MANAGED_DIR="$BATS_TEST_TMPDIR/managed"
  managed "$HOOKED"
  chat_alive() { return 1; }
  restart_chat() { echo restart > "$BATS_TEST_TMPDIR/r"; }
  clear_chat
  [ -f "$BATS_TEST_TMPDIR/r" ]
}

@test "clear_chat sends no key to a pane that does not run Claude Code, and restarts" {
  load_lib options env session
  export HC_MANAGED_DIR="$BATS_TEST_TMPDIR/managed"
  managed "$HOOKED"
  chat_alive() { return 0; }
  as_claude() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/as_claude"; [[ "$*" == *display-message* ]] && echo bash; return 0; }
  restart_chat() { echo restart > "$BATS_TEST_TMPDIR/r"; }
  run clear_chat
  [ -f "$BATS_TEST_TMPDIR/r" ]
  run grep -- "send-keys" "$BATS_TEST_TMPDIR/as_claude"
  [ "$status" -eq 1 ]
}

@test "clear_chat sends /clear, then the opening, when the hook's mark confirms the clear" {
  load_lib options env session
  export HC_MANAGED_DIR="$BATS_TEST_TMPDIR/managed" HC_CLEAR_WAIT=3
  managed "$HOOKED"
  chat_alive() { return 0; }
  sleep() { :; }
  as_claude() {
    printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/as_claude"
    [[ "$*" == *display-message* ]] && echo claude
    if [[ "$*" == *"-l /clear"* ]]; then
      mkdir -p "$(dirname "$HC_SESSION_MARK")"
      echo "clear $(date +%s)" > "$HC_SESSION_MARK"
    fi
    return 0
  }
  restart_chat() { echo restart > "$BATS_TEST_TMPDIR/r"; }
  clear_chat "Present the summary"
  [ ! -e "$BATS_TEST_TMPDIR/r" ]
  grep -q -- "send-keys -t chat Escape" "$BATS_TEST_TMPDIR/as_claude"
  grep -q -- "send-keys -t chat -l /clear" "$BATS_TEST_TMPDIR/as_claude"
  grep -q -- "set-buffer -b hc-opening -- Present the summary" "$BATS_TEST_TMPDIR/as_claude"
  grep -q -- "paste-buffer -p -d -b hc-opening -t chat" "$BATS_TEST_TMPDIR/as_claude"
}

@test "clear_chat without an opening pastes nothing" {
  load_lib options env session
  export HC_MANAGED_DIR="$BATS_TEST_TMPDIR/managed" HC_CLEAR_WAIT=3
  managed "$HOOKED"
  chat_alive() { return 0; }
  sleep() { :; }
  as_claude() {
    printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/as_claude"
    [[ "$*" == *display-message* ]] && echo claude
    [[ "$*" == *"-l /clear"* ]] && { mkdir -p "$(dirname "$HC_SESSION_MARK")"; echo "clear $(date +%s)" > "$HC_SESSION_MARK"; }
    return 0
  }
  clear_chat
  run grep -- "paste-buffer" "$BATS_TEST_TMPDIR/as_claude"
  [ "$status" -eq 1 ]
}

@test "clear_chat restarts with the opening when no mark comes, or only an old one or one from a start" {
  load_lib options env session
  export HC_MANAGED_DIR="$BATS_TEST_TMPDIR/managed" HC_CLEAR_WAIT=2
  managed "$HOOKED"
  chat_alive() { return 0; }
  sleep() { :; }
  as_claude() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/as_claude"; [[ "$*" == *display-message* ]] && echo claude; return 0; }
  restart_chat() { echo "restart:${1:-}" > "$BATS_TEST_TMPDIR/r"; }
  clear_chat "hello"
  [ "$(cat "$BATS_TEST_TMPDIR/r")" = "restart:hello" ]
  rm "$BATS_TEST_TMPDIR/r"
  mkdir -p "$(dirname "$HC_SESSION_MARK")"
  echo "clear 1" > "$HC_SESSION_MARK"
  clear_chat
  [ -f "$BATS_TEST_TMPDIR/r" ]
  rm "$BATS_TEST_TMPDIR/r"
  echo "startup $(( $(date +%s) + 100 ))" > "$HC_SESSION_MARK"
  clear_chat
  [ -f "$BATS_TEST_TMPDIR/r" ]
}

@test "clear_chat removes an earlier mark before it sends the keys, and takes no pipe or link for a mark" {
  load_lib options env session
  export HC_MANAGED_DIR="$BATS_TEST_TMPDIR/managed" HC_CLEAR_WAIT=1
  managed "$HOOKED"
  chat_alive() { return 0; }
  sleep() { :; }
  as_claude() {
    printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/as_claude"
    [[ "$*" == *display-message* ]] && echo claude
    return 0
  }
  restart_chat() { echo restart > "$BATS_TEST_TMPDIR/r"; }
  clear_chat
  rm_line="$(grep -n -- "rm -f $HC_SESSION_MARK" "$BATS_TEST_TMPDIR/as_claude" | cut -d: -f1)"
  esc_line="$(grep -n -- "send-keys -t chat Escape" "$BATS_TEST_TMPDIR/as_claude" | cut -d: -f1)"
  [ -n "$rm_line" ] && [ "$rm_line" -lt "$esc_line" ]
  mkdir -p "$(dirname "$HC_SESSION_MARK")"
  echo "clear $(( $(date +%s) + 100 ))" > "$BATS_TEST_TMPDIR/real"
  ln -s "$BATS_TEST_TMPDIR/real" "$HC_SESSION_MARK"
  run _clear_seen 0
  [ "$status" -ne 0 ]
  rm "$HC_SESSION_MARK"
  mkfifo "$HC_SESSION_MARK"
  run _clear_seen 0
  [ "$status" -ne 0 ]
}
