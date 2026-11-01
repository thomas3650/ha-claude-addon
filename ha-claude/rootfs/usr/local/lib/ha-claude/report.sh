# The report command: runs the working folder's .claude/report as the Claude
# user and writes what it prints to the add-on's log, framed, limited and
# cleaned. The add-on trusts nothing the file prints: a line of the output
# can never pass for a line of the add-on's own, and the log is kept by Home
# Assistant, so the file must print nothing personal.
: "${HC_LIMIT_BIN:=/usr/local/bin/ha-claude-limit}"
: "${HC_REPORT_LIMIT:=30}"
: "${HC_REPORT_GRACE:=5}"
: "${HC_REPORT_LINES:=200}"
: "${HC_REPORT_CHARS:=200}"
# The most the file may print, in KiB: 200 lines of 200 characters need
# 40, and the frame reads a pipe one byte at a time, so a flood of empty
# lines must be stopped before it is read. The same cap on both ends: the
# file is cut off at it (SIGXFSZ, so the outcome is failed), and the frame
# never reads past it.
: "${HC_REPORT_KIB:=256}"
HC_REPORT_FILE=.claude/report

# True when the report file is a regular file, not a link, in the working
# folder's own .claude folder, and the Claude user can read and run it. Root
# passes any execute bit, so the last check runs as the Claude user.
report_configured() {
  local src="$HC_WORKSPACE/$HC_REPORT_FILE" real_dir real_ws
  [[ -f "$src" && ! -L "$src" ]] || return 1
  real_dir="$(cd -P "$(dirname "$src")" 2>/dev/null && pwd -P)" || return 1
  real_ws="$(cd -P "$HC_WORKSPACE" 2>/dev/null && pwd -P)" || return 1
  [[ "$real_dir" == "$real_ws/.claude" ]] || return 1
  as_claude test -r "$src" -a -x "$src" </dev/null >/dev/null 2>&1
}

# _report_frame [label] [lines] [chars] [KiB] - reads the file's output on
# standard input and prints it framed: a first and a last line of the
# add-on's own, every line of the output behind a prefix ("report: | " by
# default), at most HC_REPORT_LINES lines of at most HC_REPORT_CHARS
# characters from at most HC_REPORT_KIB KiB, unless other limits are
# given, control characters (C0, DEL and C1) removed,
# empty lines left out. Bytes that are not UTF-8 are dropped first, so the
# counting is in characters and a cut cannot split one. The C0 characters
# and the empty lines go before the loop, in tr and grep, because the loop
# reads a pipe one byte at a time and a flood of empty lines would keep it
# busy for seconds on a small machine.
_report_frame() {
  # shellcheck disable=SC2034  # read by bash itself
  local LC_ALL=C.UTF-8
  local label="${1:-report}" max="${2:-$HC_REPORT_LINES}" chars="${3:-$HC_REPORT_CHARS}"
  local kib="${4:-$HC_REPORT_KIB}" line n=0 more=0
  printf '%s: begin\n' "$label"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//[[:cntrl:]]/}"
    line="${line//[$'\xc2\x80'-$'\xc2\x9f']/}"
    [[ -n "$line" ]] || continue
    if (( n >= max )); then more=1; break; fi
    n=$((n + 1))
    printf '%s: | %s\n' "$label" "${line:0:chars}"
  done < <(head -c "$((kib * 1024))" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null \
           | tr -d '\000-\011\013-\037\177' | grep -av '^$')
  if (( more )); then
    printf '%s: end, %d lines, more left out\n' "$label" "$n"
  else
    printf '%s: end, %d lines\n' "$label" "$n"
  fi
}

# run_report <variable> [month] - runs the report file, with the month as
# its only argument when one is given, and stores the outcome in the named
# variable: ok, failed or not_configured. The outcome is not printed, for
# the reason run_morning gives. What the file prints goes to a file only
# root can read, and from there, framed, to the log; what it prints on
# standard error is thrown away, because an error can quote the data it
# failed on.
run_report() {
  local _rr_month="${2:-}" _rr_src="$HC_WORKSPACE/$HC_REPORT_FILE" _rr_out="$HC_STATE/report.out" _rr_rc=0
  local -a _rr_args=()
  if [[ -n "$_rr_month" && ! "$_rr_month" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
    log "report: the argument is not a month"
    printf -v "$1" '%s' failed
    return 0
  fi
  if ! report_configured; then
    printf -v "$1" '%s' not_configured
    return 0
  fi
  [[ -n "$_rr_month" ]] && _rr_args=("$_rr_month")
  mkdir -p "$HC_STATE"
  rm -f "$_rr_out"
  ( umask 077; : > "$_rr_out" )
  # Both the soft and the hard file-size limit, so the file cannot raise it.
  ( cd "$HC_WORKSPACE" && ulimit -f "$HC_REPORT_KIB" && as_claude env HC_LIMIT_GRACE="$HC_REPORT_GRACE" \
      "$HC_LIMIT_BIN" "$HC_REPORT_LIMIT" "$_rr_src" "${_rr_args[@]}" \
  ) </dev/null >>"$_rr_out" 2>/dev/null &
  wait $! || _rr_rc=$?
  if (( _rr_rc == 0 )); then
    _report_frame < "$_rr_out" | log_lines
    printf -v "$1" '%s' ok
  elif (( _rr_rc == 124 )); then
    log "report: failed with status 124, the time limit"
    printf -v "$1" '%s' failed
  else
    log "report: failed with status $_rr_rc"
    printf -v "$1" '%s' failed
  fi
  rm -f "$_rr_out"
  return 0
}
