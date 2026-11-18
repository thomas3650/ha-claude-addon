load helpers

# A fixed run's start, end and finding are its job's state. The agents are
# made up: alpha-run and beta-run. The runner itself is in runner.bats.

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

# body <verdict-json> - a result body as publish_result keeps it.
body() {
  sleep 1
  ( umask 077; jq -nc --argjson v "$1" '{agent: "x", count: 1, verdict: $v, text: "line one\nline two", time: "t"}' \
      > "$HC_STATE/fixed-alpha-run.body" )
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

@test "fixed_run_begin and fixed_run_end: running during the run, ok after, with the finding and the text" {
  fixed_run_setup
  fixed_run_begin alpha-run
  [ "$(state alpha-run .status)" = running ]
  body '"2 things"'
  fixed_run_end alpha-run ok
  [ "$(state alpha-run .status)" = ok ]
  [ "$(state alpha-run .error)" = null ]
  [ "$(state alpha-run .finding)" = "2 things" ]
  [ "$(state alpha-run .text)" = $'line one\nline two' ]
  [[ "$(state alpha-run .last_run)" =~ ^[0-9]+$ ]]
  [ "$(state alpha-run .last_end)" -ge "$(state alpha-run .last_run)" ]
  (( $(state alpha-run .next_run) > $(state alpha-run .last_run) ))
  grep -qx alpha-run "$CHANGES"
}

@test "failed, timeout and not_configured end the state, and keep the last finding" {
  fixed_run_setup
  fixed_run_begin alpha-run; body '"first"'; fixed_run_end alpha-run ok
  [ "$(state alpha-run .finding)" = first ]
  local o want err
  for o in failed timeout not_configured; do
    fixed_run_begin alpha-run
    fixed_run_end alpha-run "$o"
    want="$o"; err=null
    [[ "$o" == not_configured ]] && { want=failed; err=not_configured; }
    [ "$(state alpha-run .status)" = "$want" ]
    [ "$(state alpha-run .error)" = "$err" ]
    [ "$(state alpha-run .finding)" = first ]
    [[ "$(state alpha-run .next_run)" =~ ^[0-9]+$ ]]
  done
}

@test "a body left from an earlier run is not this run's finding; a fresh one without a verdict empties it" {
  fixed_run_setup
  fixed_run_begin alpha-run; body '"old"'; fixed_run_end alpha-run ok
  [ "$(state alpha-run .finding)" = old ]
  jq -nc '{agent: "x", count: 1, verdict: "stale", text: "s", time: "t"}' > "$HC_STATE/fixed-alpha-run.body"
  touch -t 202001010000 "$HC_STATE/fixed-alpha-run.body"
  fixed_run_begin alpha-run
  fixed_run_end alpha-run ok
  [ "$(state alpha-run .finding)" = old ]
  fixed_run_begin alpha-run; body 5; fixed_run_end alpha-run ok
  [ "$(state alpha-run .status)" = ok ]
  [ "$(state alpha-run .finding)" = null ]
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

@test "a fixed run is not counted as a running job" {
  fixed_run_setup
  fixed_run_begin alpha-run
  [ "$(state alpha-run .status)" = running ]
  [ -z "$(jobs_running)" ]
}

@test "after a restart a fixed job left running is failed" {
  fixed_run_setup
  fixed_run_begin alpha-run
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
