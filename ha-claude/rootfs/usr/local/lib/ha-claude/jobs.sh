# Jobs: files the chat writes in the jobs folder, one per job, each a task
# for one of three fixed agent types on a schedule. Home Assistant keeps the
# clock and sends "jobs tick"; the add-on reads the files, checks them and
# runs the jobs that are due. The add-on knows nothing about what a job does
# or what a type may: the gate holds each type to its reach. The chat's gate
# checks a job file when it is written; this check is the second, so either
# alone stops a bad job.
#
# The folder and its files are the Claude user's, who can swap a file for a
# link, a pipe or a huge file at any moment. So a job file is only ever read
# through a copy the Claude user makes, as publish_result does.
: "${HC_JOB_BYTES:=16384}"
: "${HC_JOB_WAIT:=5}"
: "${HC_LIMIT_BIN:=/usr/local/bin/ha-claude-limit}"
HC_JOB_NAME_RE='^[a-z][a-z0-9-]{0,31}$'
# At most this many enabled jobs, and at most this many days from the day a
# job was made to its end.
HC_JOBS_MAX=10
HC_JOB_DAYS=28

job_name_ok() {
  [[ "$1" =~ $HC_JOB_NAME_RE ]]
}

# True for a plain file that is not a link. A swap after this check is met by
# the copy's own limits; the check makes the common case quick and certain.
_job_plain() {
  [[ -f "$1" && ! -L "$1" ]]
}

# job_read <name> <out-file> - copies the job's file into out-file, which
# only root can reach. Returns 1 when the name is not a job name, or the file
# is missing, not a plain file, cannot be read in time or is too large.
job_read() {
  local file="$HC_JOBS/$1.json"
  rm -f "$2"
  job_name_ok "$1" || return 1
  _job_plain "$file" || return 1
  claude_copy "$file" "$2" "$HC_JOB_BYTES" "$HC_JOB_WAIT" || return 1
}

# job_list - prints the names of the job files, one per line, in order. A
# name that is not a job name is not a job; the folder ended/ holds the jobs
# that have ended.
job_list() {
  local file name
  [[ -d "$HC_JOBS" ]] || return 0
  for file in "$HC_JOBS"/*.json; do
    name="${file##*/}"; name="${name%.json}"
    job_name_ok "$name" || continue
    [[ -f "$file" ]] || continue
    printf '%s\n' "$name"
  done
}

