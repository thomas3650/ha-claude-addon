load helpers

# One runner for every job: a file from the repo with run_by jobs is started
# by the tick, and a repo file by its command, in the same runner as a chat's
# job. The agents are made up: alpha-run, beta-run and gamma-run.

setup_file() {
  export TZ=Europe/Copenhagen
}

# A stand-in for Claude Code. as_claude scrubs the environment, so the
# stand-in reads its mode from files beside itself: mode-<agent> when there
# is one, else mode. It learns its agent from HA_CLAUDE_UNATTENDED, and keeps
# what each start saw in files named after the agent.
runner_setup() {
  load_lib options env layout retention morning result run outcome jobs fixed commands
  ensure_layout
  mkdir -p "$HC_WORKSPACE/jobs" "$HC_WORKSPACE/.claude/agents" "$HC_HANDOVER"
  touch "$HC_WORKSPACE/.claude/agents/job-web.md"
  TODAY="$(date +%F)"
  STUB="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB"
  printf '%s\n%s\n%s\n' "$HC_RESULTS" "$HC_JOB_RESULTS" "$HC_HANDOVER/$TODAY.md" > "$STUB/paths"
  echo write > "$STUB/mode"
  cat > "$STUB/claude" <<'EOT'
#!/usr/bin/env bash
here="$(dirname "$0")"
{ read -r results; read -r jobresults; read -r handover; } < "$here/paths"
agent="$HA_CLAUDE_UNATTENDED"
mode="$(cat "$here/mode-$agent" 2>/dev/null || cat "$here/mode")"
printf '%s\n' "$@" > "$here/$agent.argv"
cat > "$here/$agent.stdin"
env > "$here/$agent.env"
pwd -P > "$here/$agent.cwd"
echo "$agent" >> "$here/starts"
echo "stand-in output"
case "$agent" in
  job-*) file="$jobresults/$HA_CLAUDE_JOB.json" ;;
  *) file="$results/$agent.json" ;;
esac
case "$mode" in
  write) printf '{"verdict":"Found by %s","text":"one\\ntwo","count":2}' "$agent" > "$file" ;;
  both) printf '{"verdict":"v","text":"t"}' > "$file"; printf '# written\n' > "$handover" ;;
  handover) printf '# written\n' > "$handover" ;;
  together) sleep 2; printf '{"verdict":"Found by %s","text":"t"}' "$agent" > "$file" ;;
  slow) sleep 3; printf '{"verdict":"v","text":"t"}' > "$file" ;;
  error) printf '{"verdict":"v","text":"t"}' > "$file"; exit 1 ;;
  nothing) ;;
  hang) exec sleep 30 ;;
esac
EOT
  chmod +x "$STUB/claude"
  export HC_CLAUDE_BIN="$STUB/claude"
  export HC_LIMIT_BIN="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/ha-claude-limit"
  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  raise_outcome() { echo "outcome $*" >> "$CALLS"; }
  clear_chat() { echo "clear $1" >> "$CALLS"; }
  CHANGES="$BATS_TEST_TMPDIR/changes"; : > "$CHANGES"
  jobs_on_change() { echo "$1" >> "$CHANGES"; }
}

teardown() {
  declare -F jobs_stop >/dev/null && jobs_stop
  pkill -f "$BATS_TEST_TMPDIR/stub" 2>/dev/null || true
  return 0
}

# repo_job <name> [jq-update] - a file from the repo, run by the jobs, due
# now (at this quarter hour, every day: its window is open for at least its
# limit), its agent, and the placed copy. In the last half minute of a
# quarter it waits for the next one, so a test with a limit of a second
# still finds the window open.
repo_job() {
  local h m
  (( $(date +%s) % 900 < 870 )) || sleep 31
  read -r h m <<<"$(date '+%H %M')"
  jq -nc --arg n "$1" --arg t "$(printf '%s:%02d' "$h" $((10#$m / 15 * 15)))" \
    '{agent: $n, run_by: "jobs", schedule: {time: $t}, enabled: true}' \
    | jq -c "${2:-.}" > "$HC_WORKSPACE/jobs/$1.json"
  touch "$HC_WORKSPACE/.claude/agents/$1.md"
  cp "$HC_WORKSPACE/jobs/$1.json" "$HC_JOBS/$1.json"
}

