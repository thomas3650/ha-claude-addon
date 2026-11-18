load helpers

# The job runner, with a stand-in for Claude Code as in run.bats. as_claude
# scrubs the environment, so the stand-in reads its mode from a file beside
# itself, and learns its job from HA_CLAUDE_JOB, which the runner passes on.
# What each start saw goes to files named after the job.
stub_claude() {
  STUB="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB" "$HC_WORKSPACE/.claude/agents"
  touch "$HC_WORKSPACE/.claude/agents/job-web.md" "$HC_WORKSPACE/.claude/agents/job-private.md" \
        "$HC_WORKSPACE/.claude/agents/job-all.md"
  TODAY="$(date +%F)"
  printf '%s\n%s\n' "$1" "$HC_JOB_RESULTS" > "$STUB/mode"
  cat > "$STUB/claude" <<'EOT'
#!/usr/bin/env bash
here="$(dirname "$0")"
{ read -r mode; read -r dir; } < "$here/mode"
job="$HA_CLAUDE_JOB"
printf '%s\n' "$@" > "$here/$job.argv"
cat > "$here/$job.stdin"
env > "$here/$job.env"
pwd -P > "$here/$job.cwd"
echo "$job" >> "$here/starts"
echo "stand-in output"
file="$dir/$job.json"
case "$mode" in
  write) printf '{"verdict":"Lowest 299 kr","text":"At the shop\\nsince Monday","notify":true}' > "$file" ;;
  quiet) printf '{"verdict":"Nothing","text":"","notify":false}' > "$file" ;;
  dirty) printf '{"verdict":"a\\u2028b\\nc","text":"x\\u0000y\\nz","notify":false}' > "$file" ;;
  extra) printf '{"verdict":"v","text":"t","notify":true,"more":1}' > "$file" ;;
  counted) printf '{"verdict":"v","text":"t","notify":true,"count":1}' > "$file" ;;
  bare) printf '{"verdict":"v","text":"t"}' > "$file" ;;
  string) printf '{"verdict":"v","text":"t","notify":"true"}' > "$file" ;;
  long) printf '{"verdict":"v","text":"%s","notify":false}' "$(printf 'x%.0s' {1..4001})" > "$file" ;;
  error) printf '{"verdict":"v","text":"t","notify":true}' > "$file"; exit 1 ;;
  nothing) ;;
  slow) sleep 3; printf '{"verdict":"v","text":"t","notify":false}' > "$file" ;;
  hang) exec sleep 30 ;;
esac
EOT
  chmod +x "$STUB/claude"
  export HC_CLAUDE_BIN="$STUB/claude"
  export HC_LIMIT_BIN="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/ha-claude-limit"
  CHANGES="$BATS_TEST_TMPDIR/changes"; : > "$CHANGES"
}

load_jobs() {
  load_lib options env layout morning result jobs
  ensure_layout
  stub_claude "${1:-write}"
  jobs_on_change() { echo "$1" >> "$CHANGES"; }
}

teardown() {
  declare -F jobs_stop >/dev/null && jobs_stop
  pkill -f "$BATS_TEST_TMPDIR/stub" 2>/dev/null || true
}

# days_after <YYYY-MM-DD> <n> - the date n days later.
days_after() {
  jq -rn --arg d "$1" --argjson n "$2" '$d | strptime("%Y-%m-%d") | mktime + $n * 86400 | strftime("%Y-%m-%d")'
}

# job_file <name> [jq-update] - a valid web job that is due now: every four
# hours and never run.
job_file() {
  jq -n --arg today "$TODAY" --arg end "$(days_after "$TODAY" 14)" \
    '{type: "web", task: "Find the lowest price of a kettle.", schedule: {every_hours: 4},
      end: $end, enabled: true, created: $today}' \
    | jq "${2:-.}" > "$HC_JOBS/$1.json"
}

state() { jq -r "$2" "$HC_JOB_STATE/$1.json"; }

