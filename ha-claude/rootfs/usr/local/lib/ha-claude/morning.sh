# The morning run: Claude Code once, without a terminal, as the agent
# "morning-briefing" from the working folder, with a turn limit and a time
# limit and with automatic memory off. The add-on does not read what the run
# produces; it only checks that today's handover file was written. The run is
# marked as unattended in its environment, as the run command's agents are.
: "${HC_CLAUDE_BIN:=claude}"
: "${HC_LIMIT_BIN:=/usr/local/bin/ha-claude-limit}"
HC_MORNING_AGENT=morning-briefing

morning_configured() {
  [[ -f "$HC_WORKSPACE/.claude/agents/$HC_MORNING_AGENT.md" ]]
}

# Prints a whole number option, or the default when it is missing or not a
# whole number.
_morning_number() {
  local value
  value="$(opt "$1" "$2")"
  [[ "$value" =~ ^[0-9]+$ ]] || value="$2"
  printf '%s' "$value"
}

# _morning_jobs - prints one line naming the jobs that have a result file,
# "Jobs: a, b (old)", or nothing when none has. A result is old when it is
# from before the job's last run, or the job is off. Names only: nothing of
# what a job file or a result holds goes into the prompt. A result file is
# only looked at, never opened; the job file is read through the copy the
# Claude user makes.
_morning_jobs() {
  local name file mtime last enabled copy="$HC_STATE/job-morning.in"
  local -a items=()
  declare -F job_list >/dev/null || return 0
  while read -r name; do
    # A fixed job's result is its own agent's, not the chat's to tell of.
    declare -F fixed_is >/dev/null && fixed_is "$name" && continue
    file="$HC_JOB_RESULTS/$name.json"
    [[ -f "$file" ]] || continue
    mtime="$(stat -c %Y -- "$file" 2>/dev/null || stat -f %m -- "$file" 2>/dev/null)" || continue
    last="$(jq -r '.last_run // 0 | numbers' <<<"$(_job_state "$name")" 2>/dev/null)"
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    enabled=false
    if job_read "$name" "$copy"; then
      enabled="$(jq -rs 'if length == 1 then .[0].enabled == true else false end' "$copy" 2>/dev/null)"
    fi
    if [[ "$enabled" != true ]] || (( mtime < last )); then
      items+=("$name (old)")
    else
      items+=("$name")
    fi
  done < <(job_list)
  rm -f -- "$copy"
  (( ${#items[@]} )) || return 0
  local IFS=,
  printf 'Jobs: %s' "${items[*]}" | sed 's/,/, /g'
}

# run_morning <variable> - runs the morning briefing and stores its outcome
# in the named variable as one word: ok, failed, timeout or not_configured.
# The outcome is not printed: a caller that captured it would hold back a
# stop signal until the run had ended. The run's output can hold what the
# agent read, so it goes to a file only root can read, not to the log.
run_morning() {
  local _rm_today _rm_file _rm_limit _rm_turns _rm_rc=0 _rm_started=$SECONDS _rm_prompt _rm_jobs
  local _rm_marker="$HC_STATE/morning.started"
  if ! morning_configured; then
    printf -v "$1" '%s' not_configured
    return 0
  fi
  _rm_today="$(date +%F)"
  _rm_file="$HC_HANDOVER/$_rm_today.md"
  _rm_limit="$(_morning_number '.morning_timeout' 900)"
  _rm_turns="$(_morning_number '.morning_max_turns' 40)"
  _rm_prompt="Today is $_rm_today. Today's handover file is $_rm_file. Do your morning run."
  _rm_jobs="$(_morning_jobs)"
  [[ -n "$_rm_jobs" ]] && _rm_prompt+=$'\n'"$_rm_jobs"
  mkdir -p "$HC_STATE"
  declare -F clean_handover >/dev/null && clean_handover
  declare -F clear_result >/dev/null && clear_result "$HC_MORNING_AGENT"
  : > "$_rm_marker"
  rm -f "$HC_STATE/morning.log"
  ( umask 077; : > "$HC_STATE/morning.log" )
  ( cd "$HC_WORKSPACE" && as_claude env CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
      HA_CLAUDE_UNATTENDED="$HC_MORNING_AGENT" \
      "$HC_LIMIT_BIN" "$_rm_limit" "$HC_CLAUDE_BIN" \
      -p "$_rm_prompt" \
      --agent "$HC_MORNING_AGENT" --max-turns "$_rm_turns" --permission-mode default \
      --no-session-persistence \
  ) </dev/null >>"$HC_STATE/morning.log" 2>&1 &
  wait $! || _rm_rc=$?
  log "morning: the run ended with status $_rm_rc after $((SECONDS - _rm_started)) seconds"
  if (( _rm_rc == 124 )); then
    printf -v "$1" '%s' timeout
  elif (( _rm_rc == 0 )) && [[ -s "$_rm_file" && ! "$_rm_file" -ot "$_rm_marker" ]]; then
    printf -v "$1" '%s' ok
    # The run may leave a short result beside its handover file. It is
    # raised when it is there and good; the outcome does not depend on it.
    if declare -F publish_result >/dev/null && [[ -e "$HC_RESULTS/$HC_MORNING_AGENT.json" ]]; then
      publish_result "$HC_MORNING_AGENT" "$_rm_marker" || true
    fi
  else
    printf -v "$1" '%s' failed
  fi
}

# The first message of the chat session that follows a morning run. Fixed
# text only: nothing the run read or wrote is put here.
opening_prompt() {
  case "$1" in
    ok)
      printf '%s' "The morning run has written today's handover file. Read it and present its summary to the owner."
      ;;
    timeout)
      printf '%s' "The morning run took too long and was stopped. Tell the owner so in one sentence. Then read today's handover file if it exists and say what is in it."
      ;;
    *)
      printf '%s' "The morning run did not finish. Tell the owner so in one sentence. Then read today's handover file if it exists and say what is in it."
      ;;
  esac
}
