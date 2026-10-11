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

# log_lines - reads lines on standard input and writes them to the log with
# the time, in one printf, so a block stays together as far as a pipe
# allows. Nothing is written for no input.
log_lines() {
  local block="" line stamp
  stamp="$(date +%H:%M:%S)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    block+="[$stamp] $line"$'\n'
  done
  [[ -n "$block" ]] || return 0
  if [[ -n "${HC_LOG:-}" ]] && printf '%s' "$block" 2>/dev/null >>"$HC_LOG"; then
    return 0
  fi
  printf '%s' "$block" >&2
}
