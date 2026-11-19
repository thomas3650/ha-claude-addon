load helpers

# ha-claude-jobs-mcp: the chat's jobs as tools, an MCP server over standard
# input and output. Driven here as the chat's Claude Code drives it: lines of
# JSON-RPC in, lines out.

SERVER="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/ha-claude-jobs-mcp"
CHECK_CMD="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/ha-claude-job-check"
EX="$BATS_TEST_DIRNAME/../ha-claude/schemas/examples"
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}'
INITED='{"jsonrpc":"2.0","method":"notifications/initialized"}'

eval "_base_setup() $(declare -f setup | tail -n +2)"
setup() {
  _base_setup
  unset HA_CLAUDE_UNATTENDED HA_CLAUDE_JOB HC_JOB_CHECK
  load_lib jobs
  export HC_JOBS HC_WORKSPACE HC_RESULTS
  export HC_LIB="$LIB"
  mkdir -p "$HC_JOBS/ended" "$HC_WORKSPACE/jobs" "$HC_WORKSPACE/.claude/agents"
  TODAY="$(date +%F)"
  END="$(jq -rn 'now + 7 * 86400 | strflocaltime("%Y-%m-%d")')"
}

# rpc <line>... - the lines to the server, its answers out.
rpc() { printf '%s\n' "$@" | "$SERVER"; }

# call <tool> <arguments-json> - the tool's text; fails on a refusal.
call() {
  local out
  out="$(rpc "$INIT" "$INITED" "$(jq -cn --arg n "$1" --argjson a "$2" \
    '{jsonrpc: "2.0", id: 2, method: "tools/call", params: {name: $n, arguments: $a}}')")"
  jq -r 'select(.id == 2) | .result.content[0].text' <<<"$out"
  [ "$(jq -r 'select(.id == 2) | .result.isError // false' <<<"$out")" = false ]
}

# set_job <name> <job-json> - job_set's arguments.
set_job() { call job_set "$(jq -cn --arg n "$1" --argjson j "$2" '{name: $n, job: $j}')"; }

# chat_job [enabled] - a valid chat job made today.
chat_job() {
  jq -c --arg c "$TODAY" --arg e "$END" --argjson on "${1:-true}" \
    '.created = $c | .end = $e | .enabled = $on' "$EX/valid/job-chat/daily-web.json"
}

# place <name> <job-json> - a job file already in the folder.
place() { printf '%s' "$2" > "$HC_JOBS/$1.json"; }

# repo_file <example> <name> - a file from the repo, placed as sync places it.
repo_file() {
  cp "$1" "$HC_WORKSPACE/jobs/$2.json"
  : > "$HC_WORKSPACE/.claude/agents/$2.md"
  cp "$1" "$HC_JOBS/$2.json"
}

# listing - every path under the jobs folder, for "nothing written".
listing() { (cd "$HC_JOBS" && find . | LC_ALL=C sort); }

@test "the server is executable in git, and its limits are the add-on's" {
  [ -x "$SERVER" ]
  [ "$(git -C "$BATS_TEST_DIRNAME/.." ls-files -s -- ha-claude/rootfs/usr/local/bin/ha-claude-jobs-mcp | cut -c1-6)" = 100755 ]
  grep -qx "const JOBS_MAX = $HC_JOBS_MAX;" "$SERVER"
  grep -qx "const JOB_BYTES = $HC_JOB_BYTES;" "$SERVER"
  grep -qxF "const NAME_RE = /${HC_JOB_NAME_RE}/;" "$SERVER"
}

@test "initialize, ping and tools/list: the three tools exactly" {
  run rpc "$INIT" "$INITED" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' '{"jsonrpc":"2.0","id":3,"method":"ping"}'
  [ "$status" -eq 0 ]
  [ "$(jq -sc 'map(.id)' <<<"$output")" = '[1,2,3]' ]
  [ "$(jq -r 'select(.id == 1) | .result.protocolVersion' <<<"$output")" = 2025-06-18 ]
  [ "$(jq -r 'select(.id == 1) | .result.serverInfo.name' <<<"$output")" = jobs ]
  [ "$(jq -c 'select(.id == 1) | .result.capabilities | keys' <<<"$output")" = '["tools"]' ]
  [ "$(jq -c 'select(.id == 2) | [.result.tools[].name]' <<<"$output")" = '["job_list","job_set","job_run_now"]' ]
  [ "$(jq -c 'select(.id == 2) | .result.tools[] | select(.name == "job_set") | .inputSchema.properties.job' <<<"$output")" = '{"type":"object"}' ]
  [ "$(jq -c 'select(.id == 3) | .result' <<<"$output")" = '{}' ]
  # A version it knows is the client's; one it does not is its own.
  run rpc '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}'
  [ "$(jq -r .result.protocolVersion <<<"$output")" = 2024-11-05 ]
  run rpc '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}'
  [ "$(jq -r .result.protocolVersion <<<"$output")" = 2025-06-18 ]
}

