load helpers

stub_actions() {
  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  raise_outcome() { echo "outcome $1 $2" >> "$CALLS"; }
  sync_workspace() { echo "sync" >> "$CALLS"; }
  install_managed_settings() { echo "managed" >> "$CALLS"; }
  ensure_layout() { :; }
  restart_chat() { echo "restart${1:+ $1}" >> "$CALLS"; }
  clear_chat() { echo "clear${1:+ $1}" >> "$CALLS"; }
}

@test "parse_command reads a JSON string, a plain word and an object" {
  load_lib commands
  [ "$(parse_command '"ping"')" = "ping" ]
  [ "$(parse_command 'ping')" = "ping" ]
  [ "$(parse_command '{"command":"sync"}')" = "sync" ]
  [ "$(parse_command $'ping\r')" = "ping" ]
}

@test "ping reports ok" {
  load_lib options commands; stub_actions
  handle_command '"ping"'
  [ "$(cat "$CALLS")" = "outcome ping ok" ]
}

@test "sync syncs, installs the managed settings, restarts the chat and reports ok" {
  load_lib options commands; stub_actions
  handle_command 'sync'
  [ "$(cat "$CALLS")" = $'sync\nmanaged\nrestart\noutcome sync ok' ]
}

@test "an unknown command is ignored and logged" {
  load_lib options commands; stub_actions
  run handle_command '"rm -rf /"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignoring unknown command"* ]]
  [ ! -s "$CALLS" ]
}

@test "an empty or malformed line is ignored" {
  load_lib options commands; stub_actions
  run handle_command ''
  [ "$status" -eq 0 ]
  run handle_command '{"broken'
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
}

@test "raise_outcome keeps the Supervisor token off the command line" {
  load_lib outcome
  export SUPERVISOR_TOKEN=tok-123
  curl() { printf '%s\n' "$*" > "$BATS_TEST_TMPDIR/curl-args"; cat > "$BATS_TEST_TMPDIR/curl-stdin"; }
  raise_outcome ping ok
  ! grep -q "tok-123" "$BATS_TEST_TMPDIR/curl-args"
  grep -q "Bearer tok-123" "$BATS_TEST_TMPDIR/curl-stdin"
}

@test "a malformed command is ignored with a log line, an empty one silently" {
  load_lib options commands; stub_actions
  run handle_command '{"broken'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignoring malformed command"* ]]
  run handle_command ''
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$CALLS" ]
}

@test "read_command returns a whole line" {
  load_lib commands
  read_command 2 got <<<'"ping"'
  [ "$got" = '"ping"' ]
}

@test "a command that arrives in two parts across a timeout is put together" {
  load_lib commands
  exec 9< <(printf '"pi'; sleep 2; printf 'ng"\n'; sleep 1)
  read_command 1 got <&9 && rc=0 || rc=$?
  [ "$rc" -eq 2 ]
  [ "$HC_PARTIAL" = '"pi' ]
  read_command 4 got <&9
  [ "$got" = '"ping"' ]
  exec 9<&-
}

@test "a part whose rest never arrives is dropped after one quiet wait, with a log line" {
  load_lib commands
  exec 9< <(printf '"pi'; sleep 4)
  read_command 1 got <&9 && rc=0 || rc=$?
  [ "$HC_PARTIAL" = '"pi' ]
  read_command 1 got <&9 2>"$BATS_TEST_TMPDIR/err" && rc=0 || rc=$?
  [ "$rc" -eq 2 ]
  [ -z "$HC_PARTIAL" ]
  grep -q "dropping an unfinished command" "$BATS_TEST_TMPDIR/err"
  exec 9<&-
}

@test "a command without a line ending is handled when standard input closes" {
  load_lib commands
  exec 9< <(printf 'ping')
  read_command 2 got <&9
  [ "$got" = 'ping' ]
  read_command 1 got <&9 && rc=0 || rc=$?
  [ "$rc" -eq 1 ]
  exec 9<&-
}

