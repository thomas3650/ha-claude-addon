# Log lines go to standard error, which is the add-on's log. A script that
# does not run under the main process sets HC_LOG to reach that log.
log() {
  local line
  line="$(printf '[%s] %s' "$(date +%H:%M:%S)" "$*")"
  if [[ -n "${HC_LOG:-}" ]] && printf '%s\n' "$line" 2>/dev/null >>"$HC_LOG"; then
    return 0
  fi
  printf '%s\n' "$line" >&2
}
