# The run command's agent: Claude Code once, without a terminal, as the
# agent the command named, from the working folder, with a turn limit and a
# time limit and with automatic memory off. The add-on knows nothing about
# what the agent is for. It tells the run where its result file goes, marks
# the run as unattended in its environment (HA_CLAUDE_UNATTENDED holds the
# agent's name, for a hook to read), and afterwards checks and raises the
# result file.
: "${HC_CLAUDE_BIN:=claude}"
: "${HC_LIMIT_BIN:=/usr/local/bin/ha-claude-limit}"

# True when the name is one the run command may start: a short name of
# lowercase letters, digits and hyphens, so it cannot leave the agents
# folder, and not the chat's agent, which run without a terminal would have
# the chat's tools with nobody there.
run_name_ok() {
  [[ "$1" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || return 1
  [[ "$1" != chat ]]
}

run_configured() {
  local file="$HC_WORKSPACE/.claude/agents/$1.md"
  run_name_ok "$1" && [[ -f "$file" && ! -L "$file" ]]
}

# run_agent <variable> <agent> - runs the agent and stores the outcome in
# the named variable as one word: ok, failed, timeout or not_configured. It
# is the run command's for an agent that has no job file; a file from the
# repo runs in the job runner (jobs.sh). The outcome is not printed: a
# caller that captured it would hold back a stop signal until the run had
# ended. The run's output can hold what the agent read, so it goes to a file
# only root can read, not to the log.
run_agent() {
  local _ra_agent="${2:-}" _ra_today _ra_limit _ra_turns _ra_log _ra_rc=0 _ra_started=$SECONDS
  local _ra_marker="$HC_STATE/run-${2:-}.started" _ra_job=()
  if ! run_configured "$_ra_agent"; then
    printf -v "$1" '%s' not_configured
    return 0
  fi
  _ra_today="$(date +%F)"
  _ra_limit="$(_morning_number '.run_timeout' 900)"
  _ra_turns="$(_morning_number '.run_max_turns' 60)"
  _ra_log="$HC_STATE/run-$_ra_agent.log"
  mkdir -p "$HC_STATE"
  declare -F clean_handover >/dev/null && clean_handover
  clear_result "$_ra_agent"
  : > "$_ra_marker"
  rm -f "$_ra_log"
  ( umask 077; : > "$_ra_log" )
  # A fixed run whose tool calls the policy asks to mark carries its job's name.
  if declare -F fixed_marked >/dev/null && fixed_marked "$_ra_agent"; then
    _ra_job=(HA_CLAUDE_JOB="$_ra_agent")
  fi
  ( cd "$HC_WORKSPACE" && as_claude env CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
      HA_CLAUDE_UNATTENDED="$_ra_agent" ${_ra_job[@]+"${_ra_job[@]}"} \
      "$HC_LIMIT_BIN" "$_ra_limit" "$HC_CLAUDE_BIN" \
      -p "Today is $_ra_today. Your result file is $HC_RESULTS/$_ra_agent.json. Do your run." \
      --agent "$_ra_agent" --max-turns "$_ra_turns" --permission-mode default \
      --no-session-persistence \
  ) </dev/null >>"$_ra_log" 2>&1 &
  wait $! || _ra_rc=$?
  log "run: $_ra_agent ended with status $_ra_rc after $((SECONDS - _ra_started)) seconds"
  if (( _ra_rc == 124 )); then
    printf -v "$1" '%s' timeout
  elif (( _ra_rc == 0 )) && publish_result "$_ra_agent" "$_ra_marker"; then
    printf -v "$1" '%s' ok
  else
    printf -v "$1" '%s' failed
  fi
}
