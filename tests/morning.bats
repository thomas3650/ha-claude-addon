load helpers

# What morning.sh gives the runner: the Jobs line of a run's context, and the
# chat's opening after a run that clears the chat. The run itself, with the
# handover rule, is in runner.bats.

@test "the opening prompt is one line of fixed text for each outcome" {
  load_lib options env morning
  ok="$(opening_prompt ok)"
  failed="$(opening_prompt failed)"
  late="$(opening_prompt timeout)"
  [ "$(wc -l <<<"$ok")" -eq 1 ]
  [ "$(wc -l <<<"$failed")" -eq 1 ]
  [[ "$ok" == *"summary"* ]]
  [[ "$failed" == *"did not finish"* ]]
  [[ "$late" == *"took too long"* ]]
  [ "$ok" != "$failed" ]
}

@test "the opening after an ok run asks for the summary only" {
  load_lib options env morning
  ok="$(opening_prompt ok)"
  [[ "$ok" == *"summary"* ]]
  [[ "$ok" != *"proposal"* ]]
}

# A job with a result: its file, its state's last run, and its result's age.
job_with_result() {
  mkdir -p "$HC_JOBS" "$HC_JOB_RESULTS" "$HC_JOB_STATE"
  jq -n --argjson on "$2" '{agent: "job-web", task: "SECRET TASK", schedule: {every_hours: 4},
                            end: "2099-01-01", enabled: $on, created: "2026-11-18"}' > "$HC_JOBS/$1.json"
  printf '{"verdict":"SECRET","text":"t","notify":false}' > "$HC_JOB_RESULTS/$1.json"
  touch -t "$3" "$HC_JOB_RESULTS/$1.json"
  jq -n --argjson last "$4" '{status: "ok", last_run: $last}' > "$HC_JOB_STATE/$1.json"
}

@test "the Jobs line lists the jobs that have a result, old when it is from before the last run or the job is off" {
  load_lib options env result morning jobs
  export HC_LIMIT_BIN="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/ha-claude-limit"
  # The results are from 2026-01-01 00:00; the last runs before or after.
  job_with_result a-new true 202601010000 1000
  job_with_result b-old true 202601010000 1893456000
  job_with_result c-off false 202601010000 1000
  mkdir -p "$HC_JOBS"
  jq -n '{agent: "job-web", task: "t", schedule: {every_hours: 4}, end: "2099-01-01", enabled: true, created: "2026-11-18"}' > "$HC_JOBS/d-none.json"
  args="$(_morning_jobs)"
  [ "$args" = 'Jobs: a-new, b-old (old), c-off (old)' ]
  [[ "$args" != *"d-none"* ]]
  [[ "$args" != *"SECRET"* ]]
}

@test "without a job result there is no Jobs line" {
  load_lib options env result morning jobs
  [ -z "$(_morning_jobs)" ]
}

@test "the Jobs line leaves out fixed names" {
  load_lib options env layout result morning jobs fixed
  export HC_LIMIT_BIN="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/ha-claude-limit"
  ensure_layout
  job_with_result a-new true 202601010000 1000
  job_with_result alpha-run true 202601010000 1000
  mkdir -p "$HC_WORKSPACE/jobs"
  jq -nc '{agent: "alpha-run", run_by: "automation", schedule: {time: "06:30"}, task: "Test.", enabled: true}' > "$HC_WORKSPACE/jobs/alpha-run.json"
  args="$(_morning_jobs)"
  [ "$args" = 'Jobs: a-new' ]
  [[ "$args" != *"alpha-run"* ]]
}
