# Jobs: files the chat writes in the jobs folder, one per job, each a task
# for one of three fixed agents (job-private, job-web, job-all) on a
# schedule. Home Assistant keeps the clock and sends "jobs tick"; the add-on
# reads the files, checks them and runs the jobs that are due. The add-on
# knows nothing about what a job does or what an agent may: the gate holds
# each to its reach. The chat's gate
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
# that have ended, and .requests/ the chat's requests (jobs_requests): both
# are skipped, as neither is a file named <name>.json.
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

# job_check <name> <file> <since> <enabled-others> - checks a chat's job
# file (job-chat.schema.json): prints the job in its normal form, or fails
# and prints one word: shape, name, type (the agent is not one of the
# three), task, schedule, end or limit. A file in the old form, with type,
# is the shape, and so is a field only a file from the repo may have. <since> is the day the add-on first saw the job,
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
  # A file from the repo is its own check's (fixed_check): a chat's file is
  # never one. Its origin is the working folder, not anything in the file.
  if declare -F fixed_is >/dev/null && fixed_is "$name"; then
    echo shape
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
    | if (keys - ["agent", "created", "enabled", "end", "notify", "schedule", "task"]) != [] then error("shape") else . end
    | if (["agent", "created", "enabled", "end", "schedule", "task"] - keys) != [] then error("shape") else . end
    | if (.enabled | type) != "boolean" then error("shape") else . end
    | if has("notify") and ((.notify | type) != "string" or (.notify | length) > 500) then error("shape") else . end
    | if (.created | day) == null then error("shape") else . end
    | if (.agent | IN("job-private", "job-web", "job-all")) | not then error("type") else . end
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
    | {name: $name, agent, task, schedule, end, enabled, notify: (.notify // null), created}
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

# _job_repo_limit <job-json> - the time limit of a file from the repo's run,
# in seconds: its timeout, or the option run_timeout (900 when unset).
_job_repo_limit() {
  local limit
  limit="$(jq -r '.timeout // empty' <<<"$1")"
  [[ "$limit" =~ ^[0-9]+$ ]] || limit="$(opt_number '.run_timeout' 900)"
  printf '%s\n' "$limit"
}

# One tick's length: Home Assistant sends the tick every 15 minutes.
HC_JOB_TICK=900

# _job_fields <job-json> <state-json> - sets enabled, end, time, every,
# days, last, status, missed and window for the caller, from the job and
# its state. A job never run has last -1; missed is the slot last raised as
# missed, or -1. window is 0 for a chat's job; for a file from the repo it
# is the run's limit plus one tick, the time after its slot in which it may
# still start. A file from the repo is told by its normal form, which has
# run_by (null or not); a chat's normal form never has it.
_job_fields() {
  local fields
  # On standard input, not as arguments: the job holds the task and the
  # state the finding, text Claude wrote, and arguments are readable by
  # every user in the container.
  # shellcheck disable=SC2016  # jq's variables, not the shell's
  fields="$(jq -rs '.[0] as $j | .[1] as $s |
    [$j.enabled, $j.end, ($j.schedule.time // ""), ($j.schedule.every_hours // 0),
     (($j.schedule.days // []) | join(",")), ($s.last_run // -1), ($s.status // "idle"),
     ($s.missed // -1), ($j | has("run_by"))]
    | map(tostring) | join("|")
  ' <<<"$1"$'\n'"$2")" || return 1
  # A separator that is not white space: read would run empty fields together.
  IFS='|' read -r enabled end time every days last status missed window <<<"$fields"
  [[ "$last" =~ ^-?[0-9]+$ ]] || last=-1
  [[ "$missed" =~ ^-?[0-9]+$ ]] || missed=-1
  if [[ "$window" == true ]]; then
    window=$(( $(_job_repo_limit "$1") + HC_JOB_TICK ))
  else
    window=0
  fi
}

# _job_days_from <YYYY-MM-DD> <from> <to> - prints "date weekday" for the
# days from..to after the date (negative is before), by the calendar, so a
# day of 23 or 25 hours does not skip or repeat one.
_job_days_from() {
  # shellcheck disable=SC2016  # jq's variables, not the shell's
  jq -rn --arg d "$1" --argjson a "$2" --argjson b "$3" \
    '$d | strptime("%Y-%m-%d") | mktime as $t | range($a; $b + 1) | $t + . * 86400 | strftime("%Y-%m-%d %u")'
}

# _job_slots <days> <time> <YYYY-MM-DD> <from> <to> - prints the job's slots
# on the days from..to after the date, in order: the epoch of its time on
# each of those days that is one of its days (a list such as "mon,wed").
_job_slots() {
  local days="$1" time="$2" day weekday slot
  local -a names=(mon tue wed thu fri sat sun)
  while read -r day weekday; do
    [[ ",$days," == *",${names[weekday - 1]},"* ]] || continue
    slot="$(_job_epoch "$day" "$time")" || continue
    printf '%s\n' "$slot"
  done < <(_job_days_from "$3" "$4" "$5")
}

# job_due <job-json> <state-json> <now-epoch> - returns 0 when the job is
# due: enabled, not past its end, not running, and its time has come since
# its last run. A daily job is due at its time on its days, once; a day the
# add-on missed is not made up. A job every few hours is due that many hours
# after its last run, less a minute, so a tick a few seconds early does not
# put it off by a whole tick.
#
# A file from the repo is due only within its window: from its time until
# its limit and one tick later. The day is the time's own: yesterday's time
# is still due while its window lasts, so a run at 23:45 that a late tick
# puts past midnight still starts. After the window the day is skipped. A
# run before the time (a command's) does not count: the time is due when
# last_run is before it.
job_due() {
  local job="$1" state="$2" now="$3" today slot from=0
  local enabled end time every days last status missed window
  _job_fields "$job" "$state" || return 1
  [[ "$enabled" == true && "$status" != running ]] || return 1
  today="$(_job_date "$now" %F)" || return 1
  [[ "$end" == null || ! "$today" > "$end" ]] || return 1
  if (( every > 0 )); then
    (( last < 0 || now - last > every * 3600 - 60 ))
    return
  fi
  # A chat's job has today's slot and no window; a file from the repo has
  # yesterday's too, while its window lasts.
  (( window > 0 )) && from=-1
  while read -r slot; do
    (( now >= slot && last < slot && (window == 0 || now < slot + window) )) && return 0
  done < <(_job_slots "$days" "$time" "$today" "$from" 0)
  return 1
}

# job_missed <job-json> <state-json> <now-epoch> - prints the slot of a file
# from the repo with run_by jobs whose window ended within the last tick
# without its run starting, and returns 0; returns 1 otherwise. Only while
# the job is on and not running, and once for a slot (the state's missed).
# Only the tick at the window's end raises it: no tick comes while the
# pause is on, and a window that ended before the add-on started, before
# the switch went on or before the pause was lifted is not missed. A run
# that started and was failed (by a restart) set last_run: it is not
# missed. A file run by an automation is the automation's to watch.
job_missed() {
  local job="$1" state="$2" now="$3" today slot close
  local enabled end time every days last status missed window
  _job_fields "$job" "$state" || return 1
  [[ "$enabled" == true && "$status" != running ]] || return 1
  (( window > 0 && every == 0 )) || return 1
  [[ "$(jq -r '.run_by' <<<"$job")" == jobs ]] || return 1
  today="$(_job_date "$now" %F)" || return 1
  while read -r slot; do
    close=$((slot + window))
    if (( now >= close && now < close + HC_JOB_TICK && last < slot && missed != slot )); then
      printf '%s\n' "$slot"
      return 0
    fi
  done < <(_job_slots "$days" "$time" "$today" -1 0)
  return 1
}

# job_next <job-json> <state-json> <now-epoch> - prints when the job runs
# next as an epoch, or null when it does not: disabled, or the next time is
# past its end. A job that is due now prints the time it became due. For a
# file from the repo a time whose window has passed is skipped, so its next
# run is never a time it will not start at; a run before the time does not
# count as the time's.
job_next() {
  local job="$1" state="$2" now="$3" today slot next="" from=0
  local enabled end time every days last status missed window
  _job_fields "$job" "$state" || { echo null; return 0; }
  [[ "$enabled" == true ]] || { echo null; return 0; }
  today="$(_job_date "$now" %F)" || { echo null; return 0; }
  if (( every > 0 )); then
    if (( last < 0 )); then next="$now"; else next=$((last + every * 3600)); fi
  else
    # Today and the seven days after it: one of them is on the job's days.
    # A file from the repo also looks at yesterday's, while its window lasts.
    (( window > 0 )) && from=-1
    while read -r slot; do
      (( window > 0 && slot + window <= now )) && continue
      if (( slot > last )); then next="$slot"; break; fi
    done < <(_job_slots "$days" "$time" "$today" "$from" 7)
  fi
  # An end of null is no end: a fixed job's normal form has it.
  if [[ -z "$next" || ( "$end" != null && "$(_job_date "$next" %F)" > "$end" ) ]]; then
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
#                   run), finding (the result's verdict) and text, and for a
#                   file from the repo missed (the last slot raised as
#                   missed, job_missed)
#   <name>.pid      the runner's PID while a run is on
#   <name>.started  made when the run starts; the result must not be older
#   <name>.limit    the run's time limit, in seconds, for sync's wait
#   seen/<name>     the day the add-on first saw the job (below)
# Its run's output goes to HC_STATE/job-<name>.log, and the prompt and the
# copies of the result being checked are HC_STATE/job-<name>.*: all for
# root only. A chat's job touches nothing of the handover; a file from the
# repo may ask for it (its context).
#
# Every job runs here, a chat's job and a file from the repo alike: the
# file's agent, with the file's limits and a first message built from the
# file (job_first_message), its result checked, and the file's after steps
# done (job_after). What differs by origin is where the result goes and
# what is done with it: a chat's job writes HC_JOB_RESULTS/<name>.json and
# its finding stays with the job; a file from the repo writes
# HC_RESULTS/<agent>.json, raised as ha_claude_result, and its outcome is
# raised as ha_claude_outcome.
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
  _job_public "$name"
  jobs_on_change "$name"
}

# _job_public <name> - writes the job's public copy, HC_JOB_PUBLIC/<name>.json,
# which the Claude user reads and cannot write: the chat's job_status reads
# it. It holds the status, the error word, the times as epochs and the
# outcome of the last request, never the finding, its text or anything a run
# wrote. Written whole and renamed in place; removed when the job has no
# state.
_job_public() {
  local name="$1" dir="${HC_JOB_PUBLIC:?}" file tmp
  job_name_ok "$name" || return 0
  file="$dir/$name.json"
  if [[ ! -f "$HC_JOB_STATE/$name.json" ]]; then
    rm -f -- "$file"
    return 0
  fi
  # Readable by the Claude user, whatever the add-on's own umask.
  ( umask 022; mkdir -p "$dir" ) 2>/dev/null || return 0
  # A temporary file of its own: the runner and the command loop may write
  # the same job's copy at once.
  tmp="$(mktemp "$dir/.$name.XXXXXX.tmp" 2>/dev/null)" || return 0
  # shellcheck disable=SC2016  # jq's variables, not the shell's
  if ( umask 022; jq -c '
        def num: if type == "number" then . else null end;
        def word: if type == "string" and test("\\A[a-z][a-z_-]{0,19}\\z") then . else null end;
        {status: (.status | word // "idle"), error: (.error | word),
         last_run: (.last_run | num), last_end: (.last_end | num), next_run: (.next_run | num),
         limits: (if (.limits | type) == "object"
                  then {seconds: (.limits.seconds | num), turns: (.limits.turns | num)} else null end),
         request: (if (.request | type) == "object"
                   then {at: (.request.at | num), outcome: (.request.outcome | word), reason: (.request.reason | word)}
                   else null end)}
      ' "$HC_JOB_STATE/$name.json" > "$tmp" ) 2>/dev/null; then
    chmod 644 -- "$tmp" && mv -f -- "$tmp" "$file"
  else
    rm -f -- "$tmp"
  fi
}

# _job_forget <name> - removes the job's state and tells Home Assistant.
_job_forget() {
  local name="$1" dir="${HC_JOB_STATE:?}"
  job_name_ok "$name" || return 0
  rm -f -- "$dir/$name.json" "$dir/$name.pid" "$dir/$name.started" "$dir/$name.limit"
  _job_public "$name"
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
    rm -f -- "$pidfile" "$HC_JOB_STATE/$name.limit"
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
  # Every job's public copy afresh, as one whose state did not change since
  # an upgrade has none yet; a copy with no state left is removed.
  ( umask 022; mkdir -p "${HC_JOB_PUBLIC:?}" ) 2>/dev/null || true
  rm -f -- "$HC_JOB_PUBLIC"/*.tmp "$HC_JOB_PUBLIC"/.*.tmp
  for file in "$dir"/*.json; do
    [[ -f "$file" ]] || continue
    name="${file##*/}"; name="${name%.json}"
    _job_public "$name"
  done
  for file in "$HC_JOB_PUBLIC"/*.json; do
    [[ -e "$file" || -L "$file" ]] || continue
    name="${file##*/}"; name="${name%.json}"
    [[ -f "$dir/$name.json" ]] || rm -f -- "$file"
  done
  # The listener is gone with the old container too, and so is any holder of
  # the publishing lock or of the placing's lock, and every run's scratch.
  # A clearing request (after/) is kept: the start carries it out.
  rm -rf -- "$state/mqtt-listen.pid" "$state/mqtt.lock.d" "$state"/job-mqtt.* "$state"/job-calls.* \
        "$state"/job-notify.* "$state"/job-switch.* "$state"/job-count.* "$state"/job-fixed.* \
        "${HC_FIXED_LOCK:-$state/fixed.lock}.d"
  rm -f -- "$dir"/*.pid "$dir"/*.started "$dir"/*.limit "$dir"/*.tmp \
        "$state"/job-*.prompt "$state"/job-*.in "$state"/job-*.err "$state"/job-*.body "$state"/job.in \
        "$state"/fixed-*.started "$state"/result-* "$state"/run-*.started "$state"/after/.*.tmp
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

# jobs_wait_cap - prints how long sync waits for the running jobs at most:
# the largest time limit among them, plus 90 seconds; 0 when none runs. A
# run whose limit is not known counts with job_timeout.
jobs_wait_cap() {
  local name limit max=-1
  while read -r name; do
    [[ -n "$name" ]] || continue
    limit="$(cat "$HC_JOB_STATE/$name.limit" 2>/dev/null)"
    [[ "$limit" =~ ^[0-9]{1,5}$ ]] || limit="$(opt_number '.job_timeout' 1800)"
    (( limit > max )) && max="$limit"
  done < <(jobs_running)
  if (( max < 0 )); then echo 0; else echo "$((max + 90))"; fi
}

# jobs_wait_idle - returns when no job runs, for sync. A run ends by its own
# time limit; the wait gives up a little after the largest (jobs_wait_cap),
# in case a runner hangs after its run. Short waits in the background, so a
# stop signal is handled at once.
jobs_wait_idle() {
  local cap waited=0 running
  running="$(jobs_running)"
  [[ -n "$running" ]] || return 0
  cap="$(jobs_wait_cap)"
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

# _job_result <name> <marker> - checks a chat job's result and writes it,
# cleaned, to HC_STATE/job-<name>.body, which only root can read. It is read
# as publish_result reads one, through a copy the Claude user makes, into
# files of this job's own, so runs that end together do not meet. On a
# failure the log has one fixed reason, nothing of the content, and
# _JOB_WHY holds the word for it, which goes into the state's error:
# no-result, stale, unreadable, too-large, or result-<reason> for a result
# that is not well formed (shape, count, type, length, json, other).
_JOB_WHY=""
_job_result() {
  local name="$1" file="$HC_JOB_RESULTS/$1.json" rc=0
  _JOB_WHY=""
  local copy="$HC_STATE/job-$1.in" err="$HC_STATE/job-$1.err" body="$HC_STATE/job-$1.body"
  rm -f -- "$body"
  if [[ ! -e "$file" ]]; then
    log "jobs: $name: no result"
    _JOB_WHY="no-result"
    return 1
  fi
  if [[ "$file" -ot "$2" ]]; then
    log "jobs: $name: the result is stale"
    _JOB_WHY=stale
    return 1
  fi
  claude_copy "$file" "$copy" "$HC_JOB_RESULT_BYTES" "$HC_RESULT_WAIT" || rc=$?
  if (( rc == 1 )); then
    log "jobs: $name: the result is unreadable"
    _JOB_WHY=unreadable
    return 1
  elif (( rc != 0 )); then
    log "jobs: $name: the result is too large"
    _JOB_WHY="too-large"
    return 1
  fi
  rc=0
  ( umask 077; result_body "$copy" > "$body" 2> "$err" ) || rc=$?
  (( rc == 0 )) || rm -f -- "$body"
  if (( rc != 0 )); then
    local why
    why="$(_result_reason "$err")"
    log "jobs: $name: the result is malformed ($why)"
    [[ "$why" == "not json" ]] && why=json
    _JOB_WHY="result-$why"
  fi
  rm -f -- "$copy" "$err"
  return "$rc"
}

# job_first_message <name> <job-json> - the run's first message, one form
# for every job: "Today is <date>. Your result file is <path>. Do your run."
# A file from the repo goes on with a line for each of its context lines, in
# its order (handover: today's handover file; jobs: the Jobs line, when a
# chat's job has a result), and its task as "Extra task from the owner:". A
# chat's job goes on as before: the condition under which the owner is
# told, and its task.
job_first_message() {
  local name="$1" job="$2" today line jobs
  today="$(date +%F)"
  if declare -F fixed_is >/dev/null && fixed_is "$name"; then
    # shellcheck disable=SC2016  # jq's variables, not the shell's
    jq -j --arg today "$today" --arg dir "$HC_RESULTS" \
      '"Today is \($today). Your result file is \($dir)/\(.agent).json. Do your run."' <<<"$job"
    while read -r line; do
      case "$line" in
        handover) printf "\nToday's handover file is %s/%s.md." "$HC_HANDOVER" "$today" ;;
        jobs) jobs="$(_morning_jobs)"; [[ -n "$jobs" ]] && printf '\n%s' "$jobs" ;;
      esac
    done < <(jq -r '(.context // [])[]' <<<"$job")
    # The task on standard output only, never on a command line.
    jq -j 'if (.task | type) == "string" then "\nExtra task from the owner: \(.task)" else "" end' <<<"$job"
    printf '\n'
    return 0
  fi
  # shellcheck disable=SC2016  # jq's variables, not the shell's
  jq -r --arg today "$today" --arg dir "$HC_JOB_RESULTS" '
    "Today is \($today). Your result file is \($dir)/\(.name).json. Do your run."
    + (if .notify then " Set notify to true only when this holds: \(.notify)" else "" end)
    + "\n\nThe task:\n\n\(.task)"
  ' <<<"$job"
}

# job_outcome_command <name> - the command a file from the repo's outcome
# is raised as: morning for the file the option morning_job names, run for
# any other.
job_outcome_command() {
  local morning
  morning="$(opt '.morning_job' '')"
  if [[ -n "$morning" && "$morning" == "$1" ]]; then echo morning; else echo run; fi
}

# job_after <name> <outcome> <by> <job-json> - a file from the repo's after
# steps, at the end of its run, and its outcome. With clear_chat the chat's
# session is cleared, which the command loop also handles, so the runner
# never does it: it writes a request (_job_after_request) and returns
# without waiting for it (jobs_after_run carries it out). Without, the
# outcome is raised at once (_job_after_raise). A request that cannot be
# written is logged, and the outcome raised without the clearing.
job_after() {
  _job_after_request "$@" || _job_after_raise "$@"
}

# _job_after_request <name> <outcome> <by> <job-json> - when the file has
# the after step clear_chat, writes the request in HC_STATE/after/<name>,
# which only root can read, "clear the chat, then raise this outcome", whole
# or not at all. Returns 0 when it was written, 1 when the file has no such
# step or the request could not be written (logged). The runner writes it
# before the state that ends the run, so whatever sees the run ended sees
# its request too.
_job_after_request() {
  local name="$1" outcome="$2" by="$3" job="$4" command agent dir="$HC_STATE/after"
  jq -e '(.after // []) | index("clear_chat")' <<<"$job" >/dev/null 2>&1 || return 1
  command="$(job_outcome_command "$name")"
  agent="$(jq -r '.agent' <<<"$job")"
  # shellcheck disable=SC2016  # jq's variables, not the shell's
  if ( umask 077; mkdir -p "$dir" && chmod 700 "$dir" \
         && jq -nc --arg c "$command" --arg o "$outcome" --arg a "$agent" --arg b "$by" \
              '{command: $c, outcome: $o, agent: $a, by: $b}' > "$dir/.$name.tmp" \
         && mv -f -- "$dir/.$name.tmp" "$dir/$name" ) 2>/dev/null; then
    log "jobs: $name: the chat is cleared next"
    return 0
  fi
  rm -f -- "$dir/.$name.tmp"
  log "jobs: $name: the request to clear the chat could not be written"
  return 1
}

# _job_after_raise <name> <outcome> <by> <job-json> - raises the outcome.
_job_after_raise() {
  raise_outcome "$(job_outcome_command "$1")" "$2" "$(jq -r '.agent' <<<"$4")" "$3"
}

# jobs_after_run - carries out the requests the runner left (job_after):
# with the option morning_chat on, and not after not_configured, the chat
# is cleared with the opening for the outcome; then the outcome is raised,
# and the request removed. Called by the command loop on every pass, after
# each command, and at the start for a request a restart left. A request
# that is not one is removed and logged.
jobs_after_run() {
  local file name req command outcome agent by
  for file in "$HC_STATE"/after/*; do
    [[ -e "$file" || -L "$file" ]] || continue
    name="${file##*/}"
    req=""
    if job_name_ok "$name" && [[ -f "$file" && ! -L "$file" ]]; then
      req="$(jq -r 'select(type == "object"
                    and (.command | IN("morning", "run"))
                    and (.outcome | IN("ok", "failed", "timeout", "not_configured"))
                    and (.by | IN("jobs", "command"))
                    and (.agent | type == "string" and test("^[a-z][a-z0-9-]{0,31}$")))
                  | "\(.command) \(.outcome) \(.agent) \(.by)"' "$file" 2>/dev/null)" || req=""
    fi
    if [[ -z "$req" ]]; then
      log "jobs: a request to clear the chat is not one; it is removed"
      rm -f -- "$file"
      continue
    fi
    read -r command outcome agent by <<<"$req"
    if [[ "$outcome" != not_configured && "$(opt_bool '.morning_chat' true)" == true ]] \
       && ! clear_chat "$(opening_prompt "$outcome")"; then
      log "jobs: $name: there is no chat session to present the run"
    fi
    raise_outcome "$command" "$outcome" "$agent" "$by"
    rm -f -- "$file"
  done
  return 0
}

# _job_run <name> <job-json> <agent> <repo> <by> <limit> <turns> <today> <mark>
# - one run, in the background: Claude Code once, without a terminal, as the
# job's agent, from the working folder, with a time limit and a turn limit
# and with automatic memory off. The first message comes on standard input
# from a file only root can read, so the task is on no command line. The run
# is marked as unattended for the gate (HA_CLAUDE_UNATTENDED holds the
# agent), and, when mark is yes, as the job (HA_CLAUDE_JOB). <repo> is true
# for a file from the repo; <today> the day the run started. Afterwards the
# runner checks the result, writes how the run ended and, for a file from
# the repo, does its after steps.
_job_run() {
  local name="$1" job="$2" agent="$3" repo="$4" by="$5" limit="$6" turns="$7" today="$8"
  local rc=0 status next started=$SECONDS kept handover why=""
  local body="$HC_STATE/job-$1.body"
  local prompt="$HC_STATE/job-$1.prompt" marker="$HC_JOB_STATE/$1.started" out="$HC_STATE/job-$1.log"
  local -a mark=()
  [[ "$9" == yes ]] && mark=(HA_CLAUDE_JOB="$name")
  ( cd "$HC_WORKSPACE" && as_claude env CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
      HA_CLAUDE_UNATTENDED="$agent" ${mark[@]+"${mark[@]}"} \
      "$HC_LIMIT_BIN" "$limit" "$HC_CLAUDE_BIN" -p \
      --agent "$agent" --max-turns "$turns" --permission-mode default \
      --no-session-persistence \
  ) <"$prompt" >>"$out" 2>&1 || rc=$?
  rm -f -- "$prompt"
  kept="$HC_STATE/fixed-$agent.body"
  handover="$HC_HANDOVER/$today.md"
  # Why a run did not end ok, as one word in its error: time-limit, max-turns
  # (Claude Code said it reached --max-turns), exit (it ended with another
  # error), handover, result (a file from the repo's result), or the word
  # _job_result gives for a chat job's result.
  if (( rc == 124 )); then
    status=timeout; why="time-limit"
  elif (( rc != 0 )); then
    status=failed
    if grep -qi 'max turns' -- "$out" 2>/dev/null; then why="max-turns"; else why="exit"; fi
  elif [[ "$repo" != true ]]; then
    if _job_result "$name" "$marker"; then status=ok; else status=failed; why="$_JOB_WHY"; fi
  # A file from the repo whose context names the handover must have written
  # today's handover file since it started, and its result as well.
  elif jq -e '(.context // []) | index("handover")' <<<"$job" >/dev/null 2>&1 \
       && ! [[ -s "$handover" && ! -L "$handover" && ! "$handover" -ot "$marker" ]]; then
    log "jobs: $name: today's handover file was not written"
    status=failed; why="handover"
  else
    rm -f -- "$kept"
    if publish_result "$agent" "$marker"; then status=ok; else status=failed; why="result"; fi
  fi
  log "jobs: $name ended $status${why:+ ($why)} after $((SECONDS - started)) seconds"
  # A request to clear the chat is written before the state that ends the
  # run: sync's wait, and anything else that sees the run ended, then sees
  # the request as well. The outcome itself is raised after the state.
  local requested=no
  [[ "$repo" == true ]] && _job_after_request "$name" "$status" "$by" "$job" && requested=yes
  # The next run counts from this one's start, which the state already
  # holds; it is written with the end, in one change, so whoever sees the
  # run ended sees its next run too.
  next="$(job_next "$job" "$(_job_state "$name")" "$(date +%s)")"
  # The result is read by jq from its file: the text Claude wrote goes on
  # no command line.
  # shellcheck disable=SC2016  # jq's variables, not the shell's
  if [[ "$status" == ok && "$repo" == true ]]; then
    # The finding is the kept body's, written by this run; when there is
    # none, the finding is empty rather than the last run's. notify is not
    # for a file from the repo.
    if ! [[ -f "$kept" && ! -L "$kept" && ! "$kept" -ot "$marker" ]]; then
      rm -f -- "$kept"
      ( umask 077; echo '{}' > "$kept" )
    fi
    _job_update "$name" '($b[0] // {}) as $r
      | .status = "ok" | .error = null | .last_end = $now | .notify_rose = false
      | .finding = ($r.verdict | if type == "string" then . else null end)
      | .text = ($r.text | if type == "string" then . else null end) | .next_run = $next' \
      --slurpfile b "$kept" --argjson now "$(date +%s)" --argjson next "$next"
    rm -f -- "$kept"
  elif [[ "$status" == ok ]]; then
    _job_update "$name" '$b[0] as $r | (.notify // false) as $was
      | .status = "ok" | .error = null | .last_end = $now
      | .notify_rose = ($r.notify and ($was | not)) | .notify = $r.notify
      | .finding = $r.verdict | .text = $r.text | .next_run = $next' \
      --slurpfile b "$body" --argjson now "$(date +%s)" --argjson next "$next"
  else
    _job_update "$name" '.status = $s | .error = (if $w == "" then null else $w end) | .last_end = $now
      | .notify_rose = false | .next_run = $next' \
      --arg s "$status" --arg w "$why" --argjson now "$(date +%s)" --argjson next "$next"
  fi
  rm -f -- "$marker" "$body"
  [[ "$repo" == true && "$requested" == no ]] && _job_after_raise "$name" "$status" "$by" "$job"
  return 0
}

# _job_start <name> <job-json> <now> [by] - starts one run in the
# background, as the job's agent; by is jobs (the tick, the default) or
# command. Returns 1, with the job failed, when the agent has no file. A
# file from the repo has its own timeout and max_turns, or the options
# run_timeout and run_max_turns; a chat's job has job_timeout and
# job_max_turns. A file from the repo starts without the last result of its
# agent, as the run command's agents do, and with the handover folder made
# clean; a chat's job keeps its last result, which its agent reads first.
_job_start() {
  local name="$1" job="$2" now="$3" by="${4:-jobs}" agent file repo=false limit turns marked=yes today
  agent="$(jq -r '.agent' <<<"$job")"
  if ! job_name_ok "$agent"; then
    log "jobs: $name: the agent is not a name"
    # shellcheck disable=SC2016  # jq's variables, not the shell's
    _job_update "$name" '.status = "failed" | .error = "agent" | .last_run = $now | .notify_rose = false' \
      --argjson now "$now"
    return 1
  fi
  file="$HC_WORKSPACE/.claude/agents/$agent.md"
  # shellcheck disable=SC2016  # jq's variables, not the shell's
  if [[ ! -f "$file" || -L "$file" ]]; then
    log "jobs: $name: there is no agent $agent"
    _job_update "$name" '.status = "failed" | .error = "agent" | .last_run = $now | .notify_rose = false' \
      --argjson now "$now"
    return 1
  fi
  declare -F fixed_is >/dev/null && fixed_is "$name" && repo=true
  if [[ "$repo" == true ]]; then
    limit="$(_job_repo_limit "$job")"
    turns="$(jq -r '.max_turns // empty' <<<"$job")"
    [[ "$turns" =~ ^[0-9]+$ ]] || turns="$(opt_number '.run_max_turns' 60)"
    # The tool calls are marked with the job only when the policy asks.
    if ! declare -F fixed_marked >/dev/null || ! fixed_marked "$name"; then marked=no; fi
  else
    limit="$(opt_number '.job_timeout' 1800)"
    turns="$(opt_number '.job_max_turns' 60)"
  fi
  today="$(date +%F)"
  ( umask 077; job_first_message "$name" "$job" > "$HC_STATE/job-$name.prompt" )
  if [[ "$repo" == true ]]; then
    declare -F clean_handover >/dev/null && clean_handover
    clear_result "$agent"
  else
    # In the results folder, which is the Claude user's: as that user. The
    # last result stays: the agent reads it first, to compare. Only a result
    # written after this mark counts as this run's.
    as_claude mkdir -p -- "$HC_JOB_RESULTS" </dev/null >/dev/null 2>&1 || true
  fi
  : > "$HC_JOB_STATE/$name.started"
  ( umask 077; printf '%s\n' "$limit" > "$HC_JOB_STATE/$name.limit" )
  rm -f -- "$HC_STATE/job-$name.log"
  ( umask 077; : > "$HC_STATE/job-$name.log" )
  # shellcheck disable=SC2016  # jq's variables, not the shell's
  _job_update "$name" '.status = "running" | .error = null | .last_run = $now | .next_run = null
      | .notify_rose = false | .limits = {seconds: $limit, turns: $turns}' \
    --argjson now "$now" --argjson limit "$limit" --argjson turns "$turns"
  _job_run "$name" "$job" "$agent" "$repo" "$by" "$limit" "$turns" "$today" "$marked" &
  printf '%s\n' "$!" > "$HC_JOB_STATE/$name.pid"
  log "jobs: $name started as $agent"
}

# job_command <name> - the run a command asks for of a file from the repo
# (morning, run <name>): started now in the runner, whatever the file's
# enabled says, and not waited for. When it runs already, nothing starts and
# the outcome is running; when the placed file is not valid, failed. The
# outcome then is raised at once, so the script that sent the command does
# not wait the run's whole limit.
job_command() {
  local name="$1" command copy="$HC_STATE/job-command.in" job
  command="$(job_outcome_command "$name")"
  # The outcome's agent is the name: a file from the repo is named after its
  # agent, which fixed_check holds it to (the word agent otherwise).
  if [[ "$(_job_status "$name")" == running ]] && _job_pid_alive "$name"; then
    log "jobs: $name runs already; it is not started again"
    raise_outcome "$command" running "$name" command
    return 0
  fi
  if ! job_read "$name" "$copy" || ! job="$(fixed_check "$name" "$copy")"; then
    rm -f -- "$copy"
    log "jobs: $name is not valid; it is not run"
    raise_outcome "$command" failed "$name" command
    return 0
  fi
  rm -f -- "$copy"
  _job_start "$name" "$job" "$(date +%s)" command || raise_outcome "$command" failed "$name" command
  return 0
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
  # The fixed jobs are not the chat's: they have no first sight and are
  # outside the cap.
  all="$(while read -r name; do
           declare -F fixed_is >/dev/null && fixed_is "$name" && continue
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

# _jobs_tick_fixed <name> <now> <copy> - checks a fixed job's placed file
# against the working folder's and writes its state: idle unless it has a
# status of its own (ok, failed, timeout, running), invalid with the word
# fixed_check gave, and its next run. A file with run_by jobs that is due is
# started, whatever the places and whether or not Home Assistant can see
# the jobs, and one whose window ended unstarted at this tick raises the
# outcome missed (job_missed); one with run_by automation is another's to
# start. It does not end.
# shellcheck disable=SC2016  # jq's variables, not the shell's
_jobs_tick_fixed() {
  local name="$1" now="$2" copy="$3" state job slot
  state="$(_job_state "$name")"
  [[ "$(jq -r '.status // empty' <<<"$state")" == running ]] && return 0
  if ! job_read "$name" "$copy"; then
    _job_update "$name" '.status = "invalid" | .error = "unreadable" | .next_run = null'
    return 0
  fi
  if ! job="$(fixed_check "$name" "$copy")"; then
    _job_update "$name" '.status = "invalid" | .error = $w | .next_run = null' --arg w "$job"
    return 0
  fi
  _job_update "$name" '(if .status == "invalid" or .status == null then .status = "idle" else . end)
    | .error = (if .status == "idle" or .status == "ok" then null else .error end)
    | .next_run = $next' --argjson next "$(job_next "$job" "$state" "$now")"
  [[ "$(jq -r '.run_by' <<<"$job")" == jobs ]] || return 0
  state="$(_job_state "$name")"
  if job_due "$job" "$state" "$now"; then
    _job_start "$name" "$job" "$now" jobs || true
  elif slot="$(job_missed "$job" "$state" "$now")"; then
    # Remembered first, so the slot is raised once even if raising fails.
    _job_update "$name" '.missed = $s' --argjson s "$slot"
    log "jobs: $name did not start in its window"
    raise_outcome "$(job_outcome_command "$name")" missed "$(jq -r '.agent' <<<"$job")" jobs
  fi
}

# _jobs_parallel - how many runs may be on at once: the option
# jobs_parallel, 3 when unset, from 1 to 10.
_jobs_parallel() {
  local parallel
  parallel="$(opt_number '.jobs_parallel' 3)"
  (( parallel >= 1 )) || parallel=1
  (( parallel <= 10 )) || parallel=10
  printf '%s\n' "$parallel"
}

# _jobs_scan <today> <now> [want] - the tick's pass over the chat's jobs, in
# their order (_jobs_order): each file read and checked, the enabled ones
# counted, so the limit refuses the newest. Without want, as the tick: writes
# each job's state, ends the jobs past their end and sets _JOBS_DUE to the
# due ones, "<name> <job>" each. With want, for a request (jobs_request):
# changes no state and ends nothing, and stops at that job, counted as the
# tick counts it. It sets _JOBS_WANT to ok, with _JOBS_WANT_JOB its normal
# form, or to why it cannot run: running, ended, unreadable or the check's
# word; empty when it is not among the jobs read.
_jobs_scan() {
  local today="$1" now="$2" want="${3:-}" name state since job last enabled=0
  local copy="$HC_STATE/job.in"
  [[ -n "$want" ]] && copy="$HC_STATE/job-request.in"
  _JOBS_DUE=()
  _JOBS_WANT=""
  _JOBS_WANT_JOB=""
  # shellcheck disable=SC2016  # jq's variables, not the shell's
  while read -r name; do
    state="$(_job_state "$name")"
    since="$(_job_seen "$name" "$today")"
    if [[ -z "$want" && "$(jq -r '.status' <<<"$state")" != running ]]; then
      _job_update "$name" '.first_seen = $d | .status = (.status // "idle")' --arg d "$since"
      state="$(_job_state "$name")"
    fi
    if [[ "$(jq -r '.status' <<<"$state")" == running ]]; then
      # Its runner owns the state; it still counts against the limit.
      if job_read "$name" "$copy" && job="$(job_check "$name" "$copy" "$since" "$enabled")" \
         && [[ "$(jq -r '.enabled' <<<"$job")" == true ]]; then
        enabled=$((enabled + 1))
      fi
      [[ -n "$want" && "$name" == "$want" ]] && { _JOBS_WANT=running; break; }
      continue
    fi
    # Whatever the file says, a job ends 28 days after the add-on first saw it.
    last="$(_job_last_day "$since")" || last=""
    if [[ -n "$last" && "$today" > "$last" ]]; then
      [[ -z "$want" ]] && _job_end "$name"
      [[ -n "$want" && "$name" == "$want" ]] && { _JOBS_WANT=ended; break; }
      continue
    fi
    if ! job_read "$name" "$copy"; then
      [[ -z "$want" ]] && _job_update "$name" '.status = "invalid" | .error = "unreadable" | .next_run = null'
      [[ -n "$want" && "$name" == "$want" ]] && { _JOBS_WANT=unreadable; break; }
      continue
    fi
    if ! job="$(job_check "$name" "$copy" "$since" "$enabled")"; then
      [[ -z "$want" ]] && _job_update "$name" '.status = "invalid" | .error = $w | .next_run = null' --arg w "$job"
      [[ -n "$want" && "$name" == "$want" ]] && { _JOBS_WANT="$job"; break; }
      continue
    fi
    [[ "$(jq -r '.enabled' <<<"$job")" == true ]] && enabled=$((enabled + 1))
    if [[ "$today" > "$(jq -r '.end' <<<"$job")" ]]; then
      [[ -z "$want" ]] && _job_end "$name"
      [[ -n "$want" && "$name" == "$want" ]] && { _JOBS_WANT=ended; break; }
      continue
    fi
    if [[ -n "$want" ]]; then
      [[ "$name" == "$want" ]] && { _JOBS_WANT=ok; _JOBS_WANT_JOB="$job"; break; }
      continue
    fi
    _job_update "$name" '(if .status == "invalid" or .status == null then .status = "idle" else . end)
      | .error = (if .status == "idle" or .status == "ok" then null else .error end)
      | .next_run = $next' --argjson next "$(job_next "$job" "$state" "$now")"
    job_due "$job" "$state" "$now" && _JOBS_DUE+=("$name $job")
  done < <(_jobs_order "$today")
  rm -f -- "$copy"
  return 0
}

# jobs_tick - reads the job files, checks them, writes each job's state,
# ends the jobs past their end, and starts the due ones, at most
# jobs_parallel at once; the rest wait for a later tick. Returns at once:
# the runs go on in the background.
jobs_tick() {
  local now today name count parallel entry file
  local copy="$HC_STATE/job.in"
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
    # A fixed job's state is its own check's, also while its copy is missing.
    declare -F fixed_is >/dev/null && fixed_is "$name" && continue
    [[ "$(_job_status "$name")" == running ]] && _job_pid_alive "$name" && continue
    _job_forget "$name"
  done
  # The files from the repo first: they are checked and shown, and the due
  # ones with run_by jobs start before any place is counted; they do not
  # count towards the limit of enabled jobs.
  if declare -F fixed_list >/dev/null; then
    while read -r name; do
      [[ -n "$name" ]] || continue
      _jobs_tick_fixed "$name" "$now" "$copy"
    done < <(fixed_list)
  fi
  rm -f -- "$copy"
  _jobs_scan "$today" "$now"
  _jobs_prune_seen "$today"
  # The files are checked and their state kept either way; without a way to
  # show them in Home Assistant, none of the chat's jobs runs. The places
  # left are counted with every run that is on, a file from the repo's too.
  jobs_can_run || return 0
  parallel="$(_jobs_parallel)"
  count="$(jobs_running | wc -l | tr -d ' ')"
  for entry in ${_JOBS_DUE[@]+"${_JOBS_DUE[@]}"}; do
    (( count < parallel )) || break
    _job_start "${entry%% *}" "${entry#* }" "$now" && count=$((count + 1))
  done
  return 0
}

# A chat's request to run one of its jobs now (the jobs server's
# job_run_now): an empty file named by the job in HC_JOB_REQUESTS, a folder
# of the Claude user's. Any process of that user can write there, so a
# request starts only what the chat's own jobs already may.
: "${HC_JOB_REQUESTS_PASS:=5}"
# At most this many requests are acted on in a pass: each costs a pass over
# the job files (_jobs_scan). The rest stay for the next pass.
: "${HC_JOB_REQUESTS_ACT:=2}"
# The entries that could not be removed, kept so they do not take a pass's
# places again; at most HC_JOB_REQUESTS_KEEP of them.
HC_JOB_REQUESTS_KEEP=64
HC_JOB_REQUESTS_STUCK=()
HC_JOB_REQUESTS_LINK=0

# jobs_request <name> - starts a chat's job now, as the tick would: valid and
# counted within the limit as the tick counts it, enabled, not past its end,
# not running, only while Home Assistant can see the jobs, and within
# jobs_parallel. Its run sets last_run as a tick's does. Otherwise nothing
# starts, and the log says why. Either way the outcome goes into the job's
# state as request, {at, outcome, reason}, for job_status and the sensor:
# started; failed with the word the start set; or dropped with one of
#   repo       a file from the repo
#   running    it runs already
#   ended      past its end
#   off        not enabled
#   limit      over the enabled jobs' limit (the scan's word limit)
#   invalid    the file fails the check (any other word of the scan)
#   no-broker  Home Assistant cannot see the jobs
#   parallel   jobs_parallel runs are on
# A drop is kept only for a job that has a state already (every tick makes
# one): a name with no job file, or one the tick has not seen, is only
# logged, and a job past its end is left to the tick.
jobs_request() {
  local name="$1" now today why="" word="" count parallel err
  now="$(date +%s)"
  today="$(_job_date "$now" %F)" || return 0
  mkdir -p "$HC_JOB_STATE"
  if declare -F fixed_is >/dev/null && fixed_is "$name"; then
    why="it is a file from the repo"; word=repo
  else
    _jobs_reap
    if [[ "$(_job_status "$name")" == running ]] && _job_pid_alive "$name"; then
      why="it runs already"; word=running
    else
      _jobs_scan "$today" "$now" "$name"
      case "$_JOBS_WANT" in
        ok) [[ "$(jq -r '.enabled' <<<"$_JOBS_WANT_JOB")" == true ]] || { why="it is switched off"; word=off; } ;;
        "") why="there is no such job" ;;
        running) why="it runs already"; word=running ;;
        ended) why="it has ended"; word=ended ;;
        limit) why="it is not valid (limit)"; word=limit ;;
        *) why="it is not valid ($_JOBS_WANT)"; word=invalid ;;
      esac
    fi
  fi
  if [[ -z "$why" ]]; then
    # A request tries the broker afresh, as a tick does.
    jobs_tick_begin
    jobs_can_run || { why="Home Assistant cannot see the jobs"; word=no-broker; }
  fi
  if [[ -z "$why" ]]; then
    parallel="$(_jobs_parallel)"
    count="$(jobs_running | wc -l | tr -d ' ')"
    (( count < parallel )) || { why="$count runs are on already"; word=parallel; }
  fi
  if [[ -n "$why" ]]; then
    log "jobs: the request to run $name now is dropped: $why"
    [[ -n "$word" && -f "$HC_JOB_STATE/$name.json" ]] && _job_request_outcome "$name" "$now" dropped "$word"
    return 0
  fi
  log "jobs: $name runs now, as the chat asked"
  if _job_start "$name" "$_JOBS_WANT_JOB" "$now"; then
    _job_request_outcome "$name" "$now" started ""
  else
    err="$(jq -r '.error // "start"' <<<"$(_job_state "$name")")"
    _job_request_outcome "$name" "$now" failed "$err"
  fi
}

