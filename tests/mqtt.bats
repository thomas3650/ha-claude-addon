load helpers

# Home Assistant sees the jobs through MQTT. The stand-ins: mosquitto_pub
# writes each message to a file of its own (its arguments, its standard
# input and the config folder it was given), and curl answers the
# Supervisor's broker question and keeps what it would send.
stub_mqtt() {
  export SUPERVISOR_TOKEN=tok-123
  export HC_LIMIT_BIN="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/ha-claude-limit"
  export HC_MQTT_DIR="$BATS_TEST_TMPDIR/mqtt-conf"
  PUB="$BATS_TEST_TMPDIR/pub"; mkdir -p "$PUB"; : > "$PUB/all"
  SENT="$BATS_TEST_TMPDIR/sent"; mkdir -p "$SENT"
  BROKER='{"result":"ok","data":{"host":"core-mosquitto","port":1883,"ssl":false,"username":"addons","password":"s3cret-pw","protocol":"3.1.1"}}'
  mosquitto_pub() {
    local topic="" a prev="" payload
    for a in "$@"; do [[ "$prev" == -t ]] && topic="$a"; prev="$a"; done
    if [[ " $* " == *" -n "* ]]; then payload=""; else payload="$(cat)"; fi
    printf '%s\t%s\t%s\n' "$*" "${XDG_CONFIG_HOME:-}" "$topic" >> "$PUB/all"
    printf '%s' "$payload" > "$PUB/$(tr '/' '_' <<<"$topic")"
  }
  curl() {
    local a
    printf '%s\n' "$*" >> "$SENT/args"
    cat >> "$SENT/stdin"
    for a in "$@"; do [[ "$a" == @* ]] && cat "${a#@}" >> "$SENT/bodies"; done
    if [[ "$*" == *"/services/mqtt"* ]]; then
      [[ -n "$BROKER" ]] || return 22
      printf '%s' "$BROKER"
    fi
    return 0
  }
}

teardown() {
  declare -F mqtt_listen_stop >/dev/null && mqtt_listen_stop
  declare -F jobs_stop >/dev/null && jobs_stop
  return 0
}

load_mqtt() {
  load_lib options env layout morning result jobs mqtt
  ensure_layout
  stub_mqtt
  TODAY="$(date +%F)"
}

days_after() {
  jq -rn --arg d "$1" --argjson n "$2" '$d | strptime("%Y-%m-%d") | mktime + $n * 86400 | strftime("%Y-%m-%d")'
}

job_file() {
  jq -n --arg today "$TODAY" --arg end "$(days_after "$TODAY" 14)" \
    '{type: "web", task: "Find the lowest price of a kettle.", schedule: {every_hours: 4},
      end: $end, enabled: true, created: $today}' \
    | jq "${2:-.}" > "$HC_JOBS/$1.json"
}

# msg <topic> - the last message published on the topic.
msg() { cat "$PUB/$(tr '/' '_' <<<"$1")"; }

@test "the broker's login goes to the clients' own config files, for root only, and on no command line" {
  load_mqtt
  mqtt_config
  [ "$(stat -c %a "$HC_MQTT_DIR" 2>/dev/null || stat -f %Lp "$HC_MQTT_DIR")" = 700 ]
  for f in mosquitto_pub mosquitto_sub; do
    [ "$(stat -c %a "$HC_MQTT_DIR/$f" 2>/dev/null || stat -f %Lp "$HC_MQTT_DIR/$f")" = 600 ]
    [ "$(cat "$HC_MQTT_DIR/$f")" = $'-h core-mosquitto\n-p 1883\n-u addons\n-P s3cret-pw' ]
  done
  grep -q "/services/mqtt" "$SENT/args"
  run grep tok-123 "$SENT/args"
  [ "$status" -eq 1 ]
  grep -q "Bearer tok-123" "$SENT/stdin"
  job_file price
  mqtt_publish_job price
  run grep -e s3cret -e addons "$PUB/all"
  [ "$status" -eq 1 ]
  [ "$(cut -f 2 "$PUB/all" | sort -u)" = "$HC_MQTT_DIR" ]
}

