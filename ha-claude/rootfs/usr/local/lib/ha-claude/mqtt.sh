# The jobs in Home Assistant, through MQTT discovery: each job is six
# entities of the device "HA Claude jobs", made and removed by retained
# messages, so a new job file is enough and no YAML is needed. The broker's
# login comes from the Supervisor (the add-on asks for the service
# mqtt:want). Without a broker the add-on works as before and runs no job.
#
# The password is never an argument, which every user in the container can
# read: the clients read their options from their own config files,
# $XDG_CONFIG_HOME/mosquitto_pub and .../mosquitto_sub, one option per line,
# in a folder only root can reach, and they run as root.
#
# What is published is the add-on's own state and what the job file and
# the run wrote, cleaned of control characters; Home Assistant shows text
# as text. The topics under ha_claude/jobs are the add-on's: the chat's gate
# refuses its publishes there.
: "${HC_MQTT_DIR:=/run/ha-claude/mqtt}"
: "${HC_MQTT_RETRY:=5}"
: "${HC_MQTT_WAIT:=10}"
: "${HC_LIMIT_BIN:=/usr/local/bin/ha-claude-limit}"
HC_MQTT_PREFIX=ha_claude/jobs
HC_MQTT_NO_BROKER_LOGGED=0
# Set when a publish failed in this tick: the broker is then taken as down
# for the rest of it.
HC_MQTT_FAILED=0
# The entities of a job: component and key.
HC_MQTT_ENTITIES=(sensor/status sensor/next_run sensor/last_run sensor/finding binary_sensor/notify switch/enabled)

# _mqtt_client <pub|sub> [args...] - runs a client with the login from its
# config file. A publish runs under a time limit, so a broker that hangs
# holds a tick for seconds, not for ever; the listener waits as long as it
# runs.
_mqtt_client() {
  local name="mosquitto_$1"
  if [[ "$1" == pub ]]; then
    shift
    HC_LIMIT_GRACE=1 "$HC_LIMIT_BIN" "$HC_MQTT_WAIT" env XDG_CONFIG_HOME="$HC_MQTT_DIR" "$name" "$@"
  else
    shift
    XDG_CONFIG_HOME="$HC_MQTT_DIR" "$name" "$@"
  fi
}

# _mqtt_locked <command> [args...] - runs the command alone: the listener,
# the command loop and the runners all publish, and a job's publish, its
# removal, the published list and the notify mark are each one step. flock
# where there is one (the image); a folder made and removed elsewhere.
_mqtt_locked() {
  local lock="${HC_STATE:?}/mqtt.lock" rc=0 tries=0
  mkdir -p "$HC_STATE"
  if command -v flock >/dev/null 2>&1; then
    {
      if ! flock -w 60 9; then
        log "mqtt: the lock was not free"
        return 1
      fi
      "$@" || rc=$?
    } 9>"$lock"
    return "$rc"
  fi
  until mkdir "$lock.d" 2>/dev/null; do
    if (( ++tries > 600 )); then
      log "mqtt: the lock was not free"
      return 1
    fi
    sleep 0.1
  done
  "$@" || rc=$?
  rmdir "$lock.d" 2>/dev/null
  return "$rc"
}

mqtt_known() {
  [[ -f "$HC_MQTT_DIR/mosquitto_pub" && -f "$HC_MQTT_DIR/mosquitto_sub" ]]
}

