# The chat session: Claude Code with Remote Control in tmux, as the
# Claude user. A session is always started fresh, never resumed.

HC_TMUX_SOCKET=hc
HC_TMUX_SESSION=chat

logged_in() {
  [[ -f "$HC_HOME/.claude/.credentials.json" ]]
}

# What the workspace's managed settings, as installed, decide. The add-on
# stays out of the way of a choice they make, and keeps its own otherwise.
_managed_has() {
  jq -e "$1" "$HC_MANAGED_DIR/managed-settings.json" >/dev/null 2>&1
}
managed_mode_set() { _managed_has '.permissions.defaultMode | strings'; }
managed_session_hook() { _managed_has '(.hooks.SessionStart // []) | arrays | length > 0'; }

# Prints the argv for the chat session, one argument per line. The mode is
# the managed settings' when they set one; the date line is left out when
# their SessionStart hook gives the date at each conversation.
chat_command() {
  local name today
  # The Claude user cannot read the options; start_chat passes the name in.
  name="${HC_SESSION_NAME:-$(opt '.session_name' 'Home')}"
  today="$(date +%F)"
  local -a argv=(claude "--remote-control=$name")
  managed_mode_set || argv+=(--permission-mode default)
  managed_session_hook \
    || argv+=(--append-system-prompt "Today is $today. Today's handover file is $HC_HANDOVER/$today.md.")
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

# start_chat [opening prompt] - does nothing when a session is running,
# unless a prompt is given: a session that the web terminal started in the
# meantime has no prompt, so it is ended and replaced.
start_chat() {
  local entry prompt="${1:-}" try
  local -a extra=()
  [[ -z "$prompt" ]] && chat_alive && return 0
  declare -F clean_handover >/dev/null && clean_handover
  log "chat: starting a new session"
  while IFS= read -r entry; do
    extra+=(-e "$entry")
  done < <(assistant_env)
  [[ -n "$prompt" ]] && extra+=(-e "HC_OPENING_PROMPT=$prompt")
  # The workspace's SessionStart hook may write here; see clear_chat.
  as_claude mkdir -p "$(dirname "$HC_SESSION_MARK")" 2>/dev/null || true
  for try in 1 2; do
    if chat_alive; then
      [[ -z "$prompt" ]] && return 0
      as_claude tmux -L "$HC_TMUX_SOCKET" kill-session -t "$HC_TMUX_SESSION" 2>/dev/null || true
    fi
    as_claude tmux -L "$HC_TMUX_SOCKET" new-session -d -s "$HC_TMUX_SESSION" \
      -e "HC_SESSION_NAME=$(opt '.session_name' 'Home')" \
      -e "HA_CLAUDE_SESSION_MARK=$HC_SESSION_MARK" \
      "${extra[@]}" \
      -c "$HC_WORKSPACE" /usr/local/bin/ha-claude-chat && return 0
    (( try == 1 )) && sleep 1
  done
  log "chat: a new session could not be started"
  return 1
}

# restart_chat [opening prompt]
restart_chat() {
  as_claude tmux -L "$HC_TMUX_SOCKET" kill-session -t "$HC_TMUX_SESSION" 2>/dev/null || true
  start_chat "${1:-}"
}

# clear_chat [opening prompt] - a new conversation in the Claude Code that
# runs, so the Claude app keeps one session. It needs the workspace to give
# the date at each conversation (a SessionStart hook) and Claude Code in the
# pane, and the hook's mark to confirm the clear; anything else is a restart.
# Escape ends a turn that is running and Ctrl-U a half-typed line, as a
# restart does.
: "${HC_CLEAR_WAIT:=15}"
_clear_seen() {
  local src at
  read -r src at < "$HC_SESSION_MARK" 2>/dev/null || return 1
  [[ "$src" == clear && "$at" =~ ^[0-9]+$ ]] && (( at >= $1 ))
}
_chat_keys() {
  as_claude tmux -L "$HC_TMUX_SOCKET" send-keys -t "$HC_TMUX_SESSION" "$@"
}
clear_chat() {
  local prompt="${1:-}" cmd since waited=0
  if ! managed_session_hook || ! chat_alive; then
    restart_chat "$prompt"
    return
  fi
  cmd="$(as_claude tmux -L "$HC_TMUX_SOCKET" display-message -p -t "$HC_TMUX_SESSION" \
           '#{pane_current_command}' 2>/dev/null)" || cmd=""
  if [[ "$cmd" != claude ]]; then
    log "chat: the pane runs '${cmd:0:40}', not Claude Code; restarting"
    restart_chat "$prompt"
    return
  fi
  since="$(date +%s)"
  _chat_keys Escape
  sleep 0.5
  _chat_keys C-u
  _chat_keys -l /clear
  _chat_keys Enter
  until _clear_seen "$since"; do
    (( waited >= HC_CLEAR_WAIT )) && break
    sleep 1
    waited=$((waited + 1))
  done
  if ! _clear_seen "$since"; then
    log "chat: the clear was not confirmed; restarting"
    restart_chat "$prompt"
    return
  fi
  declare -F clean_handover >/dev/null && clean_handover
  if [[ -n "$prompt" ]]; then
    as_claude tmux -L "$HC_TMUX_SOCKET" set-buffer -b hc-opening -- "$prompt"
    as_claude tmux -L "$HC_TMUX_SOCKET" paste-buffer -d -b hc-opening -t "$HC_TMUX_SESSION"
    sleep 0.5
    _chat_keys Enter
  fi
  log "chat: a new conversation"
}

# chat_quick_exits <count so far> <seconds the last run took> - prints the
# new count of runs in a row that ended within thirty seconds. A longer run
# starts the count again. The chat loop leaves a shell when it reaches three:
# Claude Code that cannot start is not started for ever.
chat_quick_exits() {
  local count="$1" took="$2"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  [[ "$took" =~ ^[0-9]+$ ]] || took=0
  if (( took < 30 )); then
    printf '%s' "$((count + 1))"
  else
    printf '0'
  fi
}