@test "job_set writes a valid chat job, and job_list shows it" {
  local job; job="$(chat_job)"
  run set_job kettle-price "$job"
  [ "$status" -eq 0 ]
  [ "$output" = "written: kettle-price" ]
  [ "$(jq -cS . "$HC_JOBS/kettle-price.json")" = "$(jq -cS . <<<"$job")" ]
  [ ! -e "$HC_JOBS/kettle-price.json.new" ]
  run call job_list '{}'
  [ "$status" -eq 0 ]
  [ "$(jq -c '.[0] | {name, from_repo, agent, enabled, end}' <<<"$output")" = \
    "$(jq -cn --arg e "$END" '{name: "kettle-price", from_repo: false, agent: "job-web", enabled: true, end: $e}')" ]
  [ "$(jq -r '.[0].task' <<<"$output")" = "Find the lowest price of a kettle." ]
  [ "$(jq -r '.[0].result' <<<"$output")" = "$HC_RESULTS/jobs/kettle-price.json" ]
}

@test "job_set refuses each invalid example with its word, and writes nothing" {
  local f word job before
  before="$(listing)"
  for f in "$EX"/invalid/job-chat/*.json; do
    word="$(basename "$f")"; word="${word%%-*}"
    job="$(jq -c --arg c "$TODAY" --arg e "$END" '.created = $c | if has("end") then .end = $e else . end' "$f")"
    run set_job some-job "$job"
    [ "$status" -ne 0 ] || { echo "$f: written"; false; }
    [ "${output%%:*}" = "$word" ] || { echo "$f: gave $output, wanted $word"; false; }
    [ "$(wc -l <<<"$output")" -eq 1 ]
  done
  [ "$(listing)" = "$before" ]
  # The field is named with the word.
  run set_job some-job "$(jq -c --arg c "$TODAY" --arg e "$END" '.created = $c | .end = $e' "$EX/invalid/job-chat/type-agent.json")"
  [ "$output" = "type: agent" ]
  run set_job some-job "$(chat_job | jq -c '.schedule = {time: "25:00"}')"
  [ "$output" = "schedule: schedule" ]
  run set_job some-job "$(chat_job | jq -c '.end = "2099-01-01"')"
  [ "$output" = "end: end" ]
}

@test "job_set: created is today for a new job, and unchanged for one that is there" {
  local old new
  old="$(jq -rn 'now - 5 * 86400 | strflocaltime("%Y-%m-%d")')"
  run set_job new-one "$(chat_job | jq -c --arg c "$old" '.created = $c')"
  [ "$status" -ne 0 ]; [ "$output" = "created: created" ]
  [ ! -e "$HC_JOBS/new-one.json" ]
  run set_job new-one "$(chat_job | jq -c 'del(.created)')"
  [ "$output" = "shape: created" ]
  place old-one "$(chat_job | jq -c --arg c "$old" '.created = $c')"
  run set_job old-one "$(chat_job | jq -c '.task = "Changed."')"
  [ "$status" -ne 0 ]; [ "$output" = "created: created" ]
  [ "$(jq -r .task "$HC_JOBS/old-one.json")" != Changed. ]
  run set_job old-one "$(chat_job | jq -c --arg c "$old" '.created = $c | .task = "Changed."')"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.task, .created' "$HC_JOBS/old-one.json")" = "Changed."$'\n'"$old" ]
}

@test "job_set refuses a string job, a name off the pattern and other arguments" {
  local before; before="$(listing)"
  run call job_set "$(jq -cn --arg j "$(chat_job)" '{name: "kettle", job: $j}')"
  [ "$status" -ne 0 ]; [ "$output" = "shape: job" ]
  run call job_set "$(jq -cn --argjson j "$(chat_job)" '{name: "Kettle", job: $j}')"
  [ "$output" = "name: name" ]
  run call job_set "$(jq -cn --argjson j "$(chat_job)" '{name: "../kettle", job: $j}')"
  [ "$output" = "name: name" ]
  run call job_set "$(jq -cn --argjson j "$(chat_job)" '{name: "kettle", job: [$j]}')"
  [ "$output" = "shape: job" ]
  run call job_set "$(jq -cn --argjson j "$(chat_job)" '{name: "kettle", job: $j, path: "/tmp/x"}')"
  [ "$output" = "shape: arguments" ]
  [ "$(listing)" = "$before" ]
}

@test "job_set on a file from the repo: only schedule, enabled and task change, and only for run_by jobs" {
  local f="$EX/valid/job-repo/briefing.json"
  repo_file "$f" night-briefing
  run set_job night-briefing "$(jq -c '.schedule = {time: "07:15"} | .enabled = false | .task = "Also the weather."' "$f")"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.schedule, .enabled, .task]' "$HC_JOBS/night-briefing.json")" = '[{"time":"07:15"},false,"Also the weather."]' ]
  run set_job night-briefing "$(jq -c '.timeout = 60' "$f")"
  [ "$status" -ne 0 ]; [ "${output%%:*}" = differs ]
  # The placed file is compared too, whatever the working folder's says.
  jq -c '.max_turns = 41' "$f" > "$HC_JOBS/night-briefing.json"
  run set_job night-briefing "$(cat "$f")"
  [ "$status" -ne 0 ]; [ "$output" = "differs: max_turns" ]
  [ "$(jq -r .max_turns "$HC_JOBS/night-briefing.json")" = 41 ]
  # A file with run_by automation is the owner's scripts', not the chat's.
  repo_file "$EX/valid/job-repo/step-a.json" house-round
  run set_job house-round "$(jq -c '.enabled = false' "$EX/valid/job-repo/step-a.json")"
  [ "$status" -ne 0 ]; [ "$output" = "run_by: run_by" ]
  [ "$(jq -r .enabled "$HC_JOBS/house-round.json")" = true ]
  # Only the files' own keys are compared, not what every object inherits:
  # with a check that passes everything, a key the placed file lacks differs.
  printf '#!/usr/bin/env bash\ncat >/dev/null\n' > "$BATS_TEST_TMPDIR/pass"
  chmod +x "$BATS_TEST_TMPDIR/pass"
  repo_file "$f" night-briefing
  HC_JOB_CHECK="$BATS_TEST_TMPDIR/pass" run set_job night-briefing "$(jq -c '. + {"__proto__": {}}' "$f")"
  [ "$status" -ne 0 ]; [ "$output" = "differs: __proto__" ]
  HC_JOB_CHECK="$BATS_TEST_TMPDIR/pass" run set_job night-briefing "$(jq -c '. + {"constructor": null}' "$f")"
  [ "$status" -ne 0 ]; [ "$output" = "differs: constructor" ]
  # A chat's job may not take a repo file's name.
  run set_job house-round "$(chat_job)"
  [ "$status" -ne 0 ]
}

@test "job_set writes the whole file in one step, beside it and then over it" {
  local job; job="$(chat_job)"
  place kettle "$(chat_job false)"
  ln "$HC_JOBS/kettle.json" "$BATS_TEST_TMPDIR/old-link"
  run set_job kettle "$job"
  [ "$status" -eq 0 ]
  # The old file is left whole: the new one replaced it, not overwrote it.
  [ "$(jq -r .enabled "$BATS_TEST_TMPDIR/old-link")" = false ]
  [ "$(jq -r .enabled "$HC_JOBS/kettle.json")" = true ]
  [ ! -e "$HC_JOBS/kettle.json.new" ]
  # A link in the place of the file beside it is not followed.
  echo keep > "$BATS_TEST_TMPDIR/target"
  ln -s "$BATS_TEST_TMPDIR/target" "$HC_JOBS/other.json.new"
  run set_job other "$job"
  [ "$status" -ne 0 ]; [ "$output" = "write: name" ]
  [ "$(cat "$BATS_TEST_TMPDIR/target")" = keep ]
  [ ! -e "$HC_JOBS/other.json" ]
  # Nor a hard link to another job's file, which is left whole.
  place third "$(chat_job false)"
  ln "$HC_JOBS/third.json" "$HC_JOBS/fourth.json.new"
  run set_job fourth "$job"
  [ "$status" -ne 0 ]; [ "$output" = "write: name" ]
  [ "$(jq -cS . "$HC_JOBS/third.json")" = "$(chat_job false | jq -cS .)" ]
  [ ! -e "$HC_JOBS/fourth.json" ]
  # A pipe there is refused at once, not waited on.
  mkfifo "$HC_JOBS/fifth.json.new"
  run set_job fifth "$job"
  [ "$status" -ne 0 ]; [ "$output" = "write: name" ]
  [ ! -e "$HC_JOBS/fifth.json" ]
  [ ! -e "$HC_JOBS/.lock" ]
}

@test "review 1: a task of 4000 characters with quotes and line breaks is written byte for byte as checked" {
  local task job
  task="$(jq -rn '[range(400) | "He said \"stop\"\nthen\\went æ "] | add | .[0:4000]')"
  job="$(chat_job | jq -c --arg t "$task" '.task = $t')"
  [ "$(jq '.task | length' <<<"$job")" -eq 4000 ]
  printf '#!/usr/bin/env bash\ntee "%s/seen" | "%s" "$@"\n' "$BATS_TEST_TMPDIR" "$CHECK_CMD" > "$BATS_TEST_TMPDIR/check"
  chmod +x "$BATS_TEST_TMPDIR/check"
  HC_JOB_CHECK="$BATS_TEST_TMPDIR/check" run set_job long-task "$job"
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/seen" "$HC_JOBS/long-task.json"
  [ "$(jq -c .task "$HC_JOBS/long-task.json")" = "$(jq -c .task <<<"$job")" ]
  [ "$(jq -r .task "$HC_JOBS/long-task.json")" = "$task" ]
  run set_job longer-task "$(jq -c '.task += "x"' <<<"$job")"
  [ "$status" -ne 0 ]; [ "$output" = "task: task" ]
}

@test "the limit: a tenth enabled job is written, an eleventh refused; a job switched off is not counted" {
  local i
  for i in 1 2 3 4 5 6 7 8 9; do place "job-$i" "$(chat_job)"; done
  place job-off "$(chat_job false)"
  run set_job job-ten "$(chat_job)"
  [ "$status" -eq 0 ]
  run set_job job-eleven "$(chat_job)"
  [ "$status" -ne 0 ]; [ "$output" = "limit: enabled" ]
  run set_job job-eleven "$(chat_job false)"
  [ "$status" -eq 0 ]
  # Changing one that is enabled does not count itself.
  run set_job job-1 "$(chat_job | jq -c '.task = "Again."')"
  [ "$status" -eq 0 ]
}

@test "review 4: two job_set calls at once with 9 enabled: one written, one refused with limit" {
  local i a b
  for i in 1 2 3 4 5 6 7 8 9; do place "job-$i" "$(chat_job)"; done
  # Both pass the first count while the lock is held, then meet it.
  mkdir -p "$HC_JOBS/.lock/held-by-test"
  set_job first-new "$(chat_job)" > "$BATS_TEST_TMPDIR/a" &
  a=$!
  set_job second-new "$(chat_job)" > "$BATS_TEST_TMPDIR/b" &
  b=$!
  sleep 2
  [ ! -e "$HC_JOBS/first-new.json" ] && [ ! -e "$HC_JOBS/second-new.json" ]
  # A lock another holds is left as it is.
  [ -d "$HC_JOBS/.lock/held-by-test" ]
  rmdir "$HC_JOBS/.lock/held-by-test" "$HC_JOBS/.lock"
  wait "$a" || true
  wait "$b" || true
  [ "$(cat "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b" | LC_ALL=C sort | tr '\n' ' ')" = "limit: enabled written: first-new " ] \
    || [ "$(cat "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b" | LC_ALL=C sort | tr '\n' ' ')" = "limit: enabled written: second-new " ]
  [ "$(find "$HC_JOBS" -maxdepth 1 -name '*-new.json' | wc -l)" -eq 1 ]
  [ ! -e "$HC_JOBS/.lock" ]
  [ -z "$(find "$HC_JOBS" -maxdepth 1 -name '.lock.*')" ]
}

@test "a lock left by a server that died is taken over, by one waiter at a time" {
  local a b
  mkdir -p "$HC_JOBS/.lock/dead-server"
  touch -t 202001010000 "$HC_JOBS/.lock/dead-server"
  set_job first-new "$(chat_job false)" > "$BATS_TEST_TMPDIR/a" &
  a=$!
  set_job second-new "$(chat_job false)" > "$BATS_TEST_TMPDIR/b" &
  b=$!
  wait "$a"
  wait "$b"
  [ "$(cat "$BATS_TEST_TMPDIR/a")" = "written: first-new" ]
  [ "$(cat "$BATS_TEST_TMPDIR/b")" = "written: second-new" ]
  [ ! -e "$HC_JOBS/.lock" ]
  [ -z "$(find "$HC_JOBS" -maxdepth 1 -name '.lock.*')" ]
  # A lock that is not old is not taken over.
  mkdir -p "$HC_JOBS/.lock/live-server"
  set_job third-new "$(chat_job false)" > "$BATS_TEST_TMPDIR/c" &
  a=$!
  sleep 1
  [ -d "$HC_JOBS/.lock/live-server" ]
  [ ! -e "$HC_JOBS/third-new.json" ]
  rmdir "$HC_JOBS/.lock/live-server" "$HC_JOBS/.lock"
  wait "$a"
  [ "$(cat "$BATS_TEST_TMPDIR/c")" = "written: third-new" ]
}

@test "job_list shows what is there, and skips ended/, .requests/, links and other names" {
  place kettle "$(chat_job | jq -c --arg t "$(printf 'y%.0s' $(seq 300))" '.task = $t')"
  repo_file "$EX/valid/job-repo/minimal-with-task.json" plant-check
  place ended-not "$(chat_job)"; mv "$HC_JOBS/ended-not.json" "$HC_JOBS/ended/"
  mkdir -p "$HC_JOBS/.requests"; : > "$HC_JOBS/.requests/kettle"
  ln -s "$HC_JOBS/kettle.json" "$HC_JOBS/linked.json"
  place Bad_Name "$(chat_job)"
  printf 'not json' > "$HC_JOBS/broken.json"
  run call job_list '{}'
  [ "$status" -eq 0 ]
  [ "$(jq -c 'map(.name)' <<<"$output")" = '["broken","kettle","plant-check"]' ]
  [ "$(jq -r '.[] | select(.name == "kettle") | .task | length' <<<"$output")" -eq 200 ]
  [ "$(jq -c '.[] | select(.name == "plant-check") | {from_repo, description, agent, result}' <<<"$output")" = \
    "$(jq -cn --arg r "$HC_RESULTS/plant-check.json" '{from_repo: true, description: "Looks at the plants", agent: "plant-check", result: $r}')" ]
  [ "$(jq -c '.[] | select(.name == "broken") | [.agent, .enabled]' <<<"$output")" = '[null,null]' ]
}

@test "job_run_now writes the request for a chat's job, and refuses a repo file, an unknown or invalid job" {
  place kettle "$(chat_job)"
  run call job_run_now '{"name":"kettle"}'
  [ "$status" -eq 0 ]; [ "$output" = "requested: kettle" ]
  [ -f "$HC_JOBS/.requests/kettle" ] && [ ! -s "$HC_JOBS/.requests/kettle" ]
  # Asked again: the same request, still empty.
  run call job_run_now '{"name":"kettle"}'
  [ "$status" -eq 0 ]
  repo_file "$EX/valid/job-repo/briefing.json" night-briefing
  run call job_run_now '{"name":"night-briefing"}'
  [ "$status" -ne 0 ]; [ "$output" = "repo: name" ]
  run call job_run_now '{"name":"nothing"}'
  [ "$output" = "missing: name" ]
  place old-form "$(chat_job | jq -c '.type = "web" | del(.agent)')"
  run call job_run_now '{"name":"old-form"}'
  [ "$output" = "shape: job" ]
  run call job_run_now '{"name":"../kettle"}'
  [ "$output" = "name: name" ]
  [ "$(ls -A "$HC_JOBS/.requests")" = kettle ]
}

@test "job_run_now does not follow a link in the place of the requests folder or a request" {
  place kettle "$(chat_job)"
  mkdir "$BATS_TEST_TMPDIR/elsewhere"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$HC_JOBS/.requests"
  run call job_run_now '{"name":"kettle"}'
  [ "$status" -ne 0 ]; [ "$output" = "requests: name" ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/elsewhere")" ]
  rm "$HC_JOBS/.requests"; mkdir "$HC_JOBS/.requests"
  echo keep > "$BATS_TEST_TMPDIR/target"
  ln -s "$BATS_TEST_TMPDIR/target" "$HC_JOBS/.requests/kettle"
  run call job_run_now '{"name":"kettle"}'
  [ "$status" -ne 0 ]; [ "$output" = "requests: name" ]
  [ "$(cat "$BATS_TEST_TMPDIR/target")" = keep ]
}

@test "every call is refused with HA_CLAUDE_UNATTENDED or HA_CLAUDE_JOB set" {
  local v value before
  place kettle "$(chat_job)"
  before="$(listing)"
  for v in HA_CLAUDE_UNATTENDED HA_CLAUDE_JOB; do
    for value in job-web ""; do
      export "$v=$value"
      run rpc "$INIT"
      [ "$(jq -r .result.serverInfo.name <<<"$output")" = jobs ]
      run call job_list '{}'
      [ "$status" -ne 0 ]; [ "$output" = "unattended: $v" ]
      run set_job other "$(chat_job)"
      [ "$status" -ne 0 ]; [ "$output" = "unattended: $v" ]
      run call job_run_now '{"name":"kettle"}'
      [ "$status" -ne 0 ]; [ "$output" = "unattended: $v" ]
      unset "$v"
    done
  done
  [ "$(listing)" = "$before" ]
}

@test "review 5: malformed JSON-RPC and an unknown method get an error answer, no crash and no write" {
  local before; before="$(listing)"
  run rpc "$INIT" 'not json' '[1,2]' '"text"' '{"jsonrpc":"2.0","id":5}' '{"jsonrpc":"1.0","id":6,"method":"ping"}' \
    '{"jsonrpc":"2.0","id":{"a":1},"method":"ping"}' '{"jsonrpc":"2.0","id":7,"method":"jobs/delete"}' \
    '{"jsonrpc":"2.0","method":"no/such/notification"}' \
    '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"job_delete","arguments":{"name":"kettle"}}}' \
    '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":"job_set"}' \
    '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"job_set","arguments":{"name":"kettle","job":{"agent":' \
    '{"jsonrpc":"2.0","id":11,"method":"ping"}'
  [ "$status" -eq 0 ]
  [ "$(jq -sc 'map([.id, .error.code])' <<<"$output")" = \
    '[[1,null],[null,-32700],[null,-32600],[null,-32600],[5,-32600],[6,-32600],[null,-32600],[7,-32601],[8,-32602],[9,-32602],[null,-32700],[11,null]]' ]
  [ "$(jq -c 'select(.id == 11) | .result' <<<"$output")" = '{}' ]
  # A last line without its line break is still a message.
  run bash -c "printf '%s' '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}' | '$SERVER'"
  [ "$(jq -c .result <<<"$output")" = '{}' ]
  [ "$(listing)" = "$before" ]
}

@test "nothing deletes a file" {
  local before f
  place kettle "$(chat_job)"
  place old-one "$(chat_job | jq -c '.type = "web"')"
  place ended-one "$(chat_job)"; mv "$HC_JOBS/ended-one.json" "$HC_JOBS/ended/"
  mkdir -p "$HC_JOBS/.requests"; : > "$HC_JOBS/.requests/old-one"
  repo_file "$EX/valid/job-repo/briefing.json" night-briefing
  before="$(cd "$HC_JOBS" && find . -type f | LC_ALL=C sort)"
  set_job kettle "$(chat_job false)" || true
  set_job old-one "$(chat_job)" || true
  set_job old-one '{}' || true
  set_job night-briefing "$(jq -c '.timeout = 1' "$EX/valid/job-repo/briefing.json")" || true
  call job_run_now '{"name":"kettle"}' || true
  call job_run_now '{"name":"old-one"}' || true
  call job_list '{}' >/dev/null || true
  while IFS= read -r f; do
    [ -f "$HC_JOBS/$f" ] || { echo "gone: $f"; false; }
  done <<<"$before"
  # The server has no call that removes a file; it removes only folders of
  # its lock.
  ! grep -nE 'unlink|rmSync|\.rm\(' "$SERVER"
  [ "$(grep -c 'rmdirSync' "$SERVER")" -eq 6 ]
  [ -z "$(grep 'rmdirSync' "$SERVER" | grep -vE 'rmdirSync\((LOCK|mine|path\.join\((LOCK|mine), [a-z]+\))\)')" ]
}
