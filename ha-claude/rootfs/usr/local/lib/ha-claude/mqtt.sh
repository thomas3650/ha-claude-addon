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
HC_MQTT_PREFIX=ha_claude/jobs
HC_MQTT_NO_BROKER_LOGGED=0
# The entities of a job: component and key.
HC_MQTT_ENTITIES=(sensor/status sensor/next_run sensor/last_run sensor/finding binary_sensor/notify switch/enabled)

# _mqtt_client <pub|sub> [args...] - runs a client with the login from its
# config file.
_mqtt_client() {
  local name="mosquitto_$1"
  shift
  XDG_CONFIG_HOME="$HC_MQTT_DIR" "$name" "$@"
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

# jobs_can_run - true when Home Assistant can see the jobs: a broker is
# known, or is found now. The first time it is not, the log says so once.
# With a broker found, the listener runs and every job is published.
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
  fi
  mqtt_listen_start
  return 0
}

# _mqtt_send <topic> [file] - publishes the file's content on the topic,
# retained; without a file, an empty retained message, which removes it.
_mqtt_send() {
  if [[ -n "${2:-}" ]]; then
    _mqtt_client pub -q 1 -r -t "$1" -s < "$2" >/dev/null 2>&1
  else
    _mqtt_client pub -q 1 -r -n -t "$1" </dev/null >/dev/null 2>&1
  fi || log "mqtt: could not publish to the broker"
}

# _mqtt_published <add|remove> <name> - the root-only list of the jobs that
# have entities, so those whose file has gone are removed at start.
_mqtt_published() {
  local list="$HC_JOB_STATE/published" tmp
  mkdir -p "$HC_JOB_STATE"
  tmp="$list.tmp"
  { [[ -f "$list" ]] && grep -v -x -F -- "$2" "$list"; [[ "$1" == add ]] && printf '%s\n' "$2"; } > "$tmp" || true
  mv -f "$tmp" "$list"
}