@test "a timeout with nothing read reports a timeout and keeps nothing" {
  load_lib commands
  exec 9< <(sleep 3)
  read_command 1 got <&9 && rc=0 || rc=$?
  [ "$rc" -eq 2 ]
  [ -z "$HC_PARTIAL" ]
  exec 9<&-
}

@test "morning starts the run of the file morning_job names, and returns" {
  load_lib options morning commands; stub_actions
  job_command() { echo "job $1" >> "$CALLS"; }
  fixed_is() { [[ "$1" == beta-run ]]; }
  set_options '{"morning_job":"beta-run"}'
  handle_command 'morning'
  [ "$(cat "$CALLS")" = "job beta-run" ]
}

@test "morning without morning_job, or naming no file from the repo, is not configured and leaves the chat alone" {
  load_lib options morning commands; stub_actions
  job_command() { echo "job $1" >> "$CALLS"; }
  fixed_is() { [[ "$1" == beta-run ]]; }
  handle_command 'morning'
  set_options '{"morning_job":"delta-run"}'
  handle_command 'morning'
  [ "$(cat "$CALLS")" = $'outcome morning not_configured\noutcome morning not_configured' ]
}

@test "sync and restart-chat report failed when no chat session could be started" {
  load_lib options morning commands; stub_actions
  restart_chat() { echo "restart" >> "$CALLS"; return 1; }
  handle_command 'sync'
  handle_command 'restart-chat'
  [ "$(grep -c 'outcome sync failed' "$CALLS")" -eq 1 ]
  [ "$(grep -c 'outcome restart-chat failed' "$CALLS")" -eq 1 ]
}

@test "sync reports kept when the repo could not be fetched and the old working folder stays" {
  load_lib options morning commands; stub_actions
  sync_workspace() { HC_SYNC_RESULT=kept; }
  handle_command 'sync'
  [ "$(tail -1 "$CALLS")" = "outcome sync kept" ]
  sync_workspace() { HC_SYNC_RESULT=ok; }
  handle_command 'sync'
  [ "$(tail -1 "$CALLS")" = "outcome sync ok" ]
}

@test "report runs the report file, with the month when one is given, and reports the outcome" {
  load_lib options report commands; stub_actions
  REPORT_OUTCOME=ok
  run_report() { echo "report${2:+ $2}" >> "$CALLS"; printf -v "$1" '%s' "$REPORT_OUTCOME"; }
  handle_command '"report"'
  [ "$(cat "$CALLS")" = $'report\noutcome report ok' ]
  : > "$CALLS"
  handle_command '"report 2026-09"'
  [ "$(cat "$CALLS")" = $'report 2026-09\noutcome report ok' ]
  : > "$CALLS"
  REPORT_OUTCOME=not_configured
  handle_command 'report'
  [ "$(cat "$CALLS")" = $'report\noutcome report not_configured' ]
}

@test "an argument on a command that takes none makes it unknown" {
  load_lib options report commands; stub_actions
  run handle_command '"sync now"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignoring unknown command"* ]]
  [ ! -s "$CALLS" ]
  run handle_command 'ping 1'
  [[ "$output" == *"ignoring unknown command"* ]]
  [ ! -s "$CALLS" ]
}

@test "parse_command reads a plain command with a month" {
  load_lib commands
  [ "$(parse_command 'report 2026-09')" = "report 2026-09" ]
  [ "$(parse_command '"report 2026-09"')" = "report 2026-09" ]
}