# _job_request_outcome <name> <epoch> <outcome> <reason> - keeps the outcome
# of the job's last request in its state; the state's error is left as it
# is, as every tick sets that afresh.
_job_request_outcome() {
  # shellcheck disable=SC2016  # jq's variables, not the shell's
  _job_update "$1" '.request = {at: $at, outcome: $o, reason: (if $r == "" then null else $r end)}' \
    --argjson at "$2" --arg o "$3" --arg r "$4"
}

# _jobs_request_stuck <entry> - true when the entry is one that could not
# be removed before.
_jobs_request_stuck() {
  local stuck
  for stuck in ${HC_JOB_REQUESTS_STUCK[@]+"${HC_JOB_REQUESTS_STUCK[@]}"}; do
    [[ "$stuck" == "$1" ]] && return 0
  done
  return 1
}

# jobs_requests - the command loop's pass over the requests, on every pass:
# at most HC_JOB_REQUESTS_PASS entries, the rest at the next, and at most
# HC_JOB_REQUESTS_ACT requests acted on. Every entry is removed, as the
# Claude user, whose folder it is: never by root, so a link or a folder put
# there is never followed. A folder that user made unwritable is first made
# its own again, as that user. Root only tests whether an entry is a link
# before anything else about it, so it never looks at a link's target. Only
# a plain file named by a job name is a request, and only its name is read,
# never its content; it is acted on once it is gone, so it cannot start a
# job twice. An entry that could not be removed is kept aside and takes no
# place in later passes. A pass over an empty folder lists it and does
# nothing else.
jobs_requests() {
  local dir="$HC_JOB_REQUESTS" entry name left=0 seen=0 wanted=0
  local -a entries=() folders=() names=()
  if [[ -L "$dir" ]]; then
    (( HC_JOB_REQUESTS_LINK )) || log "jobs: the requests folder is a link; it is not read"
    HC_JOB_REQUESTS_LINK=1
    return 0
  fi
  HC_JOB_REQUESTS_LINK=0
  [[ ! -L "$dir" && -d "$dir" ]] || return 0
  # An entry kept aside that is gone now is forgotten, so a request of the
  # same name later is read.
  local -a stuck=()
  for entry in ${HC_JOB_REQUESTS_STUCK[@]+"${HC_JOB_REQUESTS_STUCK[@]}"}; do
    [[ -L "$entry" || -e "$entry" ]] && stuck+=("$entry")
  done
  HC_JOB_REQUESTS_STUCK=(${stuck[@]+"${stuck[@]}"})
  while IFS= read -r -d '' entry; do
    # A bound on the listing too, however many entries are skipped.
    seen=$((seen + 1))
    (( seen <= HC_JOB_REQUESTS_PASS * 4 )) || break
    _jobs_request_stuck "$entry" && continue
    name="${entry##*/}"
    if [[ ! -L "$entry" && -f "$entry" ]] && job_name_ok "$name"; then
      # A request beyond those acted on this pass stays for the next.
      (( wanted < HC_JOB_REQUESTS_ACT )) || continue
      wanted=$((wanted + 1))
      names+=("$name")
    elif [[ ! -L "$entry" && -d "$entry" ]]; then
      folders+=("$entry")
    fi
    entries+=("$entry")
    (( ${#entries[@]} < HC_JOB_REQUESTS_PASS )) || break
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  (( ${#entries[@]} )) || return 0
  # One time limit for both steps, as the Claude user: the folders made that
  # user's own again, then everything removed.
  # shellcheck disable=SC2016  # the inner shell's variables
  as_claude env HC_LIMIT_GRACE=1 "$HC_LIMIT_BIN" 10 sh -c '
    n="$1"; shift
    i=0
    for f in "$@"; do
      i=$((i + 1))
      [ "$i" -le "$n" ] && chmod -R u+rwx -- "$f" 2>/dev/null
    done
    shift "$n"
    rm -rf -- "$@"
  ' sh "${#folders[@]}" ${folders[@]+"${folders[@]}"} "${entries[@]}" </dev/null >/dev/null 2>&1 || true
  for entry in "${entries[@]}"; do
    if [[ -L "$entry" || -e "$entry" ]]; then
      left=$((left + 1))
      (( ${#HC_JOB_REQUESTS_STUCK[@]} < HC_JOB_REQUESTS_KEEP )) && HC_JOB_REQUESTS_STUCK+=("$entry")
    fi
  done
  (( left )) && log "jobs: $left entries in the requests folder could not be removed; none is acted on"
  for name in ${names[@]+"${names[@]}"}; do
    # One that is still there is not acted on: it would start again.
    [[ -L "$dir/$name" || -e "$dir/$name" ]] && continue
    jobs_request "$name"
  done
  return 0
}
