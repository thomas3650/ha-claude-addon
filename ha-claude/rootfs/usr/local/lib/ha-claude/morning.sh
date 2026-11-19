# What the add-on gives the runs of the job files beyond the runner itself
# (jobs.sh): the Jobs line a run's context may ask for, and the chat's
# opening after a run whose file asks for the chat to be cleared. Nothing
# here names an agent.

# _morning_jobs - prints one line naming the jobs that have a result file,
# "Jobs: a, b (old)", or nothing when none has. A result is old when it is
# from before the job's last run, or the job is off. Names only: nothing of
# what a chat's job file or a result holds goes into the line. A result file is
# only looked at, never opened; the job file is read through the copy the
# Claude user makes.
_morning_jobs() {
  local name file mtime last enabled copy="$HC_STATE/job-morning.in"
  local -a items=()
  declare -F job_list >/dev/null || return 0
  while read -r name; do
    # A fixed job's result is its own agent's, not the chat's to tell of.
    job_from_repo "$name" && continue
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

# The first message of the chat session that follows a run whose file has
# the after step clear_chat (the morning run). Fixed text only: nothing the
# run read or wrote is put here.
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