# job_check <name> <file> <since> <enabled-others> - prints the job in its
# normal form, or fails and prints one word: shape, name, type, task,
# schedule, end or limit. <since> is the day the add-on first saw the job,
# from its own state: the 28 days count from it as well as from the file's
# own created, so a created moved later does not stretch them.
# <enabled-others> is the number of other enabled jobs that come before this
# one.
#
# The normal form has every field: schedule has days (every day when the
# file gives none) or every_hours, and notify is null when the file has none.
job_check() {
  local name="$1" file="$2" since="$3" others="$4" out members
  if ! job_name_ok "$name"; then
    echo name
    return 1
  fi
  # jq keeps the last of a key written twice, so the gate and this check
  # could read different values. The members of the top-level object are
  # counted from the parser's own events: a member ends with a value that
  # has no members of its own, or with the close of one that has. Counted
  # against the keys, a key written twice is found.
  members="$(jq -n --stream '[inputs | select((length == 2 and (.[0] | length) == 1)
                                or (length == 1 and (.[0] | length) == 2))] | length' "$file" 2>/dev/null)" \
    || members=-1
  [[ "$members" =~ ^[0-9]+$ ]] || members=-1
  # shellcheck disable=SC2016  # jq's variables, not the shell's
  if out="$(jq -cen --arg name "$name" --arg since "$since" --argjson others "$others" --argjson members "$members" \
               --argjson max "$HC_JOBS_MAX" --argjson days "$HC_JOB_DAYS" '
    def day: if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
             then (try (strptime("%Y-%m-%d") | mktime) catch null) as $t
               | if $t != null and ($t | strftime("%Y-%m-%d")) == . then $t else null end
             else null end;
    def all_days: ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];
    [inputs] | if length != 1 then error("shape") else .[0] end
    | if type != "object" or (keys | length) != $members then error("shape") else . end
    | if has("agent") then error("shape") else . end
    | if (keys - ["created", "enabled", "end", "notify", "schedule", "task", "type"]) != [] then error("shape") else . end
    | if (["created", "enabled", "end", "schedule", "task", "type"] - keys) != [] then error("shape") else . end
    | if (.enabled | type) != "boolean" then error("shape") else . end
    | if has("notify") and ((.notify | type) != "string" or (.notify | length) > 500) then error("shape") else . end
    | if (.created | day) == null then error("shape") else . end
    | if (.type | IN("private", "web", "all")) | not then error("type") else . end
    | if (.task | type) != "string" or (.task | length) == 0 or (.task | length) > 4000 then error("task") else . end
    | .schedule |= (
        if type != "object" then error("schedule")
        elif keys == ["every_hours"] then
          if (.every_hours | type) == "number" and (.every_hours | tojson | test("^[0-9]+$"))
             and .every_hours >= 4 and .every_hours <= 24
          then {every_hours} else error("schedule") end
        elif (keys - ["days"]) == ["time"] then
          if (.time | type) != "string" or (.time | test("^([01][0-9]|2[0-3]):[0-5][0-9]$") | not)
          then error("schedule")
          elif has("days") and ((.days | type) != "array" or (.days | length) == 0
                or (.days | unique | length) != (.days | length)
                or (.days - all_days) != [])
          then error("schedule")
          else {time, days: (if has("days") then [all_days[] as $d | select(.days | index($d)) | $d] else all_days end)}
          end
        else error("schedule") end)
    | (.end | day) as $end | (.created | day) as $created | ($since | day) as $since
    | if $end == null or $since == null or $end < $created
         or $end > ([$created, $since] | min) + $days * 86400
      then error("end") else . end
    | if .enabled and $others >= $max then error("limit") else . end
    | {name: $name, type, task, schedule, end, enabled, notify: (.notify // null), created}
  ' "$file" 2>&1)"; then
    printf '%s\n' "$out"
    return 0
  fi
  # Only the word of the check that failed, from jq's last line; any other
  # error (the file did not parse) is the shape.
  out="${out##*$'\n'}"
  case "${out##*: }" in
    type|task|schedule|end|limit) echo "${out##*: }" ;;
    *) echo shape ;;
  esac
  return 1
}

# _job_date <epoch> <format> - the local date or time of an epoch, GNU date
# first, then BSD.
_job_date() {
  date -d "@$1" +"$2" 2>/dev/null || date -r "$1" +"$2"
}

# _job_epoch <YYYY-MM-DD> <HH:MM> - the epoch of a local time. A time that a
# change to summer time skips does not exist; GNU date refuses it, and it is
# then counted from midnight, which lands an hour later, as BSD date does.
_job_epoch() {
  local midnight h m
  date -d "$1 $2:00" +%s 2>/dev/null && return 0
  date -j -f '%Y-%m-%d %H:%M:%S' "$1 $2:00" +%s 2>/dev/null && return 0
  midnight="$(date -d "$1 00:00:00" +%s 2>/dev/null)" || return 1
  h="${2%%:*}"; m="${2##*:}"
  printf '%s\n' "$((midnight + 10#$h * 3600 + 10#$m * 60))"
}

