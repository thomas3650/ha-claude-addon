load helpers

# A fixed run's start, end and finding are its job's state. The agents are
# made up: alpha-run (the run command) and beta-run (the morning agent).

setup_file() {
  export TZ=Europe/Copenhagen
}

fixed_run_setup() {
  load_lib options env layout morning result run jobs fixed commands
  export HC_LIMIT_BIN="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/ha-claude-limit"
  ensure_layout
  mkdir -p "$HC_STATE" "$HC_WORKSPACE/jobs" "$HC_WORKSPACE/.claude/agents" "$HC_RESULTS"
  as_claude() { "$@"; }
  CHANGES="$BATS_TEST_TMPDIR/changes"; : > "$CHANGES"
  jobs_on_change() { echo "$1" >> "$CHANGES"; }
  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  raise_outcome() { echo "outcome $*" >> "$CALLS"; }
  clear_chat() { echo "clear" >> "$CALLS"; }
  export HC_MORNING_AGENT=beta-run
  local n
  for n in alpha-run beta-run; do
    jq -nc --arg n "$n" '{agent: $n, run_by: "automation", schedule: {time: "06:30"}, task: "Test.", enabled: true}' \
      > "$HC_WORKSPACE/jobs/$n.json"
    touch "$HC_WORKSPACE/.claude/agents/$n.md"
  done
}

# state <name> <jq> - a field of the job's state.
state() {
  jq -r "$2" "$HC_JOB_STATE/$1.json"
}

# stub_runs <outcome> [verdict] - run_agent and run_morning as stand-ins: they
# note the state the job had while running, keep a result body as the real
# publish does when asked to, and set the outcome.
stub_runs() {
  STUB_OUTCOME="$1"; STUB_VERDICT="${2:-}"
  stand_in() {
    local var="$1" agent="$2"
    echo "$agent $(state "$agent" .status 2>/dev/null)" >> "$CALLS"
    if [[ -n "$STUB_VERDICT" ]]; then
      sleep 1
      ( umask 077; jq -nc --arg v "$STUB_VERDICT" '{agent: "x", count: 1, verdict: $v, text: "line one\nline two", time: "t"}' \
          > "$HC_STATE/fixed-$agent.body" )
    fi
    printf -v "$var" '%s' "$STUB_OUTCOME"
  }
  run_agent() { stand_in "$1" "$2"; }
  run_morning() { stand_in "$1" "$HC_MORNING_AGENT"; }
}

@test "a fixed run's state is running during it and ok after, with the finding and the text" {
  fixed_run_setup; stub_runs ok "2 things"
  handle_command '"run alpha-run"'
  [ "$(sed -n 1p "$CALLS")" = "alpha-run running" ]
  [ "$(state alpha-run .status)" = ok ]
  [ "$(state alpha-run .error)" = null ]
  [ "$(state alpha-run .finding)" = "2 things" ]
  [ "$(state alpha-run .text)" = $'line one\nline two' ]
  [[ "$(state alpha-run .last_run)" =~ ^[0-9]+$ ]]
  [[ "$(state alpha-run .last_end)" =~ ^[0-9]+$ ]]
  [ "$(state alpha-run .last_end)" -ge "$(state alpha-run .last_run)" ]
  [[ "$(state alpha-run .next_run)" =~ ^[0-9]+$ ]]
  (( $(state alpha-run .next_run) > $(state alpha-run .last_run) ))
  grep -qx 'outcome run ok alpha-run' "$CALLS"
  grep -qx alpha-run "$CHANGES"
}

@test "failed, timeout and not_configured end the state, and keep the last finding" {
  fixed_run_setup; stub_runs ok "first"
  handle_command '"run alpha-run"'
  [ "$(state alpha-run .finding)" = first ]
  local o want err
  for o in failed timeout not_configured; do
    stub_runs "$o"
    rm -f "$HC_STATE/fixed-alpha-run.body"
    handle_command '"run alpha-run"'
    want="$o"; err=null
    [[ "$o" == not_configured ]] && { want=failed; err=not_configured; }
    [ "$(state alpha-run .status)" = "$want" ]
    [ "$(state alpha-run .error)" = "$err" ]
    [ "$(state alpha-run .finding)" = first ]
    [ "$(state alpha-run .text)" = $'line one\nline two' ]
    [[ "$(state alpha-run .next_run)" =~ ^[0-9]+$ ]]
  done
}

