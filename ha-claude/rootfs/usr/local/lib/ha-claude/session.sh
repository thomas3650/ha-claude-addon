# The chat session: Claude Code with Remote Control in tmux, as the
# Claude user. A session is started fresh, unless the option chat_resume is
# on: then it continues the last conversation (--continue), except when it
# opens with a prompt or a clear had to become a restart.

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

# True when the option chat_resume is on. The Claude user cannot read the
# options; start_chat passes the option in as HC_CHAT_RESUME.
chat_resume_on() {
  [[ "${HC_CHAT_RESUME:-$(opt_bool '.chat_resume' false)}" == true ]]
}

# Prints the argv for the chat session, one argument per line. The mode is
# the managed settings' when they set one; the date line is left out when
# their SessionStart hook gives the date at each conversation. With
# chat_resume on, the last conversation is continued, unless an opening
# prompt is given (it belongs to a new conversation), HC_CHAT_FRESH asks for
# a new one, or continuing has just failed (HC_RESUME_FAILED).
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
  if [[ -n "${1:-}" ]]; then
    argv+=("$1")
  elif chat_resume_on && [[ -z "${HC_CHAT_FRESH:-}" && -z "${HC_RESUME_FAILED:-}" ]]; then
    argv+=(--continue)
  fi
  printf '%s\n' "${argv[@]}"
}

# Fills the array CHAT_ARGV with the argv for the chat session, and sets
# CHAT_RESUMING to 1 when it continues the last conversation, 0 otherwise.
# An opening prompt in HC_OPENING_PROMPT, and HC_CHAT_FRESH and
# HC_RESUME_FAILED, are used by the first call only: when Claude Code is
# started again in the same session, the prompt is not given again, and the
# last conversation is continued again.
next_chat_argv() {
  mapfile -t CHAT_ARGV < <(chat_command "${HC_OPENING_PROMPT:-}")
  CHAT_RESUMING=0
  [[ "${CHAT_ARGV[${#CHAT_ARGV[@]}-1]}" == --continue ]] && CHAT_RESUMING=1
  unset HC_OPENING_PROMPT HC_CHAT_FRESH HC_RESUME_FAILED
}

# chat_resume_failed <seconds the last run took> - true when the last run
# continued a conversation and ended within thirty seconds: most likely
# there was none to continue. It then sets HC_RESUME_FAILED, so the next
# start is a new conversation. The chat loop starts that at once and does
# not count the quick exit towards giving up; a new conversation that also
# ends quickly does count, so the loop still gives up.
chat_resume_failed() {
  local took="$1"
  [[ "$took" =~ ^[0-9]+$ ]] || took=0
  [[ "${CHAT_RESUMING:-0}" == 1 ]] && (( took < 30 )) || return 1
  HC_RESUME_FAILED=1
}

chat_alive() {
  as_claude tmux -L "$HC_TMUX_SOCKET" has-session -t "$HC_TMUX_SESSION" 2>/dev/null
}

# start_chat [opening prompt] [fresh] - does nothing when a session is
# running, unless a prompt or "fresh" is given: a session that the web
# terminal started in the meantime has no prompt and may have continued the
# last conversation, so it is ended and replaced. With "fresh" the session
# starts a new conversation also when chat_resume is on.
start_chat() {
  local entry prompt="${1:-}" fresh="${2:-}" try
  local -a extra=()
  [[ -z "$prompt" && -z "$fresh" ]] && chat_alive && return 0
  declare -F clean_handover >/dev/null && clean_handover
  log "chat: starting a new session"
  while IFS= read -r entry; do
    extra+=(-e "$entry")
  done < <(assistant_env)
  [[ -n "$prompt" ]] && extra+=(-e "HC_OPENING_PROMPT=$prompt")
  [[ -n "$fresh" ]] && extra+=(-e "HC_CHAT_FRESH=1")
  # The workspace's SessionStart hook may write here; see clear_chat.
  as_claude mkdir -p "$(dirname "$HC_SESSION_MARK")" 2>/dev/null || true
  for try in 1 2; do
    if chat_alive; then
      [[ -z "$prompt" && -z "$fresh" ]] && return 0
      as_claude tmux -L "$HC_TMUX_SOCKET" kill-session -t "$HC_TMUX_SESSION" 2>/dev/null || true
    fi
    as_claude tmux -L "$HC_TMUX_SOCKET" new-session -d -s "$HC_TMUX_SESSION" \
      -e "HC_SESSION_NAME=$(opt '.session_name' 'Home')" \
      -e "HC_CHAT_RESUME=$(opt_bool '.chat_resume' false)" \
      -e "HA_CLAUDE_SESSION_MARK=$HC_SESSION_MARK" \
      "${extra[@]}" \
      -c "$HC_WORKSPACE" /usr/local/bin/ha-claude-chat && return 0
    (( try == 1 )) && sleep 1
  done
  log "chat: a new session could not be started"
  return 1
}