# chat_job <name> - a chat's job, due now.
chat_job() {
  jq -n --arg t "$TODAY" --arg e "$(jq -rn --arg d "$TODAY" '$d | strptime("%Y-%m-%d") | mktime + 86400 | strftime("%Y-%m-%d")')" \
    '{agent: "job-web", task: "Find a kettle.", schedule: {every_hours: 4}, end: $e, enabled: true, created: $t,
      notify: "below 300"}' > "$HC_JOBS/$1.json"
}

# wait_runs - waits until every runner has ended, its last step included.
wait_runs() {
  local pidfile pid
  for pidfile in "$HC_JOB_STATE"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    pid="$(cat "$pidfile")"
    while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done
  done
  return 0
}

state() { jq -r "$2" "$HC_JOB_STATE/$1.json"; }

@test "a due repo file starts in the runner with its agent, first message and limits" {
  runner_setup
  repo_job alpha-run '. + {task: "Look at the roof.", timeout: 120, max_turns: 7}'
  jobs_tick
  wait_runs
  args="$(cat "$STUB/alpha-run.argv")"
  [[ "$args" == *$'--agent\nalpha-run'* ]]
  [[ "$args" == *$'--max-turns\n7'* ]]
  [[ "$args" == *$'--permission-mode\ndefault'* ]]
  [[ "$args" == *"--no-session-persistence"* ]]
  [[ "$args" != *"roof"* ]]
  [ "$(cat "$STUB/alpha-run.stdin")" = "Today is $TODAY. Your result file is $HC_RESULTS/alpha-run.json. Do your run."$'\n'"Extra task from the owner: Look at the roof." ]
  grep -qx "HA_CLAUDE_UNATTENDED=alpha-run" "$STUB/alpha-run.env"
  grep -qx "CLAUDE_CODE_DISABLE_AUTO_MEMORY=1" "$STUB/alpha-run.env"
  ! grep -q '^HA_CLAUDE_JOB=' "$STUB/alpha-run.env"
  [ "$(cat "$STUB/alpha-run.cwd")" = "$(cd "$HC_WORKSPACE" && pwd -P)" ]
  [ "$(cat "$HC_JOB_STATE/alpha-run.limit")" = 120 ]
  [ "$(state alpha-run .status)" = ok ]
  [ "$(state alpha-run .finding)" = "Found by alpha-run" ]
  [ "$(state alpha-run .text)" = $'one\ntwo' ]
  [[ "$(state alpha-run .last_run)" =~ ^[0-9]+$ ]]
  [[ "$(state alpha-run .next_run)" =~ ^[0-9]+$ ]]
  grep -qx 'outcome run ok alpha-run jobs' "$CALLS"
  [ "$(cat "$HC_STATE/job-alpha-run.log")" = "stand-in output" ]
  [ "$(stat -c %a "$HC_STATE/job-alpha-run.log" 2>/dev/null || stat -f %Lp "$HC_STATE/job-alpha-run.log")" = 600 ]
  [ ! -e "$HC_STATE/job-alpha-run.prompt" ]
}

@test "a repo run starts without its agent's last result, from a clean handover folder, and without the token" {
  runner_setup
  export SUPERVISOR_TOKEN=tok-123
  curl() { cat > /dev/null; }
  repo_job alpha-run
  printf '{"verdict":"old","text":"old"}' > "$HC_RESULTS/alpha-run.json"
  touch "$HC_HANDOVER/CLAUDE.md"
  echo nothing > "$STUB/mode"
  jobs_tick 2>/dev/null
  wait_runs
  [ ! -e "$HC_RESULTS/alpha-run.json" ]
  [ ! -e "$HC_HANDOVER/CLAUDE.md" ]
  [ "$(state alpha-run .status)" = failed ]
  ! grep -q -e tok-123 -e SUPERVISOR "$STUB/alpha-run.env"
}