@test "a due job runs as its type's agent, marked as unattended and as the job, with the task on standard input" {
  load_jobs write
  job_file price
  jobs_tick
  jobs_wait_idle
  args="$(cat "$STUB/price.argv")"
  [[ "$args" == *$'--agent\njob-web'* ]]
  [[ "$args" == *$'--max-turns\n60'* ]]
  [[ "$args" == *$'--permission-mode\ndefault'* ]]
  [[ "$args" == *"--no-session-persistence"* ]]
  [[ "$args" == *"-p"* ]]
  [[ "$args" != *"dangerously"* ]]
  [[ "$args" != *"kettle"* ]]
  grep -q "Find the lowest price of a kettle." "$STUB/price.stdin"
  grep -q "Today is $TODAY" "$STUB/price.stdin"
  grep -q "$HC_JOB_RESULTS/price.json" "$STUB/price.stdin"
  grep -qx "HA_CLAUDE_UNATTENDED=job-web" "$STUB/price.env"
  grep -qx "HA_CLAUDE_JOB=price" "$STUB/price.env"
  grep -qx "CLAUDE_CODE_DISABLE_AUTO_MEMORY=1" "$STUB/price.env"
  run grep "SUPERVISOR" "$STUB/price.env"
  [ "$status" -eq 1 ]
  [ "$(cat "$STUB/price.cwd")" = "$(cd "$HC_WORKSPACE" && pwd -P)" ]
}

@test "a good result is kept in the job's state, and the state says when it ran and runs next" {
  load_jobs write
  job_file price
  before="$(date +%s)"
  jobs_tick
  jobs_wait_idle
  [ "$(state price .status)" = ok ]
  [ "$(state price .finding)" = "Lowest 299 kr" ]
  [ "$(state price .text)" = $'At the shop\nsince Monday' ]
  [ "$(state price .notify)" = true ]
  [ "$(state price .notify_rose)" = true ]
  [ "$(state price .first_seen)" = "$TODAY" ]
  last="$(state price .last_run)"
  (( last >= before ))
  [ "$(state price .next_run)" = "$((last + 4 * 3600))" ]
  grep -qx price "$CHANGES"
  [ ! -e "$HC_JOB_STATE/price.pid" ] || [ "$(jobs_running)" = "" ]
}

@test "notify_rose is true only when notify goes from false to true" {
  load_jobs write
  job_file price
  jq '.last_run = 0 | .notify = true' <<<'{"first_seen":"'"$TODAY"'","status":"ok"}' > "$HC_JOB_STATE/price.json"
  jobs_tick
  jobs_wait_idle
  [ "$(state price .notify)" = true ]
  [ "$(state price .notify_rose)" = false ]
}

@test "the run's output goes to a file of its own that only root can read" {
  load_jobs write
  job_file price
  jobs_tick > "$BATS_TEST_TMPDIR/out" 2> "$BATS_TEST_TMPDIR/err"
  jobs_wait_idle
  run grep "stand-in output" "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/err"
  [ "$status" -eq 1 ]
  [ "$(cat "$HC_STATE/job-price.log")" = "stand-in output" ]
  [ "$(stat -c %a "$HC_STATE/job-price.log" 2>/dev/null || stat -f %Lp "$HC_STATE/job-price.log")" = "600" ]
}

@test "the type picks the agent" {
  load_jobs write
  job_file a '.type = "private"'
  job_file b '.type = "all"'
  jobs_tick
  jobs_wait_idle
  [[ "$(cat "$STUB/a.argv")" == *$'--agent\njob-private'* ]]
  [[ "$(cat "$STUB/b.argv")" == *$'--agent\njob-all'* ]]
  grep -qx "HA_CLAUDE_UNATTENDED=job-all" "$STUB/b.env"
}

@test "without the type's agent file the job fails and nothing runs" {
  load_jobs write
  rm "$HC_WORKSPACE/.claude/agents/job-web.md"
  job_file price
  jobs_tick
  jobs_wait_idle
  [ ! -e "$STUB/starts" ]
  [ "$(state price .status)" = failed ]
}

@test "at most jobs_parallel run at once; the rest wait for a later tick" {
  load_jobs hang
  for n in a b c d; do job_file "$n"; done
  jobs_tick
  [ "$(jobs_running | wc -l | tr -d ' ')" -eq 3 ]
  [ "$(state d .status)" != running ]
  [ "$(jobs_running)" = $'a\nb\nc' ]
  set_options '{"jobs_parallel":4}'
  jobs_tick
  [ "$(jobs_running | wc -l | tr -d ' ')" -eq 4 ]
}

@test "jobs_parallel comes from the options" {
  load_jobs hang
  set_options '{"jobs_parallel":1}'
  for n in a b; do job_file "$n"; done
  jobs_tick
  [ "$(jobs_running)" = a ]
}

@test "a running job is not started twice" {
  load_jobs hang
  job_file price
  jobs_tick
  jobs_tick
  sleep 1
  [ "$(grep -c price "$STUB/starts")" -eq 1 ]
}