@test "a broker answer with a line break or a missing field is refused, and nothing is written" {
  load_mqtt
  BROKER='{"result":"ok","data":{"host":"h\n-P x","port":1883,"username":"u","password":"p"}}'
  run mqtt_config
  [ "$status" -eq 1 ]
  [ ! -e "$HC_MQTT_DIR/mosquitto_pub" ]
  BROKER='{"result":"ok","data":{"host":"h","port":1883,"username":"u"}}'
  run mqtt_config
  [ "$status" -eq 1 ]
  [ ! -e "$HC_MQTT_DIR/mosquitto_pub" ]
}

@test "without a broker the tick checks the files, runs no job, publishes nothing and says so once" {
  load_mqtt
  BROKER=""
  mkdir -p "$HC_WORKSPACE/.claude/agents"; touch "$HC_WORKSPACE/.claude/agents/job-web.md"
  job_file price
  jobs_tick 2> "$BATS_TEST_TMPDIR/first"
  grep -q "no MQTT broker" "$BATS_TEST_TMPDIR/first"
  jobs_tick 2> "$BATS_TEST_TMPDIR/second"
  run grep "no MQTT broker" "$BATS_TEST_TMPDIR/second"
  [ "$status" -eq 1 ]
  [ "$(jq -r .status "$HC_JOB_STATE/price.json")" = idle ]
  [ ! -e "$HC_JOB_STATE/price.pid" ]
  [ ! -s "$PUB/all" ]
}

@test "a job is published as six retained entities of one device, and a retained state" {
  load_mqtt
  mqtt_config
  job_file price
  mqtt_publish_job price
  for e in sensor/ha_claude_job_price_status sensor/ha_claude_job_price_next_run \
           sensor/ha_claude_job_price_last_run sensor/ha_claude_job_price_finding \
           binary_sensor/ha_claude_job_price_notify switch/ha_claude_job_price_enabled; do
    topic="homeassistant/$e/config"
    grep -q $'\t'"$topic"'$' "$PUB/all"
    [[ "$(grep $'\t'"$topic"'$' "$PUB/all" | cut -f 1)" == *"-r"* ]]
    [ "$(msg "$topic" | jq -r '.unique_id')" = "${e#*/}" ]
    [ "$(msg "$topic" | jq -r '.default_entity_id')" = "${e%%/*}.${e#*/}" ]
    [ "$(msg "$topic" | jq -c '.device.identifiers')" = '["ha_claude_jobs"]' ]
    [ "$(msg "$topic" | jq -r '.device.name')" = "HA Claude jobs" ]
    [ "$(msg "$topic" | jq -r '.state_topic')" = "ha_claude/jobs/price/state" ]
  done
  [ "$(msg homeassistant/sensor/ha_claude_job_price_next_run/config | jq -r .device_class)" = timestamp ]
  [ "$(msg homeassistant/sensor/ha_claude_job_price_last_run/config | jq -r .device_class)" = timestamp ]
  [ "$(msg homeassistant/switch/ha_claude_job_price_enabled/config | jq -r .command_topic)" = "ha_claude/jobs/price/enabled/set" ]
  [[ "$(grep $'\t'"ha_claude/jobs/price/state"'$' "$PUB/all" | cut -f 1)" == *"-r"* ]]
  state="$(msg ha_claude/jobs/price/state)"
  [ "$(jq -r .status <<<"$state")" = idle ]
  [ "$(jq -r .enabled <<<"$state")" = ON ]
  [ "$(jq -r .notify <<<"$state")" = OFF ]
  [ "$(jq -r .type <<<"$state")" = web ]
  [ "$(jq -r .task <<<"$state")" = "Find the lowest price of a kettle." ]
  [ "$(jq -c .schedule <<<"$state")" = '{"every_hours":4}' ]
  grep -qx price "$HC_JOB_STATE/published"
}