@test "a body left from an earlier run is not this run's finding" {
  fixed_run_setup; stub_runs ok "old"
  handle_command '"run alpha-run"'
  [ "$(state alpha-run .finding)" = old ]
  stub_runs ok
  handle_command '"run alpha-run"'
  [ "$(state alpha-run .status)" = ok ]
  [ "$(state alpha-run .finding)" = old ]
  # Not even a body that is still there, older than the run's start.
  jq -nc '{agent: "x", count: 1, verdict: "stale", text: "s", time: "t"}' > "$HC_STATE/fixed-alpha-run.body"
  touch -t 202001010000 "$HC_STATE/fixed-alpha-run.body"
  fixed_run_begin alpha-run
  fixed_run_end alpha-run ok
  [ "$(state alpha-run .finding)" = old ]
}

@test "the morning command is the morning agent's fixed run" {
  fixed_run_setup; stub_runs ok "good morning"
  set_options '{"morning_chat": false}'
  handle_command '"morning"'
  [ "$(sed -n 1p "$CALLS")" = "beta-run running" ]
  [ "$(state beta-run .status)" = ok ]
  [ "$(state beta-run .finding)" = "good morning" ]
  [ ! -e "$HC_JOB_STATE/alpha-run.json" ]
  grep -qx 'outcome morning ok' "$CALLS"
}

@test "a run of an agent with no fixed file changes no job state" {
  fixed_run_setup; stub_runs ok "x"
  touch "$HC_WORKSPACE/.claude/agents/gamma-run.md"
  handle_command '"run gamma-run"'
  [ -z "$(ls "$HC_JOB_STATE" 2>/dev/null)" ]
  [ ! -s "$CHANGES" ]
  grep -qx 'outcome run ok gamma-run' "$CALLS"
}

@test "the broker down does not stop the run or change its outcome, and the state is written" {
  fixed_run_setup; stub_runs ok "still here"
  jobs_on_change() { return 1; }
  handle_command '"run alpha-run"'
  grep -qx 'outcome run ok alpha-run' "$CALLS"
  [ "$(state alpha-run .status)" = ok ]
  [ "$(state alpha-run .finding)" = "still here" ]
}

@test "a state that cannot be written does not stop the run" {
  fixed_run_setup; stub_runs ok "x"
  _job_update() { return 1; }
  handle_command '"run alpha-run"'
  grep -qx 'alpha-run ' "$CALLS"
  grep -qx 'outcome run ok alpha-run' "$CALLS"
}

@test "a fixed run is not counted as a running job" {
  fixed_run_setup; stub_runs ok
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
  MARKER="$HC_STATE/run.started"; : > "$MARKER"; touch -t 202001010000 "$MARKER"
  printf '%s' '{"count":1,"verdict":"v","text":"t"}' > "$HC_RESULTS/alpha-run.json"
  publish_result alpha-run "$MARKER"
  [ ! -e "$HC_STATE/result.body" ]
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

@test "a real run with fixed_log in the policy carries HA_CLAUDE_JOB, and ends with the finding" {
  fixed_run_setup; real_claude
  printf '{"jobs":{"fixed_log":true}}' > "$HC_WORKSPACE/.claude/policy.json"
  handle_command '"run alpha-run"'
  grep -qx 'HA_CLAUDE_JOB=alpha-run' "$STUB/env"
  [ "$(state alpha-run .status)" = ok ]
  [ "$(state alpha-run .finding)" = "2 ting" ]
  [ "$(state alpha-run .text)" = $'one\ntwo' ]
}

@test "without fixed_log in the policy, or without a policy, the run has no HA_CLAUDE_JOB" {
  fixed_run_setup; real_claude
  handle_command '"run alpha-run"'
  ! grep -q '^HA_CLAUDE_JOB=' "$STUB/env"
  printf '{"jobs":{"fixed_log":false}}' > "$HC_WORKSPACE/.claude/policy.json"
  handle_command '"run alpha-run"'
  ! grep -q '^HA_CLAUDE_JOB=' "$STUB/env"
  printf 'not json' > "$HC_WORKSPACE/.claude/policy.json"
  handle_command '"run alpha-run"'
  ! grep -q '^HA_CLAUDE_JOB=' "$STUB/env"
  printf '{"jobs":{"fixed_log":true}}' > "$HC_WORKSPACE/.claude/policy.json"
  touch "$HC_WORKSPACE/.claude/agents/gamma-run.md"
  run fixed_marked gamma-run
  [ "$status" -eq 1 ]
}
