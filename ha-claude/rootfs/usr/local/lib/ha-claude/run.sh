# The run command's agent: Claude Code once (claude_once), as the agent the
# command named, with the options run_timeout and run_max_turns. The add-on
# knows nothing about what the agent is for. It tells the run where its
# result file goes, and afterwards checks and raises the result file.

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
  local _ra_agent="${2:-}" _ra_limit _ra_turns _ra_log _ra_prompt _ra_rc=0 _ra_started=$SECONDS
  local _ra_marker="$HC_STATE/run-${2:-}.started"
  if ! run_configured "$_ra_agent"; then
    printf -v "$1" '%s' not_configured
    return 0
  fi
  _ra_limit="$(opt_number '.run_timeout' 900)"
  _ra_turns="$(opt_number '.run_max_turns' 60)"
  _ra_log="$HC_STATE/run-$_ra_agent.log"
  _ra_prompt="$HC_STATE/run-$_ra_agent.prompt"
  mkdir -p "$HC_STATE"
  declare -F clean_handover >/dev/null && clean_handover
  clear_result "$_ra_agent"
  : > "$_ra_marker"
  rm -f "$_ra_log"
  ( umask 077; : > "$_ra_log"
    printf 'Today is %s. Your result file is %s/%s.json. Do your run.\n' \
      "$(date +%F)" "$HC_RESULTS" "$_ra_agent" > "$_ra_prompt" )
  claude_once "$_ra_agent" "$_ra_limit" "$_ra_turns" "$_ra_prompt" "$_ra_log" || _ra_rc=$?
  rm -f -- "$_ra_prompt"
  log "run: $_ra_agent ended with status $_ra_rc after $((SECONDS - _ra_started)) seconds"
  if (( _ra_rc == 124 )); then
    printf -v "$1" '%s' timeout
  elif (( _ra_rc == 0 )) && publish_result "$_ra_agent" "$_ra_marker"; then
    printf -v "$1" '%s' ok
  else
    printf -v "$1" '%s' failed
  fi
}
