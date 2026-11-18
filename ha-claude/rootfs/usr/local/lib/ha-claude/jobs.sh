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
  local name="$1" file="$2" since="$3" others="$4" out
  if ! job_name_ok "$name"; then
    echo name
    return 1
  fi
  # shellcheck disable=SC2016  # jq's variables, not the shell's
  if out="$(jq -cen --arg name "$name" --arg since "$since" --argjson others "$others" \
               --argjson max "$HC_JOBS_MAX" --argjson days "$HC_JOB_DAYS" '
    def day: if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
             then (try (strptime("%Y-%m-%d") | mktime) catch null) as $t
               | if $t != null and ($t | strftime("%Y-%m-%d")) == . then $t else null end
             else null end;
    def all_days: ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];
    [inputs] | if length != 1 then error("shape") else .[0] end
    | if type != "object" then error("shape") else . end
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

# job_due <job-json> <state-json> <now-epoch> - returns 0 when the job is
# due: enabled, not past its end, not running, and its time has come since
# its last run. A daily job is due at its time on its days, once; a day the
# add-on missed is not made up. A job every few hours is due that many hours
# after its last run, less a minute, so a tick a few seconds early does not
# put it off by a whole tick.
job_due() {
  local job="$1" state="$2" now="$3" fields today weekday slot
  local enabled end time every days last status
  fields="$(jq -rn --argjson j "$job" --argjson s "$state" '
    [$j.enabled, $j.end, ($j.schedule.time // ""), ($j.schedule.every_hours // 0),
     (($j.schedule.days // []) | join(",")), ($s.last_run // -1), ($s.status // "idle")]
    | map(tostring) | join("|")
  ')" || return 1
  # A separator that is not white space: read would run empty fields together.
  IFS='|' read -r enabled end time every days last status <<<"$fields"
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