# mqtt_config - asks the Supervisor for the broker and writes the clients'
# config files. Fails, writing nothing, without a token, without a broker,
# or with an answer that is not a plain host, port, user and password: a
# line break in one would become an option of its own.
mqtt_config() {
  local answer lines dir="${HC_MQTT_DIR:?}"
  [[ -n "${SUPERVISOR_TOKEN:-}" ]] || return 1
  # The token goes to curl on standard input, not as an argument.
  answer="$(curl -fsS -m 10 -K - "${HC_SUPERVISOR_API:-http://supervisor}/services/mqtt" \
              <<<"header = \"Authorization: Bearer $SUPERVISOR_TOKEN\"" 2>/dev/null)" || return 1
  # shellcheck disable=SC2016  # jq's variables, not the shell's
  lines="$(jq -re '
    def plain: type == "string" and length > 0 and (explode | all(. >= 32 and . != 127));
    .data | if (.host | plain) and (.username | plain) and (.password | plain)
               and (.port | type) == "number" and .port >= 1 and .port <= 65535
            then "-h \(.host)\n-p \(.port)\n-u \(.username)\n-P \(.password)"
            else error("broker") end
  ' <<<"$answer" 2>/dev/null)" || return 1
  mkdir -p "$dir"
  chmod 700 "$dir"
  ( umask 077
    printf '%s\n' "$lines" > "$dir/mosquitto_pub.new"
    printf '%s\n' "$lines" > "$dir/mosquitto_sub.new" ) || return 1
  mv -f "$dir/mosquitto_pub.new" "$dir/mosquitto_pub"
  mv -f "$dir/mosquitto_sub.new" "$dir/mosquitto_sub"
  log "mqtt: the broker is known"
}

# jobs_tick_begin - a new tick tries the broker afresh.
jobs_tick_begin() {
  HC_MQTT_FAILED=0
}

# jobs_can_run - true when Home Assistant can see the jobs: a broker is
# known, or is found now. The first time it is not, the log says so once.
# With a broker found, the listener runs and every job is published.
#
# A removal the broker did not take is tried again here, on every tick. A
# publish that failed in this tick means the broker is down for it: no job
# starts that Home Assistant would not see.
jobs_can_run() {
  if ! mqtt_known; then
    if ! mqtt_config; then
      if (( HC_MQTT_NO_BROKER_LOGGED == 0 )); then
        log "mqtt: no MQTT broker; the jobs are checked but none runs"
        HC_MQTT_NO_BROKER_LOGGED=1
      fi
      return 1
    fi
    mqtt_republish_all
  else
    _mqtt_locked _mqtt_remove_gone || true
  fi
  mqtt_listen_start
  if (( HC_MQTT_FAILED )); then
    log "mqtt: the broker did not answer; no job starts this tick"
    return 1
  fi
  return 0
}

# _mqtt_id <name> - the job's name as it is written in object IDs, unique
# IDs and entity IDs, which take no hyphen: with an underscore. A job name
# holds no underscore, so two names never meet in one ID. The topics under
# ha_claude/jobs keep the name itself.
_mqtt_id() {
  printf '%s' "${1//-/_}"
}

# _mqtt_send <topic> [file] - publishes the file's content on the topic,
# retained; without a file, an empty retained message, which removes it.
# Fails, with HC_MQTT_FAILED set, when the broker did not take it in time;
# after that every send of the tick fails at once, so a broker that hangs
# costs a tick one time limit.
_mqtt_send() {
  local rc=0
  (( HC_MQTT_FAILED == 0 )) || return 1
  if [[ -n "${2:-}" ]]; then
    _mqtt_client pub -q 1 -r -t "$1" -s < "$2" >/dev/null 2>&1 || rc=$?
  else
    _mqtt_client pub -q 1 -r -n -t "$1" </dev/null >/dev/null 2>&1 || rc=$?
  fi
  if (( rc != 0 )); then
    HC_MQTT_FAILED=1
    log "mqtt: could not publish to the broker"
    return 1
  fi
}

# _mqtt_published <add|remove> <name> - the root-only list of the jobs that
# have entities, so those whose file has gone are removed at start.
# Called under the lock.
_mqtt_published() {
  local list="$HC_JOB_STATE/published" tmp
  mkdir -p "$HC_JOB_STATE"
  tmp="$(mktemp "$HC_JOB_STATE/published.XXXXXX")" || return 1
  { [[ -f "$list" ]] && grep -v -x -F -- "$2" "$list"; [[ "$1" == add ]] && printf '%s\n' "$2"; } > "$tmp" || true
  mv -f "$tmp" "$list"
}