@test "a run that takes longer than job_timeout ends as timeout" {
  load_jobs hang
  set_options '{"job_timeout":1}'
  job_file price
  started=$SECONDS
  jobs_tick
  jobs_wait_idle
  [ "$(state price .status)" = timeout ]
  (( SECONDS - started < 15 ))
}

@test "the turn limit comes from job_max_turns" {
  load_jobs write
  set_options '{"job_max_turns":7}'
  job_file price
  jobs_tick
  jobs_wait_idle
  [[ "$(cat "$STUB/price.argv")" == *$'--max-turns\n7'* ]]
}

@test "a result with another field, a notify that is not a bool, or a text too long is failed" {
  for mode in extra string long nothing error; do
    load_jobs "$mode"
    rm -f "$HC_JOB_STATE/price.json"
    job_file price
    jobs_tick
    jobs_wait_idle
    [ "$(state price .status)" = failed ]
    [ "$(state price .finding)" = null ]
  done
}

@test "a job's result may carry a count, and may leave notify out (one result for every run)" {
  load_jobs counted
  job_file price
  jobs_tick
  jobs_wait_idle
  [ "$(state price .status)" = ok ]
  [ "$(state price .notify)" = true ]
}

@test "a job's result with no notify and no count is ok, and its notify is false" {
  load_jobs bare
  job_file price
  jobs_tick
  jobs_wait_idle
  [ "$(state price .status)" = ok ]
  [ "$(state price .notify)" = false ]
}

@test "a result is cleaned as the result event's is" {
  load_jobs dirty
  job_file price
  jobs_tick
  jobs_wait_idle
  [ "$(state price .status)" = ok ]
  [ "$(state price .finding)" = "abc" ]
  [ "$(state price .text)" = $'xy\nz' ]
}

@test "the last result stays for the agent to read, and does not count as this run's" {
  load_jobs nothing
  job_file price
  printf '{"verdict":"old","text":"old","notify":true}' > "$HC_JOB_RESULTS/price.json"
  touch -t 202001010000 "$HC_JOB_RESULTS/price.json"
  jobs_tick
  jobs_wait_idle
  [ "$(state price .status)" = failed ]
  [ "$(state price .finding)" = null ]
  [ "$(jq -r .verdict "$HC_JOB_RESULTS/price.json")" = old ]
}

@test "a job file that fails the check is invalid, with the check's word, and does not run" {
  load_jobs write
  job_file price '.schedule = {every_hours: 2}'
  jobs_tick
  jobs_wait_idle
  [ ! -e "$STUB/starts" ]
  [ "$(state price .status)" = invalid ]
  [ "$(state price .error)" = schedule ]
  job_file price
  jobs_tick
  jobs_wait_idle
  [ "$(state price .status)" = ok ]
  [ "$(state price .error)" = null ]
}

@test "the 28 days count from the day the add-on first saw the job, not from its created" {
  load_jobs write
  job_file price ".end = \"$(days_after "$TODAY" 20)\""
  jq -n --arg d "$(days_after "$TODAY" -20)" '{first_seen: $d, status: "idle"}' > "$HC_JOB_STATE/price.json"
  jobs_tick
  [ "$(state price .status)" = invalid ]
  [ "$(state price .error)" = end ]
  [ ! -e "$STUB/starts" ]
}

@test "an 11th enabled job is invalid; the ten seen first run" {
  load_jobs quiet
  set_options '{"jobs_parallel":10}'
  for n in a b c d e f g h i j k; do job_file "j$n"; done
  jq -n --arg d "$(days_after "$TODAY" -1)" '{first_seen: $d, status: "idle"}' > "$HC_JOB_STATE/jk.json"
  jobs_tick
  jobs_wait_idle
  [ "$(state jk .status)" = ok ]
  [ "$(state jj .status)" = invalid ]
  [ "$(state jj .error)" = limit ]
  [ "$(wc -l < "$STUB/starts" | tr -d ' ')" -eq 10 ]
}

@test "a job past its end is moved to ended, its state goes and the change is told" {
  load_jobs write
  job_file price ".created = \"$(days_after "$TODAY" -3)\" | .end = \"$(days_after "$TODAY" -1)\""
  jq -n --arg d "$(days_after "$TODAY" -3)" '{first_seen: $d, status: "ok"}' > "$HC_JOB_STATE/price.json"
  jobs_tick
  [ ! -e "$HC_JOBS/price.json" ]
  [ -f "$HC_JOBS/ended/price.json" ]
  [ ! -e "$HC_JOB_STATE/price.json" ]
  grep -qx price "$CHANGES"
  [ ! -e "$STUB/starts" ]
}