@test "the state carries the run's result, its times as timestamps, and the last 20 tool calls, short and plain" {
  load_mqtt
  mqtt_config
  job_file price
  jq -n '{first_seen: "2026-11-18", status: "ok", last_run: 1795000000, next_run: 1795014400,
          notify: true, finding: "Lowest\u0007 299 kr", text: "a\nb\u001bc"}' > "$HC_JOB_STATE/price.json"
  mkdir -p "$HC_JOB_RESULTS"
  for i in $(seq 1 25); do
    jq -cn --argjson i "$i" '{ts: "t", job: "price", type: "web", tool: "WebFetch", input: {url: ("http://x/" + ($i | tostring) + "/" + ("y" * 300))}}'
  done > "$HC_JOB_RESULTS/price.log.jsonl"
  echo 'not json' >> "$HC_JOB_RESULTS/price.log.jsonl"
  mqtt_publish_job price
  state="$(msg ha_claude/jobs/price/state)"
  [ "$(jq -r .finding <<<"$state")" = "Lowest 299 kr" ]
  [ "$(jq -r .text <<<"$state")" = $'a\nbc' ]
  [ "$(jq -r .notify <<<"$state")" = ON ]
  [ "$(jq -r .last_run <<<"$state")" = "$(jq -rn '1795000000 | todate')" ]
  [ "$(jq -r .next_run <<<"$state")" = "$(jq -rn '1795014400 | todate')" ]
  [ "$(jq '.calls | length' <<<"$state")" = 20 ]
  [ "$(jq -r '.calls[0].tool' <<<"$state")" = WebFetch ]
  [[ "$(jq -r '.calls[0].input' <<<"$state")" == *'http://x/6/'* ]]
  [ "$(jq '[.calls[].input | length] | max' <<<"$state")" -le 200 ]
}

@test "the run log is read through a copy the Claude user makes" {
  load_mqtt
  mqtt_config
  job_file price
  mkdir -p "$HC_JOB_RESULTS"
  printf '{"tool":"WebSearch","input":{"query":"q"}}\n' > "$HC_JOB_RESULTS/price.log.jsonl"
  as_claude() { echo "as_claude $*" >> "$BATS_TEST_TMPDIR/as"; "$@"; }
  mqtt_publish_job price
  grep -q "tail -c .* -- $HC_JOB_RESULTS/price.log.jsonl" "$BATS_TEST_TMPDIR/as"
  [ "$(msg ha_claude/jobs/price/state | jq -r '.calls[0].tool')" = WebSearch ]
}

@test "an invalid or unreadable job file is still shown, with its status" {
  load_mqtt
  mqtt_config
  printf 'not json' > "$HC_JOBS/price.json"
  jq -n '{first_seen: "2026-11-18", status: "invalid", error: "shape"}' > "$HC_JOB_STATE/price.json"
  mqtt_publish_job price
  [ "$(msg ha_claude/jobs/price/state | jq -r .status)" = invalid ]
  [ "$(msg ha_claude/jobs/price/state | jq -r .enabled)" = OFF ]
}

@test "a job that is gone is removed: an empty retained config for each entity, and an empty state" {
  load_mqtt
  mqtt_config
  job_file price
  mqtt_publish_job price
  : > "$PUB/all"
  rm "$HC_JOBS/price.json"
  jobs_on_change price
  [ "$(grep -c $'\t'homeassistant/ "$PUB/all")" -eq 6 ]
  grep -q $'\t'ha_claude/jobs/price/state'$' "$PUB/all"
  while IFS=$'\t' read -r args _ topic; do
    [[ " $args " == *" -r "* && " $args " == *" -n "* ]]
  done < "$PUB/all"
  run grep -x price "$HC_JOB_STATE/published"
  [ "$status" -eq 1 ]
}

@test "at start everything is published again, and what has no file is removed" {
  load_mqtt
  mqtt_config
  job_file price
  printf 'price\ngone\n' > "$HC_JOB_STATE/published"
  mqtt_republish_all
  [ "$(msg ha_claude/jobs/price/state | jq -r .status)" = idle ]
  grep -q $'\t'homeassistant/switch/ha_claude_job_gone_enabled/config'$' "$PUB/all"
  [ -z "$(msg homeassistant/switch/ha_claude_job_gone_enabled/config)" ]
  [ "$(cat "$HC_JOB_STATE/published")" = price ]
}

