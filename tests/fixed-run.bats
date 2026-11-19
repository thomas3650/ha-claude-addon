load helpers

# A fixed run's start, end and finding are its job's state; the run command
# sends a fixed name to the job runner. The agents are made up: alpha-run
# and beta-run. The runner itself is in runner.bats.

setup_file() {
  export TZ=Europe/Copenhagen
}

fixed_run_setup() {
  load_lib options env layout morning result run jobs fixed commands
  export HC_LIMIT_BIN="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/ha-claude-limit"
  ensure_layout
  mkdir -p "$HC_STATE" "$HC_WORKSPACE/jobs" "$HC_WORKSPACE/.claude/agents" "$HC_RESULTS" "$HC_JOBS"
  as_claude() { "$@"; }
  CHANGES="$BATS_TEST_TMPDIR/changes"; : > "$CHANGES"
  jobs_on_change() { echo "$1" >> "$CHANGES"; }
  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  raise_outcome() { echo "outcome $*" >> "$CALLS"; }
  clear_chat() { echo "clear" >> "$CALLS"; }
  local n
  for n in alpha-run beta-run; do
    jq -nc --arg n "$n" '{agent: $n, run_by: "automation", schedule: {time: "06:30"}, task: "Test.", enabled: true}' \
      > "$HC_WORKSPACE/jobs/$n.json"
    cp "$HC_WORKSPACE/jobs/$n.json" "$HC_JOBS/$n.json"
    touch "$HC_WORKSPACE/.claude/agents/$n.md"
  done
}

# state <name> <jq> - a field of the job's state.
state() {
  jq -r "$2" "$HC_JOB_STATE/$1.json"
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

@test "a run of an agent with no fixed file changes no job state" {
  fixed_run_setup
  run_agent() { printf -v "$1" '%s' ok; }
  touch "$HC_WORKSPACE/.claude/agents/gamma-run.md"
  handle_command '"run gamma-run"'
  [ -z "$(ls "$HC_JOB_STATE" 2>/dev/null)" ]
  [ ! -s "$CHANGES" ]
  grep -qx 'outcome run ok gamma-run command' "$CALLS"
}

# running <name> - the state a running fixed job has, without a runner.
running() {
  _job_update "$1" '.status = "running" | .error = null | .last_run = $now' --argjson now "$(date +%s)"
}

@test "a fixed job whose state says running, without a runner, is not counted as a running job" {
  fixed_run_setup
  running alpha-run
  [ "$(state alpha-run .status)" = running ]
  [ -z "$(jobs_running)" ]
}

@test "after a restart a fixed job left running is failed" {
  fixed_run_setup
  running alpha-run
  [ "$(state alpha-run .status)" = running ]
  jobs_startup
  [ "$(state alpha-run .status)" = failed ]
  [ "$(state alpha-run .error)" = stopped ]
}

@test "publish_result keeps the body for root alone, with no Supervisor token" {
  fixed_run_setup
  unset SUPERVISOR_TOKEN
  MARKER="$HC_STATE/run-alpha-run.started"; : > "$MARKER"; touch -t 202001010000 "$MARKER"
  printf '%s' '{"count":1,"verdict":"v","text":"t"}' > "$HC_RESULTS/alpha-run.json"
  publish_result alpha-run "$MARKER"
  [ ! -e "$HC_STATE/result-alpha-run.body" ]
  [ "$(jq -r .verdict "$HC_STATE/fixed-alpha-run.body")" = v ]
  [ "$(jq -r .text "$HC_STATE/fixed-alpha-run.body")" = t ]
  case "$(uname)" in
    Darwin) [ "$(stat -f %Lp "$HC_STATE/fixed-alpha-run.body")" = 600 ] ;;
    *) [ "$(stat -c %a "$HC_STATE/fixed-alpha-run.body")" = 600 ] ;;
  esac
}

# real_claude - a stand-in for Claude Code that writes the result file and
# keeps its environment, for the real run_agent.
real_claude() {
  STUB="$BATS_TEST_TMPDIR/stub"; mkdir -p "$STUB"
  cat > "$STUB/claude" <<EOT
#!/usr/bin/env bash
env > "$STUB/env"
printf '%s' '{"count":2,"verdict":"2 ting","text":"one\ntwo"}' > "$HC_RESULTS/alpha-run.json"
EOT
  chmod +x "$STUB/claude"
  export HC_CLAUDE_BIN="$STUB/claude"
  unset SUPERVISOR_TOKEN
}

teardown() {
  declare -F jobs_stop >/dev/null && jobs_stop
  return 0
}

@test "the broker down does not stop a command's run or change its outcome, and the state is written" {
  fixed_run_setup; real_claude
  jobs_on_change() { return 1; }
  handle_command '"run alpha-run"'
  wait_runs
  grep -qx 'outcome run ok alpha-run command' "$CALLS"
  [ "$(state alpha-run .status)" = ok ]
  [ "$(state alpha-run .finding)" = "2 ting" ]
}

@test "a state that cannot be written does not stop a command's run" {
  fixed_run_setup; real_claude
  _job_update() { return 1; }
  handle_command '"run alpha-run"'
  wait_runs
  [ -f "$STUB/env" ]
  grep -qx 'outcome run ok alpha-run command' "$CALLS"
}

@test "a real run with fixed_log in the policy carries HA_CLAUDE_JOB, and ends with the finding" {
  fixed_run_setup; real_claude
  printf '{"jobs":{"fixed_log":true}}' > "$HC_WORKSPACE/.claude/policy.json"
  handle_command '"run alpha-run"'
  wait_runs
  grep -qx 'HA_CLAUDE_JOB=alpha-run' "$STUB/env"
  [ "$(state alpha-run .status)" = ok ]
  [ "$(state alpha-run .finding)" = "2 ting" ]
  [ "$(state alpha-run .text)" = $'one\ntwo' ]
}

@test "without fixed_log in the policy, or without a policy, the run has no HA_CLAUDE_JOB" {
  fixed_run_setup; real_claude
  handle_command '"run alpha-run"'; wait_runs
  ! grep -q '^HA_CLAUDE_JOB=' "$STUB/env"
  printf '{"jobs":{"fixed_log":false}}' > "$HC_WORKSPACE/.claude/policy.json"
  handle_command '"run alpha-run"'; wait_runs
  ! grep -q '^HA_CLAUDE_JOB=' "$STUB/env"
  printf 'not json' > "$HC_WORKSPACE/.claude/policy.json"
  handle_command '"run alpha-run"'; wait_runs
  ! grep -q '^HA_CLAUDE_JOB=' "$STUB/env"
  printf '{"jobs":{"fixed_log":true}}' > "$HC_WORKSPACE/.claude/policy.json"
  touch "$HC_WORKSPACE/.claude/agents/gamma-run.md"
  run fixed_marked gamma-run
  [ "$status" -eq 1 ]
}