# restart_chat [opening prompt] [fresh] - see start_chat.
restart_chat() {
  as_claude tmux -L "$HC_TMUX_SOCKET" kill-session -t "$HC_TMUX_SESSION" 2>/dev/null || true
  start_chat "${1:-}" "${2:-}"
}

# clear_chat [opening prompt] - a new conversation in the Claude Code that
# runs, so the Claude app keeps one session. It needs the workspace to give
# the date at each conversation (a SessionStart hook) and Claude Code in the
# pane, and the hook's mark to confirm the clear; anything else is a restart
# with a new conversation, also when chat_resume is on.
# Escape ends a turn that is running and Ctrl-U a half-typed line, as a
# restart does.
: "${HC_CLEAR_WAIT:=15}"
# The mark is in the Claude user's home, so it is read only when it is a
# plain file, and with a time limit: a pipe or a link put in its place must
# not hold up the add-on's commands.
_clear_seen() {
  local line src at
  [[ -f "$HC_SESSION_MARK" && ! -L "$HC_SESSION_MARK" ]] || return 1
  if command -v timeout >/dev/null 2>&1; then
    line="$(timeout 2 head -c 64 -- "$HC_SESSION_MARK" 2>/dev/null)" || return 1
  else
    line="$(head -c 64 -- "$HC_SESSION_MARK" 2>/dev/null)" || return 1
  fi
  read -r src at <<<"$line"
  [[ "$src" == clear && "$at" =~ ^[0-9]+$ ]] && (( at >= $1 ))
}
# True when Claude Code runs in the chat's pane. The pane runs the chat
# loop, a shell, so its own command is always bash: Claude Code is a
# process on the pane's terminal started with --remote-control, however
# deep below the shell. Between two runs there is only a sleep, and after
# three quick exits a login shell.
_pane_runs_claude() {
  local tty
  tty="$(as_claude tmux -L "$HC_TMUX_SOCKET" display-message -p -t "$HC_TMUX_SESSION" \
           '#{pane_tty}' 2>/dev/null)" || return 1
  [[ "$tty" =~ ^/dev/(pts/[0-9]+)$ ]] || return 1
  pgrep -t "${BASH_REMATCH[1]}" -f -- '--remote-control=' >/dev/null 2>&1
}
_chat_keys() {
  as_claude tmux -L "$HC_TMUX_SOCKET" send-keys -t "$HC_TMUX_SESSION" "$@"
}
clear_chat() {
  local prompt="${1:-}" since waited=0
  if ! managed_session_hook || ! chat_alive; then
    restart_chat "$prompt" fresh
    return
  fi
  if ! _pane_runs_claude; then
    log "chat: Claude Code is not running in the pane; restarting"
    restart_chat "$prompt" fresh
    return
  fi
  # A mark from an earlier clear must not confirm this one.
  as_claude rm -f "$HC_SESSION_MARK" 2>/dev/null || true
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
    restart_chat "$prompt" fresh
    return
  fi
  declare -F clean_handover >/dev/null && clean_handover
  if [[ -n "$prompt" ]]; then
    as_claude tmux -L "$HC_TMUX_SOCKET" set-buffer -b hc-opening -- "$prompt"
    as_claude tmux -L "$HC_TMUX_SOCKET" paste-buffer -p -d -b hc-opening -t "$HC_TMUX_SESSION"
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