@test "a stop signal during a report ends the main process at once" {
  STUB="$HC_DATA/workspace/assistant/.claude"
  mkdir -p "$STUB" "$HC_DATA/state"
  printf '#!/usr/bin/env bash\nsleep 30 &\ntrap "kill $!" TERM\nwait\n' > "$STUB/report"
  chmod 755 "$STUB/report"
  cat > "$BATS_TEST_TMPDIR/main" <<EOT
for f in paths log options env report commands; do . "$LIB/\$f.sh"; done
raise_outcome() { :; }
trap 'echo stopped; exit 0' TERM
handle_command report
echo finished
EOT
  HC_LIMIT_BIN="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/ha-claude-limit" \
    bash "$BATS_TEST_TMPDIR/main" > "$BATS_TEST_TMPDIR/out" 2>&1 3>&- &
  pid=$!
  sleep 2
  kill -TERM "$pid"
  for _ in 1 2 3 4 5; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  pkill -f "$STUB/report" 2>/dev/null || true
  run kill -0 "$pid"
  [ "$status" -ne 0 ]
  grep -qx "stopped" "$BATS_TEST_TMPDIR/out"
  run grep "finished" "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 1 ]
}


stub_run() {
  raise_outcome() { echo "outcome $*" >> "$CALLS"; }
  RUN_OUTCOME=ok
  run_agent() { echo "agent $2" >> "$CALLS"; printf -v "$1" '%s' "$RUN_OUTCOME"; }
}

@test "run starts the named agent, leaves the chat alone and reports the outcome with the agent" {
  load_lib options morning run commands; stub_actions; stub_run
  handle_command '"run house-check"'
  [ "$(cat "$CALLS")" = $'agent house-check\noutcome run ok house-check command' ]
  : > "$CALLS"
  RUN_OUTCOME=timeout
  handle_command 'run house-check'
  [ "$(cat "$CALLS")" = $'agent house-check\noutcome run timeout house-check command' ]
  run grep restart "$CALLS"
  [ "$status" -eq 1 ]
}

@test "run without a name is unknown" {
  load_lib options morning run commands; stub_actions; stub_run
  run handle_command '"run"'
  [[ "$output" == *"ignoring unknown command"* ]]
  run handle_command 'run'
  [[ "$output" == *"ignoring unknown command"* ]]
  [ ! -s "$CALLS" ]
}

@test "run with a name that is not an agent name starts nothing and does not echo the name" {
  load_lib options env morning result run commands; stub_actions
  raise_outcome() { echo "outcome $*" >> "$CALLS"; }
  mkdir -p "$HC_WORKSPACE/.claude/agents"
  touch "$HC_WORKSPACE/.claude/agents/chat.md"
  HC_CLAUDE_BIN="$BATS_TEST_TMPDIR/never"
  long="$(printf 'a%.0s' {1..33})"
  for line in '"run a b"' '"run chat"' "\"run $long\"" '"run ../x"' '"run Abc"'; do
    : > "$CALLS"
    handle_command "$line"
    [ "$(cat "$CALLS")" = "outcome run not_configured  command" ]
  done
  # A name with no agent file is a name: it is in the event.
  : > "$CALLS"
  handle_command '"run beta-run"'
  [ "$(cat "$CALLS")" = "outcome run not_configured beta-run command" ]
}

@test "parse_command reads a plain run with a name" {
  load_lib commands
  [ "$(parse_command 'run house-check')" = "run house-check" ]
  [ "$(parse_command '"run house-check"')" = "run house-check" ]
}

@test "a plain line with a word after a command that takes a month or nothing is still malformed" {
  load_lib commands
  [ -z "$(parse_command 'report abc')" ]
  [ -z "$(parse_command 'sync now')" ]
  [ "$(parse_command 'report 2026-09')" = "report 2026-09" ]
}

