# The chat session: Claude Code with Remote Control in tmux, as the
# Claude user. A session is always started fresh, never resumed.

HC_TMUX_SOCKET=hc
HC_TMUX_SESSION=chat

logged_in() {
  [[ -f "$HC_HOME/.claude/.credentials.json" ]]
}

# Prints the argv for the chat session, one argument per line.
chat_command() {
  local name today
  # The Claude user cannot read the options; start_chat passes the name in.
  name="${HC_SESSION_NAME:-$(opt '.session_name' 'Home')}"
  today="$(date +%F)"
  local -a argv=(
    claude
    "--remote-control=$name"
    --permission-mode default
    --append-system-prompt "Today is $today. Today's handover file is $HC_HANDOVER/$today.md."
  )
  [[ -f "$HC_WORKSPACE/.claude/agents/chat.md" ]] && argv+=(--agent chat)
  [[ -n "${1:-}" ]] && argv+=("$1")
  printf '%s\n' "${argv[@]}"
}

# Fills the array CHAT_ARGV with the argv for the chat session. An opening
# prompt in HC_OPENING_PROMPT is used by the first call only: when Claude
# Code is started again in the same session, the prompt is not given again.
next_chat_argv() {
  # shellcheck disable=SC2034  # read by ha-claude-chat
  mapfile -t CHAT_ARGV < <(chat_command "${HC_OPENING_PROMPT:-}")
  unset HC_OPENING_PROMPT
}

chat_alive() {
  as_claude tmux -L "$HC_TMUX_SOCKET" has-session -t "$HC_TMUX_SESSION" 2>/dev/null
}

# start_chat [opening prompt]
start_chat() {
  local entry prompt="${1:-}"
  local -a extra=()
  chat_alive && return 0
  log "chat: starting a new session"
  while IFS= read -r entry; do
    extra+=(-e "$entry")
  done < <(assistant_env)
  [[ -n "$prompt" ]] && extra+=(-e "HC_OPENING_PROMPT=$prompt")
  as_claude tmux -L "$HC_TMUX_SOCKET" new-session -d -s "$HC_TMUX_SESSION" \
    -e "HC_SESSION_NAME=$(opt '.session_name' 'Home')" \
    "${extra[@]}" \
    -c "$HC_WORKSPACE" /usr/local/bin/ha-claude-chat
}

# restart_chat [opening prompt]
restart_chat() {
  as_claude tmux -L "$HC_TMUX_SOCKET" kill-session -t "$HC_TMUX_SESSION" 2>/dev/null || true
  start_chat "${1:-}"
}