# _mqtt_calls <name> <out> - writes the last 20 tool calls from the run log
# the gate writes, each its tool and its input in at most 200 characters.
# The log is the Claude user's, so it is read through a copy that user
# makes: its last 64 KiB, within a few seconds.
_mqtt_calls() {
  local copy log="$HC_JOB_RESULTS/$1.log.jsonl"
  # A fixed job's log is in results/fixed/, which the add-on's own jobs do
  # not write in.
  ! fixed_is "$1" || log="$HC_RESULTS/fixed/$1.log.jsonl"
  copy="$(mktemp "$HC_STATE/job-calls.XXXXXX")" || { echo '[]' > "$2"; return 0; }
  if [[ -e "$log" ]] \
     && claude_copy "$log" "$copy" 65536 "$HC_RESULT_WAIT" tail; then
    jq -R 'fromjson? | select(type == "object")' "$copy" 2>/dev/null \
      | jq -cs "$HC_JQ_CLEAN"'
          map({tool: ((.tool // "") | tostring | clean(false) | .[0:200]),
               input: ((.input // "") | if type == "string" then . else tojson end | clean(false) | .[0:200])})
          | .[-20:]' > "$2" 2>/dev/null || echo '[]' > "$2"
  else
    echo '[]' > "$2"
  fi
  rm -f -- "$copy"
}

# mqtt_publish_job <name> - publishes the job's entities and its state.
mqtt_publish_job() {
  job_name_ok "$1" || return 0
  mqtt_known || return 0
  _mqtt_locked _mqtt_publish_job "$1"
}

# _mqtt_publish_job <name> - the same, under the lock, with files of this
# call's own.
_mqtt_publish_job() {
  local name="$1" e comp key id topic="$HC_MQTT_PREFIX/$1/state" dir rc=0 repo=false
  # A file from the repo has no type: its origin is the working folder.
  declare -F fixed_is >/dev/null && fixed_is "$name" && repo=true
  dir="$(mktemp -d "$HC_STATE/job-mqtt.XXXXXX")" || return 1
  local cfg="$dir/cfg" job="$dir/job" calls="$dir/calls" state="$dir/state" raw="$dir/raw"
  ( umask 077
    # The file as it is, valid or not, so an invalid job still shows.
    if job_read "$name" "$raw"; then
      jq -cs 'if length == 1 and (.[0] | type) == "object" then .[0] else {} end' \
        "$raw" > "$job" 2>/dev/null || echo '{}' > "$job"
    else
      echo '{}' > "$job"
    fi
    _job_state "$name" > "$state"
    _mqtt_calls "$name" "$calls"
  )
  for e in "${HC_MQTT_ENTITIES[@]}"; do
    comp="${e%%/*}"; key="${e#*/}"; id="$(_mqtt_id "$name")"
    # shellcheck disable=SC2016  # jq's variables and Home Assistant's templates
    ( umask 077; jq -cn --arg name "$name" --arg idname "$id" --arg comp "$comp" --arg key "$key" --arg topic "$topic" '
        ("ha_claude_job_\($idname)_\($key)") as $id
        | {name: "\($name) \($key | gsub("_"; " "))", unique_id: $id, default_entity_id: "\($comp).\($id)",
           state_topic: $topic,
           device: {identifiers: ["ha_claude_jobs"], name: "HA Claude jobs"}}
        + if $key == "status" then
            {value_template: "{{ value_json.status }}", json_attributes_topic: $topic,
             json_attributes_template: "{{ {\"type\": value_json.type, \"schedule\": value_json.schedule, \"end\": value_json.end, \"task\": value_json.task, \"description\": value_json.description, \"run_by\": value_json.run_by, \"error\": value_json.error, \"calls\": value_json.calls} | tojson }}"}
          elif $key == "next_run" or $key == "last_run" then
            {device_class: "timestamp", value_template: "{{ value_json.\($key) or None }}"}
          elif $key == "finding" then
            {value_template: "{{ value_json.finding or None }}", json_attributes_topic: $topic,
             json_attributes_template: "{{ {\"text\": value_json.text} | tojson }}"}
          elif $key == "notify" then
            {value_template: "{{ value_json.notify }}", payload_on: "ON", payload_off: "OFF"}
          else
            {value_template: "{{ value_json.enabled }}", command_topic: "ha_claude/jobs/\($name)/enabled/set",
             payload_on: "ON", payload_off: "OFF", state_on: "ON", state_off: "OFF"}
          end
      ' > "$cfg" )
    _mqtt_send "homeassistant/$comp/ha_claude_job_${id}_$key/config" "$cfg" || rc=1
  done
  # The type is the chat's agent without its job- prefix, so the view stays
  # as it was: web for job-web; none for a file from the repo or another agent.
  ( umask 077; jq -cn --slurpfile j "$job" --slurpfile s "$state" --slurpfile c "$calls" --argjson repo "$repo" "$HC_JQ_CLEAN"'
      def time: if type == "number" then todate else null end;
      def text($nl): if type == "string" then clean($nl) else null end;
      $j[0] as $j | $s[0] as $s
      | {run_by: ($j.run_by | text(false)),
         status: ($s.status // "idle"), error: ($s.error // null),
         next_run: ($s.next_run | time), last_run: ($s.last_run | time),
         finding: ($s.finding | text(false)), text: ($s.text | text(true)),
         notify: (if $s.notify == true then "ON" else "OFF" end),
         enabled: (if $j.enabled == true then "ON" else "OFF" end),
         type: (if $repo then null
                elif $j.agent | IN("job-private", "job-web", "job-all") then $j.agent | ltrimstr("job-")
                else null end), schedule: (if ($j.schedule | type) == "object" then $j.schedule else null end),
         end: ($j.end | text(false)), task: ($j.task | text(true)), description: ($j.description | text(true)), calls: $c[0]}
    ' > "$cfg" )
  _mqtt_send "$topic" "$cfg" || rc=1
  rm -rf -- "${dir:?}"
  _mqtt_published add "$name"
  return "$rc"
}

# mqtt_remove_job <name> - removes the job's entities and its state.
mqtt_remove_job() {
  job_name_ok "$1" || return 0
  mqtt_known || return 0
  _mqtt_locked _mqtt_remove_job "$1"
}

# _mqtt_remove_job <name> - the same, under the lock. The job leaves the
# published list only when the broker took every removal; otherwise the
# next tick tries again.
_mqtt_remove_job() {
  local e ok=1
  for e in "${HC_MQTT_ENTITIES[@]}"; do
    _mqtt_send "homeassistant/${e%%/*}/ha_claude_job_$(_mqtt_id "$1")_${e#*/}/config" || ok=0
  done
  _mqtt_send "$HC_MQTT_PREFIX/$1/state" || ok=0
  if (( ok )); then
    _mqtt_published remove "$1"
  else
    log "mqtt: $1 is not removed yet; the next tick tries again"
  fi
}

# _mqtt_remove_gone - under the lock: removes the published jobs that have
# no file now.
_mqtt_remove_gone() {
  local name
  while read -r name; do
    job_name_ok "$name" || continue
    [[ -e "$HC_JOBS/$name.json" || -L "$HC_JOBS/$name.json" ]] || _mqtt_remove_job "$name" || true
  done < <(cat "$HC_JOB_STATE/published" 2>/dev/null)
}

# mqtt_republish_all - at start: the jobs that were published and have no
# file now are removed, and the job files a tick reads are published.
mqtt_republish_all() {
  local name
  mqtt_known || return 0
  _mqtt_locked _mqtt_remove_gone || true
  while read -r name; do
    mqtt_publish_job "$name" || true
  done < <(_jobs_order "$(date +%F)")
}

# _mqtt_notify <name> - raises ha_claude_job_notify with the job and its
# finding, once for each run whose notify went from false to true. The body
# is read by curl from a file only root can read; the token goes on
# standard input.
#
# The run is known by its end, last_end: a run that starts clears
# notify_rose and changes last_run, and must not count as a new rise. The
# check and the mark are one step, under the lock.
_mqtt_notify() {
  local name="$1" state body run
  state="$(_job_state "$name")"
  [[ "$(jq -r '.notify_rose == true and .status != "running"' <<<"$state")" == true ]] || return 0
  run="$(jq -r '.last_end // 0' <<<"$state")"
  _mqtt_locked _mqtt_mark "$name" "$run" || return 0
  if [[ -z "${SUPERVISOR_TOKEN:-}" ]]; then
    log "jobs: $name notifies (not reported: no Supervisor token)"
    return 0
  fi
  body="$(mktemp "$HC_STATE/job-notify.XXXXXX")" || return 0
  ( umask 077; jq -c --arg job "$name" "$HC_JQ_CLEAN"'{job: $job, finding: ((.finding // "") | clean(false))}' \
      <<<"$state" > "$body" )
  if curl -fsS -m 10 -o /dev/null -X POST -H "Content-Type: application/json" \
       --data-binary "@$body" -K - \
       "${HC_CORE_API:-http://supervisor/core/api}/events/ha_claude_job_notify" \
       <<<"header = \"Authorization: Bearer $SUPERVISOR_TOKEN\""; then
    log "jobs: $name notifies"
  else
    log "jobs: $name notifies (could not reach Home Assistant)"
  fi
  rm -f -- "$body"
}

# _mqtt_mark <name> <run> - true, and marked, when the run was not told yet.
_mqtt_mark() {
  local mark="$HC_JOB_STATE/$1.notified"
  [[ "$(cat "$mark" 2>/dev/null)" != "$2" ]] || return 1
  printf '%s\n' "$2" > "$mark"
}

# jobs_on_change <name> - fills the jobs' hook: a job with a file and a
# state is published, and its notify raised; one without is removed.
jobs_on_change() {
  job_name_ok "$1" || return 0
  if [[ -e "$HC_JOBS/$1.json" || -L "$HC_JOBS/$1.json" ]]; then
    mqtt_publish_job "$1" || true
    [[ -f "$HC_JOB_STATE/$1.json" ]] && { _mqtt_notify "$1" || true; }
  else
    mqtt_remove_job "$1" || true
    rm -f -- "${HC_JOB_STATE:?}/$1.notified"
  fi
  return 0
}

# _mqtt_enabled_others <name> - prints how many other chat job files are
# enabled, valid or not: the safe direction for the limit. A file from the
# repo is outside the limit, by its origin.
_mqtt_enabled_others() {
  local other n=0 copy
  copy="$(mktemp "$HC_STATE/job-count.XXXXXX")" || { echo "$HC_JOBS_MAX"; return 0; }
  while read -r other; do
    [[ "$other" != "$1" ]] || continue
    fixed_is "$other" && continue
    job_read "$other" "$copy" || continue
    [[ "$(jq -rs 'if length == 1 and (.[0] | type) == "object"
                  then .[0].enabled == true else false end' "$copy" 2>/dev/null)" == true ]] && n=$((n + 1))
  done < <(_jobs_order "$(date +%F)")
  rm -f -- "$copy"
  printf '%s\n' "$n"
}

# mqtt_on_switch <line> - one message from the listener, "<topic> <payload>":
# ON or OFF for an existing job file. ON only while fewer than 10 other jobs
# are enabled. Only enabled changes; the file is rewritten whole and
# replaced in one step, as the Claude user, whose folder it is.
mqtt_on_switch() {
  local line="$1" topic payload name want
  local re="^$HC_MQTT_PREFIX/([a-z][a-z0-9-]{0,31})/enabled/set\$"
  topic="${line%% *}"
  [[ "$line" == *" "* ]] && payload="${line#* }" || payload=""
  [[ "$topic" =~ $re ]] || return 0
  name="${BASH_REMATCH[1]}"
  # The listener has no tick: each message tries the broker afresh.
  HC_MQTT_FAILED=0
  case "$payload" in
    ON) want=true ;;
    OFF) want=false ;;
    *) return 0 ;;
  esac
  # The read-to-move of the file is alone against the placing of the fixed
  # files, whose lock it takes (for every job, so there is one path), or a
  # placed file written between the two would be written over.
  # Nothing is published when nothing was tried.
  _fixed_locked _mqtt_switch_move "$name" "$want" "$payload" || return 0
  mqtt_publish_job "$name" || true
}

# _mqtt_switch_move <name> <true|false> <payload> - the read, the rewrite
# and the move of the job's file, under the fixed lock. A fixed job is
# outside the limit of 10, as it is outside the cap of the tick.
_mqtt_switch_move() {
  local name="$1" want="$2" payload="$3" copy new
  copy="$(mktemp "$HC_STATE/job-switch.XXXXXX")" || return 1
  new="$copy.new"
  if ! job_read "$name" "$copy"; then
    rm -f -- "$copy"
    return 1
  fi
  if [[ "$want" == true ]] && ! fixed_is "$name" && (( $(_mqtt_enabled_others "$name") >= HC_JOBS_MAX )); then
    log "jobs: $name stays off: $HC_JOBS_MAX other jobs are on"
    rm -f -- "$copy"
    return 1
  fi
  if ! ( umask 077; jq -cs --argjson on "$want" \
           'if length == 1 and (.[0] | type) == "object" then .[0] | .enabled = $on else error("shape") end' \
           "$copy" > "$new" 2>/dev/null ); then
    rm -f -- "$copy" "$new"
    return 1
  fi
  # The Claude user writes the new file beside the old one and moves it
  # over it; what it writes comes on standard input, from root's copy.
  # shellcheck disable=SC2016  # the inner shell's arguments, not this one's
  if as_claude sh -c 'cat > "$1.switch" && mv -f "$1.switch" "$1"' sh "$HC_JOBS/$name.json" < "$new" >/dev/null 2>&1; then
    log "jobs: $name switched $payload"
  else
    log "jobs: $name could not be switched"
  fi
  rm -f -- "$copy" "$new"
  return 0
}

# mqtt_listen_start - starts the listener for the switches when none runs:
# a client that waits for messages on the switches' topics, started again
# when it ends. Retained messages are skipped, so a command left on the
# broker is not taken again at every start.
mqtt_listen_start() {
  local pid=""
  [[ -f "$HC_STATE/mqtt-listen.pid" ]] && pid="$(cat "$HC_STATE/mqtt-listen.pid")"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null && return 0
  (
    while true; do
      _mqtt_client sub -R -v -t "$HC_MQTT_PREFIX/+/enabled/set" </dev/null 2>/dev/null \
        | while IFS= read -r line; do mqtt_on_switch "$line"; done
      sleep "$HC_MQTT_RETRY"
    done
  ) &
  printf '%s\n' "$!" > "$HC_STATE/mqtt-listen.pid"
}

# mqtt_listen_stop - stops the listener and its client.
mqtt_listen_stop() {
  local pid=""
  [[ -f "$HC_STATE/mqtt-listen.pid" ]] && pid="$(cat "$HC_STATE/mqtt-listen.pid")"
  if [[ "$pid" =~ ^[1-9][0-9]*$ && "$pid" != "$$" ]]; then
    _job_kill_tree "$pid"
  fi
  rm -f -- "${HC_STATE:?}/mqtt-listen.pid"
}