@test "a state change publishes the job" {
  load_mqtt
  mqtt_config
  job_file price
  jobs_tick
  [ "$(msg ha_claude/jobs/price/state | jq -r .status)" != "" ]
}

@test "the switch turns a job off by changing enabled only, as the Claude user" {
  load_mqtt
  mqtt_config
  job_file price '.notify = "below 300"'
  before="$(jq -S 'del(.enabled)' "$HC_JOBS/price.json")"
  as_claude() { echo "as_claude $*" >> "$BATS_TEST_TMPDIR/as"; "$@"; }
  mqtt_on_switch "ha_claude/jobs/price/enabled/set OFF"
  [ "$(jq -r .enabled "$HC_JOBS/price.json")" = false ]
  [ "$(jq -S 'del(.enabled)' "$HC_JOBS/price.json")" = "$before" ]
  grep -q "mv -f" "$BATS_TEST_TMPDIR/as"
  [ "$(msg ha_claude/jobs/price/state | jq -r .enabled)" = OFF ]
  mqtt_on_switch "ha_claude/jobs/price/enabled/set ON"
  [ "$(jq -r .enabled "$HC_JOBS/price.json")" = true ]
  [ "$(msg ha_claude/jobs/price/state | jq -r .enabled)" = ON ]
  ls -A "$HC_JOBS" > "$BATS_TEST_TMPDIR/left"
  [ "$(grep -v -x -e price.json -e ended "$BATS_TEST_TMPDIR/left")" = "" ]
}

@test "the switch accepts only ON or OFF, for a job file that exists" {
  load_mqtt
  mqtt_config
  job_file price '.enabled = false'
  cp "$HC_JOBS/price.json" "$BATS_TEST_TMPDIR/before"
  for line in "ha_claude/jobs/price/enabled/set on" "ha_claude/jobs/price/enabled/set ON " \
              "ha_claude/jobs/price/enabled/set TRUE" "ha_claude/jobs/price/enabled/set" \
              "ha_claude/jobs/Price/enabled/set ON" "ha_claude/jobs/../enabled/set ON" \
              "ha_claude/jobs/price/x/set ON" "ha_claude/jobs/none/enabled/set ON"; do
    mqtt_on_switch "$line"
  done
  cmp "$BATS_TEST_TMPDIR/before" "$HC_JOBS/price.json"
  [ ! -e "$HC_JOBS/none.json" ]
  [ ! -s "$PUB/all" ]
}

@test "the switch turns on no 11th job, and turns off any" {
  load_mqtt
  mqtt_config
  for n in a b c d e f g h i j; do job_file "j$n"; done
  job_file price '.enabled = false'
  mqtt_on_switch "ha_claude/jobs/price/enabled/set ON"
  [ "$(jq -r .enabled "$HC_JOBS/price.json")" = false ]
  mqtt_on_switch "ha_claude/jobs/ja/enabled/set OFF"
  [ "$(jq -r .enabled "$HC_JOBS/ja.json")" = false ]
  mqtt_on_switch "ha_claude/jobs/price/enabled/set ON"
  [ "$(jq -r .enabled "$HC_JOBS/price.json")" = true ]
}

@test "the switch does not touch a link or a file that is not JSON" {
  load_mqtt
  mqtt_config
  printf 'not json' > "$HC_JOBS/bad.json"
  mqtt_on_switch "ha_claude/jobs/bad/enabled/set OFF"
  [ "$(cat "$HC_JOBS/bad.json")" = "not json" ]
  job_file real
  mv "$HC_JOBS/real.json" "$BATS_TEST_TMPDIR/real.json"
  ln -s "$BATS_TEST_TMPDIR/real.json" "$HC_JOBS/link.json"
  mqtt_on_switch "ha_claude/jobs/link/enabled/set OFF"
  [ -L "$HC_JOBS/link.json" ]
  [ "$(jq -r .enabled "$BATS_TEST_TMPDIR/real.json")" = true ]
}