@test "the context lines come before the task, and a repo file without limits has the run options" {
  runner_setup
  set_options '{"run_max_turns": 9}'
  printf '{"verdict":"v","text":"t","notify":false}' > "$HC_JOB_RESULTS/price.json"
  chat_job price
  jq -n '{status: "ok", last_run: 1}' > "$HC_JOB_STATE/price.json"
  repo_job beta-run '. + {context: ["handover", "jobs"], task: "Say hello."}'
  job="$(fixed_check beta-run "$HC_JOBS/beta-run.json")"
  [ "$(job_first_message beta-run "$job")" = "Today is $TODAY. Your result file is $HC_RESULTS/beta-run.json. Do your run."$'\n'"Today's handover file is $HC_HANDOVER/$TODAY.md."$'\n'"Jobs: price"$'\n'"Extra task from the owner: Say hello." ]
  # Without a task and without a jobs line, only what there is.
  repo_job gamma-run '. + {context: ["jobs"]}'
  rm "$HC_JOB_RESULTS/price.json"
  job="$(fixed_check gamma-run "$HC_JOBS/gamma-run.json")"
  [ "$(job_first_message gamma-run "$job")" = "Today is $TODAY. Your result file is $HC_RESULTS/gamma-run.json. Do your run." ]
  echo both > "$STUB/mode-beta-run"
  rm -f "$HC_JOBS/gamma-run.json" "$HC_WORKSPACE/jobs/gamma-run.json"
  jobs_tick
  wait_runs
  [[ "$(cat "$STUB/beta-run.argv")" == *$'--max-turns\n9'* ]]
}

@test "a chat's job has the same first line, then its notify condition and its task as before" {
  runner_setup
  chat_job price
  job="$(job_check price "$HC_JOBS/price.json" "$TODAY" 0)"
  msg="$(job_first_message price "$job")"
  [ "$(head -n 1 <<<"$msg")" = "Today is $TODAY. Your result file is $HC_JOB_RESULTS/price.json. Do your run. Set notify to true only when this holds: below 300" ]
  [[ "$msg" == *$'\n\nThe task:\n\nFind a kettle.' ]]
}

@test "the repo file's timeout stops its run" {
  runner_setup
  repo_job alpha-run '. + {timeout: 1}'
  echo hang > "$STUB/mode"
  started=$SECONDS
  jobs_tick
  wait_runs
  (( SECONDS - started < 10 ))
  [ "$(state alpha-run .status)" = timeout ]
  grep -qx 'outcome run timeout alpha-run jobs' "$CALLS"
}

@test "two repo runs that end together each check their own result" {
  runner_setup
  echo together > "$STUB/mode"
  repo_job alpha-run
  repo_job beta-run
  jobs_tick
  [ "$(jobs_running | wc -l | tr -d ' ')" -eq 2 ]
  wait_runs
  [ "$(state alpha-run .status)" = ok ]
  [ "$(state beta-run .status)" = ok ]
  [ "$(state alpha-run .finding)" = "Found by alpha-run" ]
  [ "$(state beta-run .finding)" = "Found by beta-run" ]
  grep -qx 'outcome run ok alpha-run jobs' "$CALLS"
  grep -qx 'outcome run ok beta-run jobs' "$CALLS"
  [ -z "$(ls "$HC_STATE" | grep -E '^result[.-]')" ]
}

@test "a handover run is ok only with its result and today's handover file" {
  runner_setup
  repo_job beta-run '. + {context: ["handover"]}'
  local mode want
  for mode in write handover both; do
    echo "$mode" > "$STUB/mode"
    rm -f "$HC_HANDOVER/$TODAY.md" "$HC_RESULTS/beta-run.json"
    jq -n '{status: "idle", last_run: 1}' > "$HC_JOB_STATE/beta-run.json"
    : > "$CALLS"
    jobs_tick
    wait_runs
    want=failed; [[ "$mode" == both ]] && want=ok
    [ "$(state beta-run .status)" = "$want" ]
    grep -qx "outcome run $want beta-run jobs" "$CALLS"
  done
  # A handover file from before the run does not count.
  echo write > "$STUB/mode"
  printf '# old\n' > "$HC_HANDOVER/$TODAY.md"; touch -t 202001010000 "$HC_HANDOVER/$TODAY.md"
  jq -n '{status: "idle", last_run: 1}' > "$HC_JOB_STATE/beta-run.json"
  jobs_tick
  wait_runs
  [ "$(state beta-run .status)" = failed ]
}

@test "the outcome is morning for the file morning_job names and run otherwise, with by" {
  runner_setup
  set_options '{"morning_job": "beta-run", "morning_chat": false}'
  repo_job alpha-run
  repo_job beta-run
  jobs_tick
  wait_runs
  grep -qx 'outcome morning ok beta-run jobs' "$CALLS"
  grep -qx 'outcome run ok alpha-run jobs' "$CALLS"
  : > "$CALLS"
  handle_command 'morning'
  wait_runs
  handle_command '"run alpha-run"'
  wait_runs
  grep -qx 'outcome morning ok beta-run command' "$CALLS"
  grep -qx 'outcome run ok alpha-run command' "$CALLS"
}