# _mqtt_calls <name> <out> - writes the last 20 tool calls from the run log
# the gate writes, each its tool and its input in at most 200 characters.
# The log is the Claude user's, so it is read through a copy that user
# makes: its last 64 KiB, within a few seconds.
_mqtt_calls() {
  local copy="$HC_STATE/job-$1.calls"
  if [[ -e "$HC_JOB_RESULTS/$1.log.jsonl" ]] \
     && claude_copy "$HC_JOB_RESULTS/$1.log.jsonl" "$copy" 65536 "$HC_RESULT_WAIT" tail; then
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
  local name="$1" e comp key cfg="$HC_STATE/job-$1.mqtt" job="$HC_STATE/job-$1.file"
  local calls="$HC_STATE/job-$1.callsj" state="$HC_STATE/job-$1.statej" topic="$HC_MQTT_PREFIX/$1/state"
  job_name_ok "$name" || return 0
  mqtt_known || return 0
  ( umask 077
    # The file as it is, valid or not, so an invalid job still shows.
    if job_read "$name" "$HC_STATE/job-$name.raw"; then
      jq -cs 'if length == 1 and (.[0] | type) == "object" then .[0] else {} end' \
        "$HC_STATE/job-$name.raw" > "$job" 2>/dev/null || echo '{}' > "$job"
    else
      echo '{}' > "$job"
    fi
    rm -f -- "$HC_STATE/job-$name.raw"
    _job_state "$name" > "$state"
    _mqtt_calls "$name" "$calls"
  )
  for e in "${HC_MQTT_ENTITIES[@]}"; do
    comp="${e%%/*}"; key="${e#*/}"
    # shellcheck disable=SC2016  # jq's variables and Home Assistant's templates
    ( umask 077; jq -cn --arg name "$name" --arg comp "$comp" --arg key "$key" --arg topic "$topic" '
        ("ha_claude_job_\($name)_\($key)") as $id
        | {name: "\($name) \($key | gsub("_"; " "))", unique_id: $id, default_entity_id: "\($comp).\($id)",
           state_topic: $topic,
           device: {identifiers: ["ha_claude_jobs"], name: "HA Claude jobs"}}
        + if $key == "status" then
            {value_template: "{{ value_json.status }}", json_attributes_topic: $topic,
             json_attributes_template: "{{ {\"type\": value_json.type, \"schedule\": value_json.schedule, \"end\": value_json.end, \"task\": value_json.task, \"error\": value_json.error, \"calls\": value_json.calls} | tojson }}"}
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
    _mqtt_send "homeassistant/$comp/ha_claude_job_${name}_$key/config" "$cfg"
  done
  ( umask 077; jq -cn --slurpfile j "$job" --slurpfile s "$state" --slurpfile c "$calls" "$HC_JQ_CLEAN"'
      def time: if type == "number" then todate else null end;
      def text($nl): if type == "string" then clean($nl) else null end;
      $j[0] as $j | $s[0] as $s
      | {status: ($s.status // "idle"), error: ($s.error // null),
         next_run: ($s.next_run | time), last_run: ($s.last_run | time),
         finding: ($s.finding | text(false)), text: ($s.text | text(true)),
         notify: (if $s.notify == true then "ON" else "OFF" end),
         enabled: (if $j.enabled == true then "ON" else "OFF" end),
         type: ($j.type | text(false)), schedule: (if ($j.schedule | type) == "object" then $j.schedule else null end),
         end: ($j.end | text(false)), task: ($j.task | text(true)), calls: $c[0]}
    ' > "$cfg" )
  _mqtt_send "$topic" "$cfg"
  rm -f -- "$cfg" "$job" "$calls" "$state"
  _mqtt_published add "$name"
}

# mqtt_remove_job <name> - removes the job's entities and its state.
mqtt_remove_job() {
  local e
  job_name_ok "$1" || return 0
  mqtt_known || return 0
  for e in "${HC_MQTT_ENTITIES[@]}"; do
    _mqtt_send "homeassistant/${e%%/*}/ha_claude_job_${1}_${e#*/}/config"
  done
  _mqtt_send "$HC_MQTT_PREFIX/$1/state"
  _mqtt_published remove "$1"
}

# mqtt_republish_all - at start: every job file is published, and the jobs
# that were published and have no file now are removed.
mqtt_republish_all() {
  local name
  mqtt_known || return 0
  while read -r name; do
    [[ -e "$HC_JOBS/$name.json" || -L "$HC_JOBS/$name.json" ]] || mqtt_remove_job "$name"
  done < <(cat "$HC_JOB_STATE/published" 2>/dev/null)
  while read -r name; do
    mqtt_publish_job "$name"
  done < <(job_list)
}

# _mqtt_notify <name> - raises ha_claude_job_notify with the job and its
# finding, once for each run whose notify went from false to true. The body
# is read by curl from a file only root can read; the token goes on
# standard input.
_mqtt_notify() {
  local name="$1" state mark="$HC_JOB_STATE/$1.notified" body="$HC_STATE/job-$1.notify" run
  state="$(_job_state "$name")"
  [[ "$(jq -r '.notify_rose == true' <<<"$state")" == true ]] || return 0
  run="$(jq -r '.last_run // 0' <<<"$state")"
  [[ "$(cat "$mark" 2>/dev/null)" != "$run" ]] || return 0
  printf '%s\n' "$run" > "$mark"
  if [[ -z "${SUPERVISOR_TOKEN:-}" ]]; then
    log "jobs: $name notifies (not reported: no Supervisor token)"
    return 0
  fi
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

# jobs_on_change <name> - fills the jobs' hook: a job with a file and a
# state is published, and its notify raised; one without is removed.
jobs_on_change() {
  job_name_ok "$1" || return 0
  if [[ -e "$HC_JOBS/$1.json" || -L "$HC_JOBS/$1.json" ]]; then
    mqtt_publish_job "$1"
    [[ -f "$HC_JOB_STATE/$1.json" ]] && _mqtt_notify "$1"
  else
    mqtt_remove_job "$1"
    rm -f -- "${HC_JOB_STATE:?}/$1.notified"
  fi
  return 0
}

# _mqtt_enabled_others <name> - prints how many other job files are
# enabled, valid or not: the safe direction for the limit.
_mqtt_enabled_others() {
  local other n=0 copy="$HC_STATE/job-switch.count"
  while read -r other; do
    [[ "$other" != "$1" ]] || continue
    job_read "$other" "$copy" || continue
    [[ "$(jq -rs 'if length == 1 and (.[0] | type) == "object" and (.[0] | has("agent") | not)
                  then .[0].enabled == true else false end' "$copy" 2>/dev/null)" == true ]] && n=$((n + 1))
  done < <(job_list)
  rm -f -- "$copy"
  printf '%s\n' "$n"
}

# mqtt_on_switch <line> - one message from the listener, "<topic> <payload>":
# ON or OFF for an existing job file. ON only while fewer than 10 other jobs
# are enabled. Only enabled changes; the file is rewritten whole and
# replaced in one step, as the Claude user, whose folder it is.
mqtt_on_switch() {
  local line="$1" topic payload name want copy="$HC_STATE/job-switch.in" new="$HC_STATE/job-switch.new"
  local re="^$HC_MQTT_PREFIX/([a-z][a-z0-9-]{0,31})/enabled/set\$"
  topic="${line%% *}"
  [[ "$line" == *" "* ]] && payload="${line#* }" || payload=""
  [[ "$topic" =~ $re ]] || return 0
  name="${BASH_REMATCH[1]}"
  case "$payload" in
    ON) want=true ;;
    OFF) want=false ;;
    *) return 0 ;;
  esac
  job_read "$name" "$copy" || return 0
  if [[ "$want" == true ]] && (( $(_mqtt_enabled_others "$name") >= HC_JOBS_MAX )); then
    log "jobs: $name stays off: $HC_JOBS_MAX other jobs are on"
    rm -f -- "$copy"
    return 0
  fi
  if ! ( umask 077; jq -cs --argjson on "$want" \
           'if length == 1 and (.[0] | type) == "object" then .[0] | .enabled = $on else error("shape") end' \
           "$copy" > "$new" 2>/dev/null ); then
    rm -f -- "$copy" "$new"
    return 0
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
  mqtt_publish_job "$name"
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