# _job_fields <job-json> <state-json> - sets enabled, end, time, every,
# days, last and status for the caller, from the job and its state. A job
# never run has last -1.
_job_fields() {
  local fields
  # On standard input, not as arguments: the job holds the task and the
  # state the finding, text Claude wrote, and arguments are readable by
  # every user in the container.
  # shellcheck disable=SC2016  # jq's variables, not the shell's
  fields="$(jq -rs '.[0] as $j | .[1] as $s |
    [$j.enabled, $j.end, ($j.schedule.time // ""), ($j.schedule.every_hours // 0),
     (($j.schedule.days // []) | join(",")), ($s.last_run // -1), ($s.status // "idle")]
    | map(tostring) | join("|")
  ' <<<"$1"$'\n'"$2")" || return 1
  # A separator that is not white space: read would run empty fields together.
  IFS='|' read -r enabled end time every days last status <<<"$fields"
}

# job_due <job-json> <state-json> <now-epoch> - returns 0 when the job is
# due: enabled, not past its end, not running, and its time has come since
# its last run. A daily job is due at its time on its days, once; a day the
# add-on missed is not made up. A job every few hours is due that many hours
# after its last run, less a minute, so a tick a few seconds early does not
# put it off by a whole tick.
job_due() {
  local job="$1" state="$2" now="$3" today weekday slot
  local enabled end time every days last status
  _job_fields "$job" "$state" || return 1
  [[ "$enabled" == true && "$status" != running ]] || return 1
  today="$(_job_date "$now" %F)" || return 1
  [[ ! "$today" > "$end" ]] || return 1
  if (( every > 0 )); then
    (( last < 0 || now - last > every * 3600 - 60 ))
    return
  fi
  weekday="$(_job_date "$now" %u)" || return 1
  local -a names=(mon tue wed thu fri sat sun)
  [[ ",$days," == *",${names[weekday - 1]},"* ]] || return 1
  slot="$(_job_epoch "$today" "$time")" || return 1
  (( now >= slot && last < slot ))
}

# job_next <job-json> <state-json> <now-epoch> - prints when the job runs
# next as an epoch, or null when it does not: disabled, or the next time is
# past its end. A job that is due now prints the time it became due.
job_next() {
  local job="$1" state="$2" now="$3" today day weekday slot next=""
  local enabled end time every days last status
  local -a names=(mon tue wed thu fri sat sun)
  _job_fields "$job" "$state" || { echo null; return 0; }
  [[ "$enabled" == true ]] || { echo null; return 0; }
  today="$(_job_date "$now" %F)" || { echo null; return 0; }
  if (( every > 0 )); then
    if (( last < 0 )); then next="$now"; else next=$((last + every * 3600)); fi
  else
    # Today and the seven days after it: one of them is on the job's days.
    while read -r day weekday; do
      [[ ",$days," == *",${names[weekday - 1]},"* ]] || continue
      slot="$(_job_epoch "$day" "$time")" || continue
      if (( slot > last )); then next="$slot"; break; fi
    done < <(jq -rn --arg d "$today" \
               '$d | strptime("%Y-%m-%d") | mktime as $t | range(0; 8) | $t + . * 86400 | strftime("%Y-%m-%d %u")')
  fi
  if [[ -z "$next" || "$(_job_date "$next" %F)" > "$end" ]]; then
    echo null
  else
    echo "$next"
  fi
}

# The runner. Each job has its state in HC_JOB_STATE, which only root can
# reach:
#   <name>.json     first_seen, status (idle, running, ok, failed, timeout or
#                   invalid), error (why it is invalid or failed, one word),
#                   last_run, last_end and next_run (epochs or null), notify,
#                   notify_rose (notify went from false to true in the last
#                   run), finding (the result's verdict) and text
#   <name>.pid      the runner's PID while a run is on
#   <name>.started  made when the run starts; the result must not be older
#   seen/<name>     the day the add-on first saw the job (below)
# Its run's output goes to HC_STATE/job-<name>.log, and the prompt and the
# copies of the result being checked are HC_STATE/job-<name>.*: all for
# root only. Nothing of a job touches the handover.
: "${HC_CLAUDE_BIN:=claude}"
: "${HC_JOB_RESULT_BYTES:=32768}"

# Called with a job's name after its state changed or was removed; Home
# Assistant is told through it. Nothing is told until a later file fills it.
declare -F jobs_on_change >/dev/null || jobs_on_change() { :; }

# True when jobs may start; a later file makes it false while Home Assistant
# cannot see them.
declare -F jobs_can_run >/dev/null || jobs_can_run() { return 0; }

# Called as a tick begins.
declare -F jobs_tick_begin >/dev/null || jobs_tick_begin() { :; }

# _job_state <name> - prints the job's state, or {} when it has none.
_job_state() {
  jq -c 'if type == "object" then . else {} end' "$HC_JOB_STATE/$1.json" 2>/dev/null || echo '{}'
}

_job_status() {
  jq -r '.status // "idle"' <<<"$(_job_state "$1")"
}

# _job_update <name> <jq-filter> [jq-args...] - changes the job's state with
# the filter; when that changed anything, writes it whole and tells Home
# Assistant.
_job_update() {
  local name="$1" filter="$2" file="$HC_JOB_STATE/$1.json" old new
  shift 2
  old="$(_job_state "$name")"
  new="$(jq -c "$@" "$filter" <<<"$old")" || return 1
  [[ "$new" == "$old" && -f "$file" ]] && return 0
  mkdir -p "$HC_JOB_STATE"
  ( umask 077; printf '%s\n' "$new" > "$file.tmp" ) && mv -f "$file.tmp" "$file"
  jobs_on_change "$name"
}

# _job_forget <name> - removes the job's state and tells Home Assistant.
_job_forget() {
  local name="$1" dir="${HC_JOB_STATE:?}"
  job_name_ok "$name" || return 0
  rm -f -- "$dir/$name.json" "$dir/$name.pid" "$dir/$name.started"
  jobs_on_change "$name"
}

# _job_pid_alive <name> - true when the job's PID file names a live process.
_job_pid_alive() {
  local pid
  pid="$(cat "$HC_JOB_STATE/$1.pid" 2>/dev/null)" || return 1
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null
}

# jobs_running - prints the names of the jobs that run now, in order. A job
# runs while its state says so and its runner lives; the runner itself
# writes the state that ends the run.
jobs_running() {
  local pidfile name
  for pidfile in "$HC_JOB_STATE"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    name="${pidfile##*/}"; name="${name%.pid}"
    _job_pid_alive "$name" && [[ "$(_job_status "$name")" == running ]] && printf '%s\n' "$name"
  done
  return 0
}

# _jobs_reap - removes the PID files of runs that have ended. A run whose
# runner is gone without saying how it ended is failed. The state is read
# after the runner is found gone, so the end it wrote is never overwritten.
_jobs_reap() {
  local pidfile name
  for pidfile in "$HC_JOB_STATE"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    name="${pidfile##*/}"; name="${name%.pid}"
    if _job_pid_alive "$name"; then
      [[ "$(_job_status "$name")" == running ]] && continue
    elif [[ "$(_job_status "$name")" == running ]]; then
      log "jobs: $name: the run was lost"
      _job_update "$name" '.status = "failed" | .error = "lost" | .notify_rose = false'
    fi
    rm -f -- "$pidfile"
  done
}

# jobs_startup - at the add-on's start, before any tick: every run is over,
# as the container is new, so a PID file is stale whatever process has its
# number now. A job left running is failed.
jobs_startup() {
  local file name dir="${HC_JOB_STATE:?}" state="${HC_STATE:?}"
  mkdir -p "$dir"
  for file in "$dir"/*.json; do
    [[ -f "$file" ]] || continue
    name="${file##*/}"; name="${name%.json}"
    if [[ "$(_job_status "$name")" == running ]]; then
      log "jobs: $name was running when the add-on stopped"
      _job_update "$name" '.status = "failed" | .error = "stopped" | .notify_rose = false'
    fi
  done
  # The listener is gone with the old container too, and so is any holder of
  # the publishing lock.
  rm -rf -- "$state/mqtt-listen.pid" "$state/mqtt.lock.d" "$state"/job-mqtt.* "$state"/job-calls.* \
        "$state"/job-notify.* "$state"/job-switch.* "$state"/job-count.*
  rm -f -- "$dir"/*.pid "$dir"/*.started "$dir"/*.tmp \
        "$state"/job-*.prompt "$state"/job-*.in "$state"/job-*.err "$state"/job-*.body "$state"/job.in
}

# _job_kill_tree <pid> - stops a process and everything it started, the
# deepest first, so nothing is left without its parent to stop it.
_job_kill_tree() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do
    _job_kill_tree "$child"
  done
  kill -TERM "$1" 2>/dev/null || true
}

# jobs_stop - stops every run, when the add-on stops. The state is left as
# it is: the next start fails what was running.
jobs_stop() {
  local pidfile pid
  for pidfile in "$HC_JOB_STATE"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    pid="$(cat "$pidfile" 2>/dev/null)"
    [[ "$pid" =~ ^[1-9][0-9]*$ && "$pid" != "$$" ]] || continue
    _job_kill_tree "$pid"
  done
  return 0
}

# jobs_wait_idle - returns when no job runs, for sync. A run ends by its own
# time limit; the wait gives up a little after it, in case a runner hangs
# after its run. Short waits in the background, so a stop signal is handled
# at once.
jobs_wait_idle() {
  local cap waited=0 running
  cap=$(( $(_morning_number '.job_timeout' 1800) + 90 ))
  running="$(jobs_running)"
  [[ -n "$running" ]] || return 0
  log "jobs: waiting for $(wc -l <<<"$running" | tr -d ' ') running job(s)"
  while [[ -n "$(jobs_running)" ]]; do
    if (( waited >= cap )); then
      log "jobs: still running after $cap seconds; going on"
      return 0
    fi
    sleep 1 & wait $!
    waited=$((waited + 1))
  done
}

# _job_result_body <file> - prints the job's result, cleaned, or fails as
# _result_body does: exactly verdict, text and notify, notify a bool, the
# same cleaning and the same limits.
_job_result_body() {
  jq -cen "$HC_JQ_CLEAN"'
    [inputs] | if length != 1 then error("shape") else .[0] end
    | if type != "object" or (keys != ["notify", "text", "verdict"]) then error("shape") else . end
    | if (.notify | type) != "boolean" or (.verdict | type) != "string" or (.text | type) != "string"
      then error("type") else . end
    | {verdict: (.verdict | clean(false)), text: (.text | clean(true)), notify}
    | if (.verdict | length) > 120 or (.text | length) > 4000 then error("length") else . end
  ' "$1"
}

# _job_result <name> <marker> - writes the job's result, cleaned, to
# HC_STATE/job-<name>.body, which only root can read. It is read as
# publish_result reads one, through a copy the Claude user makes, into
# files of this job's own, so runs that end together do not meet. Fails with
# one fixed reason in the log; nothing of the content is logged.
_job_result() {
  local name="$1" file="$HC_JOB_RESULTS/$1.json" rc=0
  local copy="$HC_STATE/job-$1.in" err="$HC_STATE/job-$1.err" body="$HC_STATE/job-$1.body"
  rm -f -- "$body"
  if [[ ! -e "$file" ]]; then
    log "jobs: $name: no result"
    return 1
  fi
  if [[ "$file" -ot "$2" ]]; then
    log "jobs: $name: the result is stale"
    return 1
  fi
  claude_copy "$file" "$copy" "$HC_JOB_RESULT_BYTES" "$HC_RESULT_WAIT" || rc=$?
  if (( rc == 1 )); then
    log "jobs: $name: the result is unreadable"
    return 1
  elif (( rc != 0 )); then
    log "jobs: $name: the result is too large"
    return 1
  fi
  rc=0
  ( umask 077; _job_result_body "$copy" > "$body" 2> "$err" ) || rc=$?
  (( rc == 0 )) || rm -f -- "$body"
  (( rc == 0 )) || log "jobs: $name: the result is malformed ($(_result_reason "$err"))"
  rm -f -- "$copy" "$err"
  return "$rc"
}

# _job_prompt <job-json> - the run's first message: the date, the job's name,
# its result file, the condition under which the owner is told, and the task.
_job_prompt() {
  # shellcheck disable=SC2016  # jq's variables, not the shell's
  jq -r --arg today "$(date +%F)" --arg dir "$HC_JOB_RESULTS" '
    "Today is \($today). You run the job \(.name) once. Your result file is \($dir)/\(.name).json."
    + (if .notify then " Set notify to true only when this holds: \(.notify)" else "" end)
    + "\n\nThe task:\n\n\(.task)"
  ' <<<"$1"
}

# _job_run <name> <job-json> <agent> - one run, in the background: Claude
# Code once, without a terminal, as the job's agent, from the working
# folder, with a time limit and a turn limit and with automatic memory off.
# The prompt comes on standard input from a file only root can read, so the
# task is on no command line. The run is marked as unattended for the gate
# (HA_CLAUDE_UNATTENDED holds the agent), and as the job (HA_CLAUDE_JOB).
# Afterwards the runner checks the result and writes how the run ended.
_job_run() {
  local name="$1" job="$2" agent="$3" limit turns rc=0 status next started=$SECONDS
  local body="$HC_STATE/job-$1.body"
  local prompt="$HC_STATE/job-$1.prompt" marker="$HC_JOB_STATE/$1.started" out="$HC_STATE/job-$1.log"
  limit="$(_morning_number '.job_timeout' 1800)"
  turns="$(_morning_number '.job_max_turns' 60)"
  ( cd "$HC_WORKSPACE" && as_claude env CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
      HA_CLAUDE_UNATTENDED="$agent" HA_CLAUDE_JOB="$name" \
      "$HC_LIMIT_BIN" "$limit" "$HC_CLAUDE_BIN" -p \
      --agent "$agent" --max-turns "$turns" --permission-mode default \
      --no-session-persistence \
  ) <"$prompt" >>"$out" 2>&1 || rc=$?
  rm -f -- "$prompt"
  if (( rc == 124 )); then
    status=timeout
  elif (( rc == 0 )) && _job_result "$name" "$marker"; then
    status=ok
  else
    status=failed
  fi
  log "jobs: $name ended $status after $((SECONDS - started)) seconds"
  # The next run counts from this one's start, which the state already
  # holds; it is written with the end, in one change, so whoever sees the
  # run ended sees its next run too.
  next="$(job_next "$job" "$(_job_state "$name")" "$(date +%s)")"
  # The result is read by jq from its file: the text Claude wrote goes on
  # no command line.
  # shellcheck disable=SC2016  # jq's variables, not the shell's
  if [[ "$status" == ok ]]; then
    _job_update "$name" '$b[0] as $r | (.notify // false) as $was
      | .status = "ok" | .error = null | .last_end = $now
      | .notify_rose = ($r.notify and ($was | not)) | .notify = $r.notify
      | .finding = $r.verdict | .text = $r.text | .next_run = $next' \
      --slurpfile b "$body" --argjson now "$(date +%s)" --argjson next "$next"
  else
    _job_update "$name" '.status = $s | .error = null | .last_end = $now | .notify_rose = false
      | .next_run = $next' \
      --arg s "$status" --argjson now "$(date +%s)" --argjson next "$next"
  fi
  rm -f -- "$marker" "$body"
}

# _job_start <name> <job-json> <now> - starts one run in the background.
# Returns 1, with the job failed, when its type has no agent file.
_job_start() {
  local name="$1" job="$2" now="$3" agent file
  agent="job-$(jq -r '.type' <<<"$job")"
  file="$HC_WORKSPACE/.claude/agents/$agent.md"
  # shellcheck disable=SC2016  # jq's variables, not the shell's
  if [[ ! -f "$file" || -L "$file" ]]; then
    log "jobs: $name: there is no agent $agent"
    _job_update "$name" '.status = "failed" | .error = "agent" | .last_run = $now | .notify_rose = false' \
      --argjson now "$now"
    return 1
  fi
  ( umask 077; _job_prompt "$job" > "$HC_STATE/job-$name.prompt" )
  # In the results folder, which is the Claude user's: as that user. The
  # last result stays: the agent reads it first, to compare. Only a result
  # written after this mark counts as this run's.
  as_claude mkdir -p -- "$HC_JOB_RESULTS" </dev/null >/dev/null 2>&1 || true
  : > "$HC_JOB_STATE/$name.started"
  rm -f -- "$HC_STATE/job-$name.log"
  ( umask 077; : > "$HC_STATE/job-$name.log" )
  # shellcheck disable=SC2016  # jq's variables, not the shell's
  _job_update "$name" '.status = "running" | .error = null | .last_run = $now | .next_run = null
      | .notify_rose = false' \
    --argjson now "$now"
  _job_run "$name" "$job" "$agent" &
  printf '%s\n' "$!" > "$HC_JOB_STATE/$name.pid"
  log "jobs: $name started as $agent"
}

# _job_end <name> - moves an ended job's file to ended/, where the chat can
# still read it, and removes its state. As the Claude user: the folder is
# that user's.
#
# When the file could not be moved, the job keeps its state and Home
# Assistant is told nothing: the next tick tries again, and the job does not
# run meanwhile.
_job_end() {
  if as_claude mkdir -p -- "$HC_JOBS/ended" </dev/null >/dev/null 2>&1 \
     && as_claude mv -f -- "$HC_JOBS/$1.json" "$HC_JOBS/ended/$1.json" </dev/null >/dev/null 2>&1; then
    log "jobs: $1 has ended"
    _job_forget "$1"
  else
    log "jobs: $1 has ended, and its file could not be moved; the next tick tries again"
  fi
}

# The day the add-on first saw each job is kept in HC_JOB_STATE/seen/<name>,
# apart from the job's state, and outlives it: a file moved away for a tick
# and back, or a job ended and made again under its name, is still counted
# from the first day. An entry goes only when its 28 days are over and the
# name has no file.
_job_seen_file() {
  printf '%s/seen/%s' "$HC_JOB_STATE" "$1"
}

# _job_seen <name> <today> - prints the day the add-on first saw the job,
# and records it on the first sight: the first_seen an older state holds,
# or today.
_job_seen() {
  local file day re='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  file="$(_job_seen_file "$1")"
  day="$(cat "$file" 2>/dev/null)"
  [[ "$day" =~ $re ]] && { printf '%s\n' "$day"; return 0; }
  day="$(jq -r '.first_seen // empty' <<<"$(_job_state "$1")")"
  [[ "$day" =~ $re ]] || day="$2"
  mkdir -p "${file%/*}"
  ( umask 077; printf '%s\n' "$day" > "$file" )
  printf '%s\n' "$day"
}

# _jobs_prune_seen <today> - removes the first-sight records whose 28 days
# are over, of names that have no job file.
_jobs_prune_seen() {
  local file name day last
  for file in "$HC_JOB_STATE"/seen/*; do
    [[ -f "$file" ]] || continue
    name="${file##*/}"
    job_name_ok "$name" || continue
    [[ -e "$HC_JOBS/$name.json" || -L "$HC_JOBS/$name.json" ]] && continue
    day="$(cat "$file" 2>/dev/null)"
    last="$(_job_last_day "$day")" || last=""
    [[ -z "$last" || "$1" > "$last" ]] && rm -f -- "$file"
  done
  return 0
}

# _jobs_order <today> - prints the job names, the first seen first, then by
# name: the limit of enabled jobs refuses the newest. At most HC_JOB_FILES
# of them, so a folder filled with files costs a tick no more than that;
# the rest are skipped, with one line in the log.
: "${HC_JOB_FILES:=32}"
_jobs_order() {
  local name all
  all="$(while read -r name; do
           printf '%s %s\n' "$(_job_seen "$name" "$1")" "$name"
         done < <(job_list) | sort | cut -d ' ' -f 2)"
  [[ -n "$all" ]] || return 0
  if (( $(wc -l <<<"$all") > HC_JOB_FILES )); then
    log "jobs: $(wc -l <<<"$all" | tr -d ' ') job files; only the first $HC_JOB_FILES are read"
  fi
  head -n "$HC_JOB_FILES" <<<"$all"
}

# _job_last_day <first-seen> - the last day a job may run, counted from the
# day the add-on first saw it.
_job_last_day() {
  # shellcheck disable=SC2016  # jq's variables, not the shell's
  jq -rn --arg d "$1" --argjson n "$HC_JOB_DAYS" \
    '$d | strptime("%Y-%m-%d") | mktime + $n * 86400 | strftime("%Y-%m-%d")' 2>/dev/null
}

# jobs_tick - reads the job files, checks them, writes each job's state,
# ends the jobs past their end, and starts the due ones, at most
# jobs_parallel at once; the rest wait for a later tick. Returns at once:
# the runs go on in the background.
jobs_tick() {
  local now today name state since job last enabled=0 count parallel entry file
  local copy="$HC_STATE/job.in"
  local -a due=()
  mkdir -p "$HC_JOB_STATE"
  jobs_tick_begin
  now="$(date +%s)"
  today="$(_job_date "$now" %F)" || return 0
  _jobs_reap
  # The state of a job whose file is gone, unless it still runs.
  for file in "$HC_JOB_STATE"/*.json; do
    [[ -f "$file" ]] || continue
    name="${file##*/}"; name="${name%.json}"
    [[ -e "$HC_JOBS/$name.json" || -L "$HC_JOBS/$name.json" ]] && continue
    [[ "$(_job_status "$name")" == running ]] && _job_pid_alive "$name" && continue
    _job_forget "$name"
  done
  # shellcheck disable=SC2016  # jq's variables, not the shell's
  while read -r name; do
    state="$(_job_state "$name")"
    since="$(_job_seen "$name" "$today")"
    if [[ "$(jq -r '.status' <<<"$state")" != running ]]; then
      _job_update "$name" '.first_seen = $d | .status = (.status // "idle")' --arg d "$since"
      state="$(_job_state "$name")"
    fi
    if [[ "$(jq -r '.status' <<<"$state")" == running ]]; then
      # Its runner owns the state; it still counts against the limit.
      if job_read "$name" "$copy" && job="$(job_check "$name" "$copy" "$since" "$enabled")" \
         && [[ "$(jq -r '.enabled' <<<"$job")" == true ]]; then
        enabled=$((enabled + 1))
      fi
      continue
    fi
    # Whatever the file says, a job ends 28 days after the add-on first saw it.
    last="$(_job_last_day "$since")" || last=""
    if [[ -n "$last" && "$today" > "$last" ]]; then
      _job_end "$name"
      continue
    fi
    if ! job_read "$name" "$copy"; then
      _job_update "$name" '.status = "invalid" | .error = "unreadable" | .next_run = null'
      continue
    fi
    if ! job="$(job_check "$name" "$copy" "$since" "$enabled")"; then
      _job_update "$name" '.status = "invalid" | .error = $w | .next_run = null' --arg w "$job"
      continue
    fi
    [[ "$(jq -r '.enabled' <<<"$job")" == true ]] && enabled=$((enabled + 1))
    if [[ "$today" > "$(jq -r '.end' <<<"$job")" ]]; then
      _job_end "$name"
      continue
    fi
    _job_update "$name" '(if .status == "invalid" or .status == null then .status = "idle" else . end)
      | .error = (if .status == "idle" or .status == "ok" then null else .error end)
      | .next_run = $next' --argjson next "$(job_next "$job" "$state" "$now")"
    job_due "$job" "$state" "$now" && due+=("$name $job")
  done < <(_jobs_order "$today")
  rm -f -- "$copy"
  _jobs_prune_seen "$today"
  # The files are checked and their state kept either way; without a way to
  # show them in Home Assistant, none runs.
  jobs_can_run || return 0
  parallel="$(_morning_number '.jobs_parallel' 3)"
  (( parallel >= 1 )) || parallel=1
  (( parallel <= 10 )) || parallel=10
  count="$(jobs_running | wc -l | tr -d ' ')"
  for entry in "${due[@]}"; do
    (( count < parallel )) || break
    _job_start "${entry%% *}" "${entry#* }" "$now" && count=$((count + 1))
  done
  return 0
}