@test "a job file seen more than 28 days ago is ended, also when it is invalid" {
  load_jobs write
  job_file price '.type = "nope"'
  jq -n --arg d "$(days_after "$TODAY" -29)" '{first_seen: $d, status: "invalid"}' > "$HC_JOB_STATE/price.json"
  jobs_tick
  [ -f "$HC_JOBS/ended/price.json" ]
  [ ! -e "$HC_JOB_STATE/price.json" ]
}

@test "the state of a job whose file is gone is removed and the change is told" {
  load_jobs write
  jq -n --arg d "$TODAY" '{first_seen: $d, status: "ok"}' > "$HC_JOB_STATE/gone.json"
  jobs_tick
  [ ! -e "$HC_JOB_STATE/gone.json" ]
  grep -qx gone "$CHANGES"
}

@test "a job file that is a link is invalid, and is not read" {
  load_jobs write
  job_file real
  mv "$HC_JOBS/real.json" "$BATS_TEST_TMPDIR/real.json"
  ln -s "$BATS_TEST_TMPDIR/real.json" "$HC_JOBS/price.json"
  jobs_tick
  [ "$(state price .status)" = invalid ]
  [ ! -e "$STUB/starts" ]
}

@test "a job never touches the handover" {
  load_jobs write
  mkdir -p "$HC_HANDOVER"
  printf 'today' > "$HC_HANDOVER/$TODAY.md"
  mkdir -p "$HC_HANDOVER/.claude"
  clean_handover() { echo cleaned >> "$CHANGES"; }
  job_file price
  jobs_tick
  jobs_wait_idle
  [ "$(cat "$HC_HANDOVER/$TODAY.md")" = today ]
  [ -d "$HC_HANDOVER/.claude" ]
  run grep cleaned "$CHANGES"
  [ "$status" -eq 1 ]
}

@test "at start, a job left running becomes failed, its PID file goes and the change is told" {
  load_jobs write
  job_file price
  jq -n --arg d "$TODAY" '{first_seen: $d, status: "running", last_run: 1}' > "$HC_JOB_STATE/price.json"
  # A PID that is alive: after a restart the number may be another process's.
  echo "$$" > "$HC_JOB_STATE/price.pid"
  jq -n --arg d "$TODAY" '{first_seen: $d, status: "ok"}' > "$HC_JOB_STATE/other.json"
  jobs_startup
  [ "$(state price .status)" = failed ]
  [ ! -e "$HC_JOB_STATE/price.pid" ]
  [ "$(state other .status)" = ok ]
  [ "$(cat "$CHANGES")" = price ]
  kill -0 "$$"
}

@test "jobs_stop ends the background runs" {
  load_jobs hang
  job_file price
  jobs_tick
  sleep 1
  pid="$(cat "$HC_JOB_STATE/price.pid")"
  jobs_stop
  for _ in 1 2 3 4 5; do
    pgrep -f "$STUB/claude" >/dev/null || break
    sleep 1
  done
  run pgrep -f "$STUB/claude"
  [ "$status" -ne 0 ]
  run kill -0 "$pid"
  [ "$status" -ne 0 ]
}

@test "a run whose runner is gone is failed on the next tick" {
  load_jobs hang
  job_file price
  jobs_tick
  sleep 1
  kill -KILL "$(cat "$HC_JOB_STATE/price.pid")"
  pkill -f "$STUB/claude" || true
  sleep 1
  [ "$(state price .status)" = running ]
  printf 'quiet\n%s\n' "$HC_JOB_RESULTS" > "$STUB/mode"
  # Not due again for four hours: the lost run counts as a run.
  jobs_tick
  [ "$(state price .status)" = failed ]
  [ "$(jobs_running)" = "" ]
}

@test "jobs_wait_idle returns at once with nothing running, and after the runs otherwise" {
  load_jobs slow
  started=$SECONDS
  jobs_wait_idle
  (( SECONDS - started < 2 ))
  job_file price
  jobs_tick
  [ "$(jobs_running)" = price ]
  jobs_wait_idle
  [ "$(jobs_running)" = "" ]
  [ "$(state price .status)" = ok ]
}

