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

# A morning lock that survived a crash or a restart would refuse every later
# morning command. Called once at start-up, before any command is read.
clear_stale_locks() {
  rmdir "$HC_STATE/morning.lock" 2>/dev/null || true
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
      restart_chat
      raise_outcome sync ok
      ;;
    restart-chat)
      restart_chat
      raise_outcome restart-chat ok
      ;;
    morning)
      if ! mkdir "$HC_STATE/morning.lock" 2>/dev/null; then
        log "commands: a morning run is already in progress"
        raise_outcome morning busy
        return 0
      fi
      # Not implemented yet.
      rmdir "$HC_STATE/morning.lock"
      raise_outcome morning not_implemented
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
