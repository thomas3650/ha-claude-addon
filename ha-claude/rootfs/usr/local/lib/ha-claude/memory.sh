# The memory command: writes the chat's memory to the add-on's log, framed
# as the report is, so that it can be read and tidied from outside. The
# memory is the Markdown files Claude Code keeps for the working folder in
# the Claude user's home, ~/.claude/projects/<folder>/memory/*.md. The
# Claude user reads them, never root: the folder is the Claude user's, and a
# link in it must not let root print a file only root can read, such as the
# add-on's options. Links, pipes and anything else that is not a regular
# file are passed over, and the reading has a time limit.
: "${HC_LIMIT_BIN:=/usr/local/bin/ha-claude-limit}"
: "${HC_MEMORY_LIMIT:=30}"
: "${HC_MEMORY_GRACE:=5}"
: "${HC_MEMORY_LINES:=2000}"
: "${HC_MEMORY_CHARS:=500}"
: "${HC_MEMORY_KIB:=1024}"

# The memory folder, named as Claude Code names a project: the working
# folder's path with every character that is not a letter or a digit made
# a "-", so /data/workspace/assistant is -data-workspace-assistant.
memory_dir() {
  printf '%s' "$HC_HOME/.claude/projects/${HC_WORKSPACE//[^A-Za-z0-9]/-}/memory"
}

# What the Claude user runs: prints each memory file's name on a line, then
# the file. Exits with 10 when the folder is missing, is reached through a
# link, or holds no memory file.
# shellcheck disable=SC2016  # expanded by the shell that runs it
HC_MEMORY_READER='
dir="$1" home="$2" found=0
[[ -d "$dir" ]] || exit 10
real="$(cd -P -- "$dir" 2>/dev/null && pwd -P)" || exit 10
home="$(cd -P -- "$home" 2>/dev/null && pwd -P)" || exit 10
[[ "$real" == "$home/${dir#"$2"/}" ]] || exit 10
for f in "$dir"/*.md; do
  [[ -f "$f" && ! -L "$f" ]] || continue
  found=1
  printf "file: %s\n" "${f##*/}"
  cat -- "$f"
  printf "\n"
done
(( found )) || exit 10
'

# run_memory <variable> - writes the memory to the log and stores the
# outcome in the named variable: ok, empty or failed. The outcome is not
# printed, for the reason run_morning gives. Until it is framed, the output
# is in a file only root can read; what the reading prints on standard
# error is thrown away.
run_memory() {
  local _rm_out="$HC_STATE/memory.out" _rm_rc=0
  mkdir -p "$HC_STATE"
  rm -f "$_rm_out"
  ( umask 077; : > "$_rm_out" )
  ( cd / && ulimit -f "$HC_MEMORY_KIB" && as_claude env HC_LIMIT_GRACE="$HC_MEMORY_GRACE" \
      "$HC_LIMIT_BIN" "$HC_MEMORY_LIMIT" bash -c "$HC_MEMORY_READER" memory "$(memory_dir)" "$HC_HOME" \
  ) </dev/null >>"$_rm_out" 2>/dev/null &
  wait $! || _rm_rc=$?
  if (( _rm_rc == 0 )); then
    _report_frame memory "$HC_MEMORY_LINES" "$HC_MEMORY_CHARS" "$HC_MEMORY_KIB" < "$_rm_out" | log_lines
    printf -v "$1" '%s' ok
  elif (( _rm_rc == 10 )); then
    printf -v "$1" '%s' empty
  elif (( _rm_rc == 124 )); then
    log "memory: failed with status 124, the time limit"
    printf -v "$1" '%s' failed
  else
    log "memory: failed with status $_rm_rc"
    printf -v "$1" '%s' failed
  fi
  rm -f "$_rm_out"
  return 0
}