@test "a daily job's next run is its next time" {
  load_jobs write
  job_file price '.schedule = {time: "23:59"}'
  jobs_tick
  [ "$(state price .status)" = idle ]
  next="$(state price .next_run)"
  (( next > $(date +%s) ))
}

@test "the add-on loads the jobs after the result and before the commands, fails stale runs at start and stops the runs" {
  f="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/addon-run"
  grep -q ' result run report memory jobs fixed mqtt commands; do' "$f"
  grep -qx 'jobs_startup' "$f"
  grep -qx '  jobs_stop' "$f"
}

@test "a job file moved away for a tick and back is still counted from the day it was first seen" {
  load_jobs write
  job_file price ".end = \"$(days_after "$TODAY" 20)\""
  jq -n --arg d "$(days_after "$TODAY" -20)" '{first_seen: $d, status: "idle"}' > "$HC_JOB_STATE/price.json"
  # Not due: only the first sight is wanted from this tick.
  job_file price ".end = \"$(days_after "$TODAY" 5)\" | .enabled = false"
  jobs_tick
  [ "$(cat "$HC_JOB_STATE/seen/price")" = "$(days_after "$TODAY" -20)" ]
  mv "$HC_JOBS/price.json" "$BATS_TEST_TMPDIR/away.json"
  jobs_tick
  [ ! -e "$HC_JOB_STATE/price.json" ]
  job_file price ".end = \"$(days_after "$TODAY" 20)\""
  jobs_tick
  [ "$(state price .status)" = invalid ]
  [ "$(state price .error)" = end ]
  [ "$(state price .first_seen)" = "$(days_after "$TODAY" -20)" ]
  [ ! -e "$STUB/starts" ]
}

@test "a first-sight record goes once its 28 days are over and the name has no file" {
  load_jobs write
  mkdir -p "$HC_JOB_STATE/seen"
  days_after "$TODAY" -29 > "$HC_JOB_STATE/seen/old"
  days_after "$TODAY" -3 > "$HC_JOB_STATE/seen/recent"
  jobs_tick
  [ ! -e "$HC_JOB_STATE/seen/old" ]
  [ -e "$HC_JOB_STATE/seen/recent" ]
}

@test "the task and the result are never on jq's command line" {
  load_jobs write
  ARGS="$BATS_TEST_TMPDIR/jq-args"; : > "$ARGS"
  job_file price '.notify = "below 300 kr"'
  jq() { printf '%s\n' "$*" >> "$ARGS"; command jq "$@"; }
  jobs_tick
  jobs_wait_idle
  [ "$(command jq -r .finding "$HC_JOB_STATE/price.json")" = "Lowest 299 kr" ]
  jobs_tick
  [ -s "$ARGS" ]
  run grep -e kettle -e 299 -e "At the shop" -e "below 300" "$ARGS"
  [ "$status" -eq 1 ]
}

# fixed_job <name> [time] - a fixed job: the file in the working folder, its
# agent, and the placed copy. The agents are made up.
fixed_job() {
  mkdir -p "$HC_WORKSPACE/jobs" "$HC_WORKSPACE/.claude/agents"
  jq -nc --arg n "$1" --arg t "${2:-06:30}" \
    '{agent: $n, run_by: "automation", schedule: {time: $t}, task: "Test.", enabled: true}' \
    > "$HC_WORKSPACE/jobs/$1.json"
  touch "$HC_WORKSPACE/.claude/agents/$1.md"
  cp "$HC_WORKSPACE/jobs/$1.json" "$HC_JOBS/$1.json"
}

@test "a fixed job is checked, given its next run and never started" {
  load_jobs write
  load_lib fixed
  fixed_job alpha-run
  jobs_tick
  jobs_wait_idle
  [ "$(state alpha-run .status)" = idle ]
  [ "$(state alpha-run .error)" = null ]
  next="$(state alpha-run .next_run)"
  [[ "$next" =~ ^[0-9]+$ ]]
  [ "$(_job_date "$next" %H:%M)" = 06:30 ]
  [ -z "$(jobs_running)" ]
  [ ! -e "$STUB/starts" ]
  [ ! -e "$HC_JOB_STATE/seen/alpha-run" ]
  [ ! -e "$HC_JOB_STATE/alpha-run.pid" ]
}