@test "a stop signal during a run ends the main process at once" {
  STUB="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB" "$HC_DATA/workspace/assistant/.claude/agents"
  touch "$HC_DATA/workspace/assistant/.claude/agents/house-check.md"
  printf '#!/usr/bin/env bash\nsleep 30 &\ntrap "kill $!" TERM\nwait\n' > "$STUB/claude"
  chmod +x "$STUB/claude"
  cat > "$BATS_TEST_TMPDIR/main" <<EOT
for f in paths log options env morning result run commands; do . "$LIB/\$f.sh"; done
raise_outcome() { :; }
restart_chat() { :; }
trap 'echo stopped; exit 0' TERM
handle_command 'run house-check'
echo finished
EOT
  HC_CLAUDE_BIN="$STUB/claude" \
  HC_LIMIT_BIN="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/ha-claude-limit" \
    bash "$BATS_TEST_TMPDIR/main" > "$BATS_TEST_TMPDIR/out" 2>&1 3>&- &
  pid=$!
  sleep 2
  kill -TERM "$pid"
  for _ in 1 2 3 4 5; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  pkill -f "$STUB/claude" 2>/dev/null || true
  run kill -0 "$pid"
  [ "$status" -ne 0 ]
  grep -qx "stopped" "$BATS_TEST_TMPDIR/out"
  run grep "finished" "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 1 ]
}

@test "clear-chat clears the chat and reports the outcome" {
  load_lib options commands; stub_actions
  handle_command 'clear-chat'
  [ "$(cat "$CALLS")" = $'clear\noutcome clear-chat ok' ]
  clear_chat() { return 1; }
  handle_command 'clear-chat'
  [ "$(tail -1 "$CALLS")" = "outcome clear-chat failed" ]
}

@test "clear-chat takes no opening from standard input" {
  load_lib options commands; stub_actions
  run handle_command 'clear-chat say something'
  [[ "$output" == *"ignoring"* ]]
  [ ! -s "$CALLS" ]
  run handle_command '{"command":"clear-chat say something"}'
  [ ! -s "$CALLS" ]
}

@test "a sync of the same commit clears the chat instead of restarting it, and reports ok" {
  load_lib options morning commands; stub_actions
  sync_workspace() { echo "sync" >> "$CALLS"; HC_SYNC_RESULT=same; }
  handle_command 'sync'
  [ "$(cat "$CALLS")" = $'sync\nmanaged\nclear\noutcome sync ok' ]
}

@test "with chat_resume a sync with nothing new leaves the chat alone, and a sync with something new restarts it" {
  load_lib options morning commands; stub_actions
  set_options '{"chat_resume":true}'
  chat_alive() { return 1; }
  start_chat() { echo "start${1:+ $1}" >> "$CALLS"; }
  sync_workspace() { echo "sync" >> "$CALLS"; HC_SYNC_RESULT=same; }
  handle_command 'sync'
  # start_chat does nothing when the chat runs, and starts it when it does not.
  [ "$(cat "$CALLS")" = $'sync\nmanaged\nstart\noutcome sync ok' ]
  : > "$CALLS"
  start_chat() { return 1; }
  handle_command 'sync'
  [ "$(tail -1 "$CALLS")" = "outcome sync failed" ]
  : > "$CALLS"
  # Something new: a restart, without an opening, so the new instructions
  # load and the chat loop continues the conversation (see session.bats).
  sync_workspace() { echo "sync" >> "$CALLS"; HC_SYNC_RESULT=ok; }
  handle_command 'sync'
  [ "$(cat "$CALLS")" = $'sync\nmanaged\nrestart\noutcome sync ok' ]
}

@test "with chat_resume a sync with nothing new restarts a chat whose pane no longer runs Claude Code" {
  load_lib options morning commands; stub_actions
  set_options '{"chat_resume":true}'
  start_chat() { echo "start" >> "$CALLS"; }
  sync_workspace() { echo "sync" >> "$CALLS"; HC_SYNC_RESULT=same; }
  # The chat is stuck at a shell: after three quick exits, or not logged in.
  chat_alive() { return 0; }
  _pane_runs_claude() { return 1; }
  handle_command 'sync'
  [ "$(cat "$CALLS")" = $'sync\nmanaged\nrestart\noutcome sync ok' ]
  : > "$CALLS"
  restart_chat() { echo "restart" >> "$CALLS"; return 1; }
  handle_command 'sync'
  [ "$(tail -1 "$CALLS")" = "outcome sync failed" ]
  : > "$CALLS"
  # Claude Code runs: nothing is done to the chat.
  _pane_runs_claude() { return 0; }
  handle_command 'sync'
  [ "$(cat "$CALLS")" = $'sync\nmanaged\nstart\noutcome sync ok' ]
}