@test "a condition met raises ha_claude_job_notify once, with the job and the finding, from a file" {
  load_mqtt
  mqtt_config
  job_file price
  jq -n '{first_seen: "2026-11-18", status: "ok", last_run: 100, notify: true, notify_rose: true,
          finding: "Lowest 299\u0007 kr"}' > "$HC_JOB_STATE/price.json"
  jobs_on_change price
  grep -q "/events/ha_claude_job_notify" "$SENT/args"
  [ "$(jq -c . "$SENT/bodies")" = '{"job":"price","finding":"Lowest 299 kr"}' ]
  run grep "299" "$SENT/args"
  [ "$status" -eq 1 ]
  jobs_on_change price
  [ "$(grep -c ha_claude_job_notify "$SENT/args")" -eq 1 ]
  jq '.last_run = 200' "$HC_JOB_STATE/price.json" > "$BATS_TEST_TMPDIR/s" && cp "$BATS_TEST_TMPDIR/s" "$HC_JOB_STATE/price.json"
  jobs_on_change price
  [ "$(grep -c ha_claude_job_notify "$SENT/args")" -eq 2 ]
}

@test "notify that did not rise raises nothing" {
  load_mqtt
  mqtt_config
  job_file price
  jq -n '{first_seen: "2026-11-18", status: "ok", last_run: 100, notify: true, notify_rose: false}' > "$HC_JOB_STATE/price.json"
  jobs_on_change price
  run grep ha_claude_job_notify "$SENT/args"
  [ "$status" -eq 1 ]
}

@test "the listener hands each switch message on, and runs again when the client ends" {
  load_mqtt
  mqtt_config
  COUNT="$BATS_TEST_TMPDIR/subs"
  mosquitto_sub() { echo sub >> "$COUNT"; printf 'ha_claude/jobs/price/enabled/set OFF\n'; }
  mqtt_on_switch() { echo "$1" >> "$BATS_TEST_TMPDIR/got"; }
  HC_MQTT_RETRY=0.2 mqtt_listen_start
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(wc -l < "$COUNT" 2>/dev/null || echo 0)" -ge 2 ] && break
    sleep 0.5
  done
  mqtt_listen_stop
  [ "$(wc -l < "$COUNT")" -ge 2 ]
  grep -qx "ha_claude/jobs/price/enabled/set OFF" "$BATS_TEST_TMPDIR/got"
  pid="$(cat "$HC_STATE/mqtt-listen.pid" 2>/dev/null || true)"
  [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null
}

@test "the add-on asks for the MQTT service and installs its clients" {
  grep -qx 'services:' "$BATS_TEST_DIRNAME/../ha-claude/config.yaml"
  grep -qx '  - mqtt:want' "$BATS_TEST_DIRNAME/../ha-claude/config.yaml"
  grep -q 'mosquitto-clients' "$BATS_TEST_DIRNAME/../ha-claude/Dockerfile"
  grep -q ' jobs mqtt commands; do' "$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/addon-run"
  grep -qx '  mqtt_listen_stop' "$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/addon-run"
}

@test "a name with a hyphen is written with an underscore in the IDs, and kept in the topics of its own" {
  load_mqtt
  mqtt_config
  # A job name holds no underscore, so two names never meet in one ID.
  run job_name_ok a_b
  [ "$status" -eq 1 ]
  job_file my-job
  mqtt_publish_job my-job
  cfg="homeassistant/sensor/ha_claude_job_my_job_status/config"
  [ "$(msg "$cfg" | jq -r .unique_id)" = ha_claude_job_my_job_status ]
  [ "$(msg "$cfg" | jq -r .default_entity_id)" = sensor.ha_claude_job_my_job_status ]
  [ "$(msg "$cfg" | jq -r .state_topic)" = ha_claude/jobs/my-job/state ]
  [ "$(msg homeassistant/switch/ha_claude_job_my_job_enabled/config | jq -r .command_topic)" = ha_claude/jobs/my-job/enabled/set ]
  run grep "ha_claude_job_my-job" "$PUB/all"
  [ "$status" -eq 1 ]
  : > "$PUB/all"
  rm "$HC_JOBS/my-job.json"
  jobs_on_change my-job
  grep -q $'\t'homeassistant/switch/ha_claude_job_my_job_enabled/config'$' "$PUB/all"
  grep -q $'\t'ha_claude/jobs/my-job/state'$' "$PUB/all"
}