@test "a fixed job is not ended after 28 days" {
  load_jobs write
  load_lib fixed
  fixed_job alpha-run
  jq -n --arg d "$(days_after "$TODAY" -40)" '{first_seen: $d, status: "idle"}' > "$HC_JOB_STATE/alpha-run.json"
  jobs_tick
  [ -f "$HC_JOBS/alpha-run.json" ]
  [ ! -e "$HC_JOBS/ended/alpha-run.json" ]
  [ "$(state alpha-run .status)" = idle ]
}

@test "fixed jobs come first and outside the cap" {
  load_jobs quiet
  load_lib fixed
  export HC_JOB_FILES=2
  for n in ja jb jc; do job_file "$n"; done
  fixed_job alpha-run
  run jobs_tick
  jobs_wait_idle
  [[ "$output" == *"3 job files; only the first 2"* ]]
  [ -f "$HC_JOB_STATE/alpha-run.json" ]
  [ "$(state alpha-run .status)" = idle ]
}

@test "a fixed job does not count towards the 10" {
  load_jobs quiet
  load_lib fixed
  set_options '{"jobs_parallel":10}'
  for n in a b c d e f g h i j; do job_file "j$n"; done
  fixed_job alpha-run
  jobs_tick
  jobs_wait_idle
  [ "$(state jj .status)" != invalid ]
  [ "$(state jj .error)" != limit ]
  [ "$(state alpha-run .status)" = idle ]
}

@test "a fixed file that differs is invalid, with no next run" {
  load_jobs write
  load_lib fixed
  fixed_job alpha-run
  jq -c '.task = "Other."' "$HC_WORKSPACE/jobs/alpha-run.json" > "$HC_JOBS/alpha-run.json"
  jobs_tick
  [ "$(state alpha-run .status)" = invalid ]
  [ "$(state alpha-run .error)" = differs ]
  [ "$(state alpha-run .next_run)" = null ]
  [ ! -e "$STUB/starts" ]
}

@test "a fixed job that is off has no next run; one that ran keeps its status" {
  load_jobs write
  load_lib fixed
  fixed_job alpha-run
  jq -c '.enabled = false' "$HC_WORKSPACE/jobs/alpha-run.json" > "$HC_JOBS/alpha-run.json"
  jq -n '{status: "failed", error: "timeout", last_run: 5}' > "$HC_JOB_STATE/alpha-run.json"
  jobs_tick
  [ "$(state alpha-run .status)" = failed ]
  [ "$(state alpha-run .next_run)" = null ]
  [ ! -e "$STUB/starts" ]
}

@test "a fixed job that is running is left alone" {
  load_jobs write
  load_lib fixed
  fixed_job alpha-run
  jq -n '{status: "running", next_run: 7}' > "$HC_JOB_STATE/alpha-run.json"
  sleep 30 & echo $! > "$HC_JOB_STATE/alpha-run.pid"
  jobs_tick
  kill $! 2>/dev/null || true
  [ "$(state alpha-run .status)" = running ]
  [ "$(state alpha-run .next_run)" = 7 ]
}

@test "a fixed job's next run is today's time before it, tomorrow's after it ran" {
  load_jobs write
  load_lib fixed
  fixed_job alpha-run
  job="$(fixed_check alpha-run "$HC_WORKSPACE/jobs/alpha-run.json")"
  [ "$(job_next "$job" '{}' "$(_job_epoch "$TODAY" 05:00)")" = "$(_job_epoch "$TODAY" 06:30)" ]
  state_json="$(jq -nc --argjson l "$(_job_epoch "$TODAY" 06:30)" '{last_run: $l}')"
  [ "$(job_next "$job" "$state_json" "$(_job_epoch "$TODAY" 07:00)")" = "$(_job_epoch "$(days_after "$TODAY" 1)" 06:30)" ]
  off="$(jq -c '.enabled = false' <<<"$job")"
  [ "$(job_next "$off" '{}' "$(_job_epoch "$TODAY" 05:00)")" = null ]
}

@test "a fixed job whose placed copy is missing keeps its state and is invalid" {
  load_jobs write
  load_lib fixed
  fixed_job alpha-run
  rm "$HC_JOBS/alpha-run.json"
  jq -n '{status: "ok", last_run: 5}' > "$HC_JOB_STATE/alpha-run.json"
  jobs_tick
  [ "$(state alpha-run .status)" = invalid ]
  [ "$(state alpha-run .error)" = unreadable ]
  [ "$(state alpha-run .last_run)" = 5 ]
  [ "$(grep -cx alpha-run "$CHANGES")" -eq 1 ]
}