@test "a sync of the same commit reports failed when the chat could not be cleared or started" {
  load_lib options morning commands; stub_actions
  sync_workspace() { HC_SYNC_RESULT=same; }
  clear_chat() { return 1; }
  handle_command 'sync'
  [ "$(tail -1 "$CALLS")" = "outcome sync failed" ]
}

stub_jobs() {
  jobs_tick() { echo "tick" >> "$CALLS"; }
  jobs_wait_idle() { echo "wait" >> "$CALLS"; }
}

@test "jobs tick ticks the jobs and reports nothing" {
  load_lib options commands; stub_actions; stub_jobs
  handle_command '"jobs tick"'
  handle_command 'jobs tick'
  handle_command '{"command":"jobs tick"}'
  [ "$(cat "$CALLS")" = $'tick\ntick\ntick' ]
}

@test "jobs takes tick and nothing else" {
  load_lib options commands; stub_actions; stub_jobs
  for line in '"jobs"' 'jobs' '"jobs run"' '"jobs tick now"' '"tick"' '"jobs  tick"'; do
    run handle_command "$line"
    [ "$status" -eq 0 ]
  done
  [ ! -s "$CALLS" ]
  [ -z "$(parse_command 'jobs foo')" ]
  [ "$(parse_command 'jobs tick')" = "jobs tick" ]
}

@test "sync waits for the running jobs before it changes anything" {
  load_lib options commands; stub_actions; stub_jobs
  handle_command 'sync'
  [ "$(cat "$CALLS")" = $'wait\nsync\nmanaged\nrestart\noutcome sync ok' ]
}

teardown() {
  declare -F jobs_stop >/dev/null && jobs_stop
  return 0
}

@test "jobs tick returns at once while jobs run, and sync waits for them and starts none" {
  load_lib options env morning result jobs commands; stub_actions
  mkdir -p "$HC_JOBS" "$HC_JOB_RESULTS" "$HC_JOB_STATE"
  STUB="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB" "$HC_WORKSPACE/.claude/agents"
  touch "$HC_WORKSPACE/.claude/agents/job-web.md"
  printf '#!/usr/bin/env bash\necho "$HA_CLAUDE_JOB $(date +%%s)" >> "%s/starts"\ncat >/dev/null\nsleep 3\nprintf %s > "%s/$HA_CLAUDE_JOB.json"\n' \
    "$STUB" "'{\"verdict\":\"v\",\"text\":\"t\",\"notify\":false}'" "$HC_JOB_RESULTS" > "$STUB/claude"
  chmod +x "$STUB/claude"
  export HC_CLAUDE_BIN="$STUB/claude"
  export HC_LIMIT_BIN="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/ha-claude-limit"
  today="$(date +%F)"
  end="$(jq -rn --arg d "$today" '$d | strptime("%Y-%m-%d") | mktime + 86400 | strftime("%Y-%m-%d")')"
  job() {
    jq -n --arg t "$today" --arg e "$end" \
      '{agent: "job-web", task: "t", schedule: {every_hours: 4}, end: $e, enabled: true, created: $t}' > "$HC_JOBS/$1.json"
  }
  job first
  started=$SECONDS
  handle_command '"jobs tick"'
  (( SECONDS - started < 2 ))
  [ "$(jobs_running)" = first ]
  job second
  handle_command 'sync'
  synced=$(date +%s)
  [ "$(jobs_running)" = "" ]
  [ "$(wc -l < "$STUB/starts" | tr -d ' ')" -eq 1 ]
  [ "$(jq -r .status "$HC_JOB_STATE/first.json")" = ok ]
  grep -qx "sync" "$CALLS"
  handle_command '"jobs tick"'
  jobs_wait_idle
  second_start="$(awk '$1 == "second" {print $2}' "$STUB/starts")"
  (( second_start >= synced ))
}
