# Commands arrive on the add-on's standard input, one per line, from Home
# Assistant's stdin action. The action sends the input JSON-encoded.

parse_command() {
  local line="${1//$'\r'/}" word
  word="$(jq -r 'if type == "string" then . elif type == "object" then (.command // "") else "" end' \
            <<<"$line" 2>/dev/null)" || word=""
  if [[ -z "$word" && "$line" =~ ^[a-z-]+$ ]]; then
    word="$line"
  fi
  printf '%s' "$word"
}

# read_command <seconds> <variable> - reads one command from standard input
# into the named variable, waiting at most the given number of seconds.
# Returns 0 with a command, 2 on a timeout, and 1 when standard input is
# closed. A line that has only partly arrived when the wait ends is kept and
# completed by the next call, unless a whole wait passes without anything
# new. A last line without a line ending is returned when standard input
# closes.
HC_PARTIAL=""
read_command() {
  local _rc_chunk="" _rc_status=0
  IFS= read -r -t "$1" _rc_chunk || _rc_status=$?
  if (( _rc_status == 0 )); then
    printf -v "$2" '%s' "$HC_PARTIAL$_rc_chunk"
    HC_PARTIAL=""
    return 0
  fi
  if (( _rc_status > 128 )); then
    # A whole wait without anything new: the rest is not coming.
    if [[ -z "$_rc_chunk" && -n "$HC_PARTIAL" ]]; then
      log "commands: dropping an unfinished command"
      HC_PARTIAL=""
    fi
    HC_PARTIAL+="$_rc_chunk"
    return 2
  fi
  HC_PARTIAL+="$_rc_chunk"
  if [[ -n "$HC_PARTIAL" ]]; then
    printf -v "$2" '%s' "$HC_PARTIAL"
    HC_PARTIAL=""
    return 0
  fi
  return 1
}

handle_command() {
  local word
  mkdir -p "$HC_STATE"
  word="$(parse_command "$1")"
  case "$word" in
    ping)
      raise_outcome ping ok
      ;;
    sync)
      sync_workspace
      ensure_layout
      install_managed_settings
      if ! restart_chat; then
        raise_outcome sync failed
      elif [[ "${HC_SYNC_RESULT:-ok}" == kept ]]; then
        raise_outcome sync kept
      else
        raise_outcome sync ok
      fi
      ;;
    restart-chat)
      if restart_chat; then
        raise_outcome restart-chat ok
      else
        raise_outcome restart-chat failed
      fi
      ;;
    morning)
      # The run is waited for here: until it has ended, no other command is
      # handled, so a second "morning" runs after the first one.
      local outcome=failed
      log "commands: the morning run starts"
      run_morning outcome
      if [[ "$outcome" != not_configured ]] && ! restart_chat "$(opening_prompt "$outcome")"; then
        log "commands: there is no chat session to present the morning run"
      fi
      raise_outcome morning "$outcome"
      ;;
    "")
      [[ -n "${1//[[:space:]]/}" ]] && log "commands: ignoring malformed command"
      ;;
    *)
      log "commands: ignoring unknown command"
      ;;
  esac
  return 0
}