@test "after clear_chat the runner leaves a request and exits; the loop clears within one pass and then raises" {
  runner_setup
  set_options '{"morning_job": "beta-run"}'
  repo_job beta-run '. + {after: ["clear_chat"]}'
  jobs_tick
  wait_runs
  [ "$(state beta-run .status)" = ok ]
  [ ! -s "$CALLS" ]
  req="$HC_STATE/after/beta-run"
  [ -f "$req" ]
  [ "$(jq -r .outcome "$req")" = ok ]
  [ "$(jq -r .by "$req")" = jobs ]
  case "$(uname)" in
    Darwin) [ "$(stat -f %Lp "$req")" = 600 ]; [ "$(stat -f %Lp "${req%/*}")" = 700 ] ;;
    *) [ "$(stat -c %a "$req")" = 600 ]; [ "$(stat -c %a "${req%/*}")" = 700 ] ;;
  esac
  jobs_after_run
  [ "$(cat "$CALLS")" = "clear $(opening_prompt ok)"$'\n'"outcome morning ok beta-run jobs" ]
  [ ! -e "$req" ]
  # Nothing left: the next pass does nothing.
  jobs_after_run
  [ "$(wc -l < "$CALLS" | tr -d ' ')" -eq 2 ]
}

@test "with morning_chat false the request raises without clearing; a request that is not one is dropped" {
  runner_setup
  set_options '{"morning_chat": false}'
  mkdir -p "$HC_STATE/after"
  jq -nc '{command: "morning", outcome: "timeout", agent: "beta-run", by: "command"}' > "$HC_STATE/after/beta-run"
  printf 'not json' > "$HC_STATE/after/alpha-run"
  jq -nc '{command: "morning", outcome: "ok; rm", agent: "x", by: "jobs"}' > "$HC_STATE/after/gamma-run"
  jobs_after_run
  [ "$(cat "$CALLS")" = "outcome morning timeout beta-run command" ]
  [ -z "$(ls -A "$HC_STATE/after")" ]
}

@test "the loop checks for a request on every pass and after each command" {
  grep -A 12 '^while true; do' "$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/addon-run" | grep -q 'jobs_after_run'
}

@test "a sync waiting for the running jobs ends while a clearing request waits" {
  runner_setup
  sync_workspace() { echo sync >> "$CALLS"; }
  install_managed_settings() { :; }
  fixed_place() { :; }
  restart_chat() { echo restart >> "$CALLS"; }
  set_options '{"morning_job": "beta-run"}'
  repo_job beta-run '. + {after: ["clear_chat"]}'
  echo slow > "$STUB/mode"
  jobs_tick
  [ "$(jobs_running)" = beta-run ]
  started=$SECONDS
  handle_command 'sync'
  (( SECONDS - started < 20 ))
  [ -f "$HC_STATE/after/beta-run" ]
  grep -qx sync "$CALLS"
  ! grep -q '^outcome morning' "$CALLS"
  jobs_after_run
  [ "$(tail -n 1 "$CALLS")" = "outcome morning ok beta-run jobs" ]
}

@test "a request left over a restart is kept by jobs_startup and carried out at the start" {
  runner_setup
  mkdir -p "$HC_STATE/after"
  jq -nc '{command: "morning", outcome: "failed", agent: "beta-run", by: "jobs"}' > "$HC_STATE/after/beta-run"
  mkdir -p "$HC_STATE/fixed.lock.d"
  touch "$HC_STATE/job-fixed.ab12" "$HC_STATE/fixed-beta-run.started" "$HC_STATE/result-beta-run.in" "$HC_JOB_STATE/beta-run.limit"
  jobs_startup
  [ -f "$HC_STATE/after/beta-run" ]
  [ ! -e "$HC_STATE/fixed.lock.d" ]
  [ ! -e "$HC_STATE/job-fixed.ab12" ]
  [ ! -e "$HC_STATE/fixed-beta-run.started" ]
  [ ! -e "$HC_STATE/result-beta-run.in" ]
  [ ! -e "$HC_JOB_STATE/beta-run.limit" ]
  jobs_after_run
  [ "$(cat "$CALLS")" = "clear $(opening_prompt failed)"$'\n'"outcome morning failed beta-run jobs" ]
  # In addon-run: after jobs_startup, once the chat has started, and before the loop.
  f="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/addon-run"
  [ "$(grep -n '^jobs_startup' "$f" | cut -d: -f1)" -lt "$(grep -n '^jobs_after_run' "$f" | cut -d: -f1)" ]
  [ "$(grep -n '^start_chat' "$f" | cut -d: -f1)" -lt "$(grep -n '^jobs_after_run' "$f" | cut -d: -f1)" ]
  [ "$(grep -n '^jobs_after_run' "$f" | cut -d: -f1)" -lt "$(grep -n '^while true' "$f" | cut -d: -f1)" ]
}

@test "morning with morning_job unset raises not_configured and does nothing else" {
  runner_setup
  repo_job beta-run
  handle_command 'morning'
  wait_runs
  [ "$(cat "$CALLS")" = "outcome morning not_configured  command" ]
  [ ! -e "$STUB/starts" ]
  [ ! -e "$HC_JOB_STATE/beta-run.json" ]
  # A name that is not a file from the repo is not configured either.
  set_options '{"morning_job": "delta-run"}'
  : > "$CALLS"
  handle_command 'morning'
  [ "$(cat "$CALLS")" = "outcome morning not_configured  command" ]
}

@test "a command starts the run and returns at once, sets last_run, and runs a file that is off" {
  runner_setup
  repo_job alpha-run '.enabled = false'
  echo slow > "$STUB/mode"
  before="$(date +%s)"
  started=$SECONDS
  handle_command '"run alpha-run"'
  (( SECONDS - started < 2 ))
  [ "$(jobs_running)" = alpha-run ]
  (( $(state alpha-run .last_run) >= before ))
  wait_runs
  [ "$(state alpha-run .status)" = ok ]
  grep -qx 'outcome run ok alpha-run command' "$CALLS"
}

@test "a command for a running job raises running, and for an invalid file failed" {
  runner_setup
  repo_job alpha-run
  echo hang > "$STUB/mode"
  handle_command '"run alpha-run"'
  [ "$(jobs_running)" = alpha-run ]
  handle_command '"run alpha-run"'
  grep -qx 'outcome run running alpha-run command' "$CALLS"
  for _ in $(seq 50); do [ -s "$STUB/starts" ] && break; sleep 0.1; done
  sleep 0.5
  [ "$(grep -c . "$STUB/starts")" -eq 1 ]
  jobs_stop
  wait_runs
  repo_job beta-run
  jq -c '.agent = "alpha-run"' "$HC_WORKSPACE/jobs/beta-run.json" > "$HC_JOBS/beta-run.json"
  : > "$CALLS"
  handle_command '"run beta-run"'
  [ "$(cat "$CALLS")" = "outcome run failed beta-run command" ]
  [ "$(grep -c . "$STUB/starts")" -eq 1 ]
  # A placed copy that is gone is failed too.
  rm "$HC_JOBS/beta-run.json"
  : > "$CALLS"
  handle_command '"run beta-run"'
  [ "$(cat "$CALLS")" = "outcome run failed beta-run command" ]
}

@test "run of an agent with no job file is the run command, with the job runs' first line" {
  runner_setup
  touch "$HC_WORKSPACE/.claude/agents/gamma-run.md"
  handle_command '"run gamma-run"'
  grep -qx 'outcome run ok gamma-run command' "$CALLS"
  [ -z "$(ls "$HC_JOB_STATE"/*.json 2>/dev/null)" ]
  [ "$(cat "$STUB/gamma-run.stdin")" = "Today is $TODAY. Your result file is $HC_RESULTS/gamma-run.json. Do your run." ]
}

@test "repo runs start with every place taken by chat jobs, and without a broker" {
  runner_setup
  set_options '{"jobs_parallel": 1}'
  echo hang > "$STUB/mode"
  chat_job price
  jobs_tick
  [ "$(jobs_running)" = price ]
  repo_job alpha-run
  chat_job other
  jobs_tick
  [ "$(jobs_running | sort | tr '\n' ' ')" = "alpha-run price " ]
  [ ! -e "$HC_JOB_STATE/other.pid" ]
  # Without a broker: the chat's jobs wait, the repo file runs.
  jobs_stop; wait_runs
  jobs_can_run() { return 1; }
  rm -f "$HC_JOB_STATE"/*.json "$HC_JOB_STATE"/*.pid "$HC_JOBS/price.json" "$HC_JOBS/alpha-run.json" \
        "$HC_WORKSPACE/jobs/alpha-run.json"
  repo_job beta-run
  jobs_tick
  [ "$(jobs_running)" = beta-run ]
  [ ! -e "$HC_JOB_STATE/other.pid" ]
}

@test "a repo file run by automation is not started by the tick" {
  runner_setup
  repo_job alpha-run '.run_by = "automation"'
  jobs_tick
  wait_runs
  [ ! -e "$STUB/starts" ]
  [ "$(state alpha-run .status)" = idle ]
}

@test "with fixed_log in the policy a repo run carries HA_CLAUDE_JOB" {
  runner_setup
  printf '{"jobs":{"fixed_log":true}}' > "$HC_WORKSPACE/.claude/policy.json"
  repo_job alpha-run
  jobs_tick
  wait_runs
  grep -qx 'HA_CLAUDE_JOB=alpha-run' "$STUB/alpha-run.env"
}

@test "sync's limit is the largest timeout of the running jobs plus 90 seconds" {
  runner_setup
  set_options '{"job_timeout": 200, "run_timeout": 300}'
  [ "$(jobs_wait_cap)" = 0 ]
  echo hang > "$STUB/mode"
  repo_job alpha-run '. + {timeout: 400}'
  repo_job beta-run
  jobs_tick
  [ "$(jobs_wait_cap)" = 490 ]
  jobs_stop; wait_runs
  rm -f "$HC_JOB_STATE"/*.pid
  jq -n '{status: "idle"}' | tee "$HC_JOB_STATE/alpha-run.json" > "$HC_JOB_STATE/beta-run.json"
  echo hang > "$STUB/mode-job-web"
  chat_job price
  rm "$HC_JOBS/alpha-run.json" "$HC_WORKSPACE/jobs/alpha-run.json"
  jobs_tick
  [ "$(jobs_running | sort | tr '\n' ' ')" = "beta-run price " ]
  [ "$(jobs_wait_cap)" = 390 ]
}

@test "a run that fails, writes nothing or errs is failed, and keeps no stale finding" {
  runner_setup
  repo_job alpha-run
  jobs_tick; wait_runs
  [ "$(state alpha-run .finding)" = "Found by alpha-run" ]
  local mode
  for mode in nothing error; do
    echo "$mode" > "$STUB/mode"
    jq '.last_run = 1' "$HC_JOB_STATE/alpha-run.json" > "$HC_JOB_STATE/x" && mv "$HC_JOB_STATE/x" "$HC_JOB_STATE/alpha-run.json"
    jobs_tick; wait_runs
    [ "$(state alpha-run .status)" = failed ]
    [ "$(state alpha-run .finding)" = "Found by alpha-run" ]
    # A result from before the run is removed before it starts.
    [[ "$mode" != nothing || ! -e "$HC_RESULTS/alpha-run.json" ]]
  done
}

@test "publish_result keeps a body only for a file from the repo" {
  runner_setup
  unset SUPERVISOR_TOKEN
  repo_job alpha-run
  MARKER="$HC_STATE/m"; : > "$MARKER"; touch -t 202001010000 "$MARKER"
  printf '{"verdict":"v","text":"t"}' > "$HC_RESULTS/alpha-run.json"
  printf '{"verdict":"v","text":"t"}' > "$HC_RESULTS/gamma-run.json"
  publish_result alpha-run "$MARKER"
  publish_result gamma-run "$MARKER"
  [ -f "$HC_STATE/fixed-alpha-run.body" ]
  [ ! -e "$HC_STATE/fixed-gamma-run.body" ]
  [ -z "$(ls "$HC_STATE" | grep -E '^result[.-]')" ]
}

@test "nothing in the add-on names an agent or a job" {
  run grep -rn -e 'morning-briefing' -e 'house-check' -e 'firefly-sorter' -e 'HC_MORNING_AGENT' -e 'run_morning' \
    "$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/lib/ha-claude" "$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin"
  [ "$status" -eq 1 ]
}

@test "morning_job is an optional string with no default" {
  f="$BATS_TEST_DIRNAME/../ha-claude/config.yaml"
  grep -qx '  morning_job: str?' "$f"
  [ "$(grep -c 'morning_job' "$f")" -eq 1 ]
}

@test "a request whose clearing fails still raises its outcome, and says so" {
  runner_setup
  clear_chat() { return 1; }
  mkdir -p "$HC_STATE/after"
  jq -nc '{command: "morning", outcome: "ok", agent: "beta-run", by: "jobs"}' > "$HC_STATE/after/beta-run"
  run jobs_after_run
  [[ "$output" == *"no chat session"* ]]
  [ "$(cat "$CALLS")" = "outcome morning ok beta-run jobs" ]
  [ ! -e "$HC_STATE/after/beta-run" ]
}

# at_time <HH:MM> - the tick's clock: date +%s gives that time today; any
# other date call is the real one. For ticks that start nothing.
at_time() {
  FAKE_NOW="$(date -d "$TODAY $1:00" +%s 2>/dev/null || date -j -f '%Y-%m-%d %H:%M:%S' "$TODAY $1:00" +%s)"
  date() { if [[ "$*" == +%s ]]; then echo "$FAKE_NOW"; else command date "$@"; fi; }
}

# window_job <name> [jq-update] - a file from the repo run by the jobs at
# 07:00 with a limit of 600 seconds: its window ends at 07:25.
window_job() {
  repo_job "$1" ". + {schedule: {time: \"07:00\"}, timeout: 600} | ${2:-.}"
}

@test "the tick raises missed once when a window ends unstarted, and starts nothing" {
  runner_setup
  window_job alpha-run
  at_time 07:30
  jobs_tick
  [ "$(cat "$CALLS")" = "outcome run missed alpha-run jobs" ]
  [ "$(state alpha-run .missed)" = "$(command date -d "$TODAY 07:00:00" +%s 2>/dev/null || command date -j -f '%Y-%m-%d %H:%M:%S' "$TODAY 07:00:00" +%s)" ]
  at_time 07:31
  jobs_tick
  [ "$(grep -c . "$CALLS")" -eq 1 ]
  [ ! -e "$STUB/starts" ]
  # Its next run is tomorrow's, not the time it missed.
  (( $(state alpha-run .next_run) > FAKE_NOW ))
}

@test "missed is morning for the file morning_job names" {
  runner_setup
  set_options '{"morning_job": "beta-run"}'
  window_job beta-run '. + {after: ["clear_chat"]}'
  at_time 07:30
  jobs_tick
  [ "$(cat "$CALLS")" = "outcome morning missed beta-run jobs" ]
  [ ! -e "$HC_STATE/after/beta-run" ]
}

@test "no missed when switched off, at a later first tick, or after a run a restart failed" {
  runner_setup
  window_job alpha-run
  jq -c '.enabled = false' "$HC_WORKSPACE/jobs/alpha-run.json" > "$HC_JOBS/alpha-run.json"
  at_time 07:30
  jobs_tick
  # Switched on later: the window has ended at an earlier tick.
  cp "$HC_WORKSPACE/jobs/alpha-run.json" "$HC_JOBS/alpha-run.json"
  at_time 07:45
  jobs_tick
  [ ! -s "$CALLS" ]
  # A run that started at 07:00 and was failed by a restart.
  rm -f "$HC_WORKSPACE/jobs/alpha-run.json" "$HC_JOBS/alpha-run.json"
  window_job beta-run
  jq -n --argjson l "$(command date -d "$TODAY 07:00:00" +%s 2>/dev/null || command date -j -f '%Y-%m-%d %H:%M:%S' "$TODAY 07:00:00" +%s)" \
    '{status: "running", last_run: $l}' > "$HC_JOB_STATE/beta-run.json"
  jobs_startup
  [ "$(state beta-run .status)" = failed ]
  at_time 07:30
  jobs_tick
  [ ! -s "$CALLS" ]
  [ ! -e "$STUB/starts" ]
}

@test "a repo file off the quarter hour or with every_hours is invalid at the tick and not started" {
  runner_setup
  repo_job alpha-run '.schedule = {time: "23:50"}'
  repo_job beta-run '.schedule = {every_hours: 4}'
  jobs_tick
  wait_runs
  [ "$(state alpha-run .status)" = invalid ]
  [ "$(state alpha-run .error)" = schedule ]
  [ "$(state beta-run .status)" = invalid ]
  [ "$(state beta-run .error)" = schedule ]
  [ ! -e "$STUB/starts" ]
  [ ! -s "$CALLS" ]
}
