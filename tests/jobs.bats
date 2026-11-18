load helpers

# Job files: read, checked and scheduled. Times are local; the tests fix the
# zone so a day has the same hours everywhere.
export TZ=Europe/Copenhagen

# epoch_at <YYYY-MM-DD> <HH:MM> - the local time as seconds, GNU date first.
epoch_at() {
  date -d "$1 $2:00" +%s 2>/dev/null || date -j -f '%Y-%m-%d %H:%M:%S' "$1 $2:00" +%s
}

# days_after <YYYY-MM-DD> <n> - the date n days later.
days_after() {
  jq -rn --arg d "$1" --argjson n "$2" '$d | strptime("%Y-%m-%d") | mktime + $n * 86400 | strftime("%Y-%m-%d")'
}

# job_file <name> [jq-update] - writes a valid web job, changed by the update.
job_file() {
  mkdir -p "$HC_JOBS"
  jq -n --arg today "$TODAY" --arg end "$(days_after "$TODAY" 14)" \
    '{type: "web", task: "Find the lowest price of a kettle.", schedule: {time: "07:10"},
      end: $end, enabled: true, created: $today}' \
    | jq "${2:-.}" > "$HC_JOBS/$1.json"
}

checks() {
  load_lib options env result jobs
  TODAY=2026-11-18
}

@test "a valid web job passes and is printed in its normal form" {
  checks
  job_file price
  run job_check price "$HC_JOBS/price.json" "$TODAY" 0
  [ "$status" -eq 0 ]
  [ "$(jq -r '.name' <<<"$output")" = price ]
  [ "$(jq -r '.type' <<<"$output")" = web ]
  [ "$(jq -c '.schedule' <<<"$output")" = '{"time":"07:10","days":["mon","tue","wed","thu","fri","sat","sun"]}' ]
  [ "$(jq -r '.enabled' <<<"$output")" = true ]
  [ "$(jq -r '.notify' <<<"$output")" = null ]
}

# refused <word> - the last check refused with that word and printed nothing else.
refused() {
  run job_check "${NAME:-price}" "$HC_JOBS/price.json" "${SINCE:-$TODAY}" "${OTHERS:-0}"
  [ "$status" -eq 1 ]
  [ "$output" = "$1" ]
}

@test "a task of 4001 characters is refused; 4000 pass" {
  checks
  job_file price ".task = \"$(printf 'x%.0s' {1..4000})\""
  run job_check price "$HC_JOBS/price.json" "$TODAY" 0
  [ "$status" -eq 0 ]
  job_file price ".task = \"$(printf 'x%.0s' {1..4001})\""
  refused task
  job_file price '.task = ""'
  refused task
  job_file price '.task = 7'
  refused task
}

@test "an end more than 28 days after it was made is refused; 28 days pass" {
  checks
  job_file price ".end = \"$(days_after "$TODAY" 29)\""
  refused end
  job_file price ".end = \"$(days_after "$TODAY" 28)\""
  run job_check price "$HC_JOBS/price.json" "$TODAY" 0
  [ "$status" -eq 0 ]
  job_file price '.end = "2026-02-30"'
  refused end
  job_file price ".end = \"$(days_after "$TODAY" -1)\""
  refused end
  job_file price 'del(.end)'
  refused shape
}

@test "created moved later does not stretch the 28 days: they count from the add-on's own first sight" {
  checks
  job_file price ".created = \"$(days_after "$TODAY" 10)\" | .end = \"$(days_after "$TODAY" 30)\""
  SINCE="$TODAY" refused end
  job_file price ".created = \"$(days_after "$TODAY" 10)\" | .end = \"$(days_after "$TODAY" 28)\""
  run job_check price "$HC_JOBS/price.json" "$TODAY" 0
  [ "$status" -eq 0 ]
  job_file price '.created = "yesterday"'
  refused shape
}

@test "a schedule outside its limits is refused" {
  checks
  for bad in '{every_hours: 3}' '{every_hours: 25}' '{every_hours: 4.5}' '{every_hours: "4"}' \
             '{time: "7:10"}' '{time: "24:00"}' '{time: "07:60"}' '{time: "07:10", every_hours: 6}' \
             '{time: "07:10", days: []}' '{time: "07:10", days: ["monday"]}' \
             '{time: "07:10", days: ["mon", "mon"]}' '{time: "07:10", when: 1}' '{}' '"daily"'; do
    job_file price ".schedule = $bad"
    refused schedule
  done
  for good in '{every_hours: 4}' '{every_hours: 24}' '{time: "00:00", days: ["sat", "sun"]}' '{time: "23:59"}'; do
    job_file price ".schedule = $good"
    run job_check price "$HC_JOBS/price.json" "$TODAY" 0
    [ "$status" -eq 0 ]
  done
}

@test "an unknown type is refused" {
  checks
  for bad in '"agent"' '"Web"' '1' 'null'; do
    job_file price ".type = $bad"
    refused type
  done
  for good in private web all; do
    job_file price ".type = \"$good\""
    run job_check price "$HC_JOBS/price.json" "$TODAY" 0
    [ "$status" -eq 0 ]
  done
}

@test "an 11th enabled job is refused; a disabled one is not counted against it" {
  checks
  job_file price
  OTHERS=10 refused limit
  run job_check price "$HC_JOBS/price.json" "$TODAY" 9
  [ "$status" -eq 0 ]
  job_file price '.enabled = false'
  run job_check price "$HC_JOBS/price.json" "$TODAY" 10
  [ "$status" -eq 0 ]
}

@test "an agent field is refused: the predefined jobs come later" {
  checks
  job_file price '.agent = "morning-briefing"'
  refused shape
}

@test "unknown fields, a second value and other shapes are refused" {
  checks
  for bad in '.more = 1' '.enabled = "yes"' '.notify = 7' 'del(.enabled)' 'del(.created)' '[.]'; do
    job_file price "$bad"
    refused shape
  done
  job_file price
  cat "$HC_JOBS/price.json" "$HC_JOBS/price.json" > "$BATS_TEST_TMPDIR/two"
  cp "$BATS_TEST_TMPDIR/two" "$HC_JOBS/price.json"
  refused shape
  printf 'not json' > "$HC_JOBS/price.json"
  refused shape
  job_file price '.notify = "below 300 kr"'
  run job_check price "$HC_JOBS/price.json" "$TODAY" 0
  [ "$status" -eq 0 ]
  [ "$(jq -r '.notify' <<<"$output")" = "below 300 kr" ]
}

@test "a name that is not a job name is refused" {
  checks
  job_file price
  for bad in Price 1a -a a.b "a b" "$(printf 'a%.0s' {1..33})"; do
    NAME="$bad" refused name
  done
  run job_check "" "$HC_JOBS/price.json" "$TODAY" 0
  [ "$status" -eq 1 ]
  [ "$output" = name ]
}

@test "job_read copies the file and refuses a link, a large file and a pipe" {
  checks
  export HC_LIMIT_BIN="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/ha-claude-limit"
  job_file price
  job_read price "$BATS_TEST_TMPDIR/copy"
  cmp "$HC_JOBS/price.json" "$BATS_TEST_TMPDIR/copy"
  run job_read Price "$BATS_TEST_TMPDIR/copy"
  [ "$status" -eq 1 ]
  run job_read none "$BATS_TEST_TMPDIR/copy"
  [ "$status" -eq 1 ]
  printf 'secret' > "$BATS_TEST_TMPDIR/outside"
  ln -s "$BATS_TEST_TMPDIR/outside" "$HC_JOBS/link.json"
  run job_read link "$BATS_TEST_TMPDIR/copy"
  [ "$status" -eq 1 ]
  [ ! -s "$BATS_TEST_TMPDIR/copy" ]
  head -c 17408 /dev/zero | tr '\0' x > "$HC_JOBS/big.json"
  run job_read big "$BATS_TEST_TMPDIR/copy"
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/copy" ]
  mkfifo "$HC_JOBS/pipe.json"
  started=$SECONDS
  run job_read pipe "$BATS_TEST_TMPDIR/copy"
  [ "$status" -eq 1 ]
  (( SECONDS - started <= 5 ))
}

@test "job_read reads as the Claude user, never by the add-on's own process" {
  checks
  export HC_LIMIT_BIN="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/ha-claude-limit"
  job_file price
  as_claude() { echo "as_claude $*" >> "$BATS_TEST_TMPDIR/as"; "$@"; }
  job_read price "$BATS_TEST_TMPDIR/copy"
  grep -q "head -c 16385 -- $HC_JOBS/price.json" "$BATS_TEST_TMPDIR/as"
}

@test "a pipe swapped in after the check costs at most the time limit" {
  checks
  export HC_LIMIT_BIN="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/ha-claude-limit"
  mkdir -p "$HC_JOBS"
  mkfifo "$HC_JOBS/pipe.json"
  # The check sees a plain file; the copy then meets the pipe.
  _job_plain() { return 0; }
  started=$SECONDS
  run job_read pipe "$BATS_TEST_TMPDIR/copy"
  [ "$status" -eq 1 ]
  (( SECONDS - started <= 8 ))
}

@test "job_list prints the names of the job files, and nothing else in the folder" {
  checks
  job_file b-job
  job_file a-job
  mkdir -p "$HC_JOBS/ended"
  touch "$HC_JOBS/ended/old.json" "$HC_JOBS/Upper.json" "$HC_JOBS/notes.txt" "$HC_JOBS/a.b.json"
  mkdir "$HC_JOBS/dir.json"
  run job_list
  [ "$status" -eq 0 ]
  [ "$output" = $'a-job\nb-job' ]
}

@test "job_list prints nothing for no folder" {
  checks
  run job_list
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# due <job-update> <state> <now as HH:MM today, or an epoch> - job_due's status.
due() {
  local now="$3"
  [[ "$now" == *:* ]] && now="$(epoch_at "$TODAY" "$now")"
  job_file price "$1"
  job="$(job_check price "$HC_JOBS/price.json" "$TODAY" 0)"
  run job_due "$job" "$2" "$now"
}

@test "a daily job is due once its time has passed today, and not again the same day" {
  checks
  yesterday="$(days_after "$TODAY" -1)"
  due . "{\"last_run\": $(epoch_at "$yesterday" 07:10)}" 07:20
  [ "$status" -eq 0 ]
  due . "{\"last_run\": $(epoch_at "$TODAY" 07:12)}" 07:20
  [ "$status" -eq 1 ]
  due . "{\"last_run\": $(epoch_at "$yesterday" 07:10)}" 07:05
  [ "$status" -eq 1 ]
  due . '{"last_run": null}' 07:20
  [ "$status" -eq 0 ]
  due . '{}' 07:20
  [ "$status" -eq 0 ]
  due . '{}' 07:00
  [ "$status" -eq 1 ]
}

@test "a job on given days is due only on them" {
  checks
  # 2026-11-18 is a Wednesday.
  due '.schedule.days = ["wed"]' '{}' 08:00
  [ "$status" -eq 0 ]
  due '.schedule.days = ["mon", "tue", "thu"]' '{}' 08:00
  [ "$status" -eq 1 ]
}

@test "a job every 4 hours is not due 3 hours 59 minutes after its last run, and is at 4 hours" {
  checks
  now="$(epoch_at "$TODAY" 12:00)"
  due '.schedule = {every_hours: 4}' "{\"last_run\": $((now - 4 * 3600 + 60))}" "$now"
  [ "$status" -eq 1 ]
  due '.schedule = {every_hours: 4}' "{\"last_run\": $((now - 4 * 3600))}" "$now"
  [ "$status" -eq 0 ]
  due '.schedule = {every_hours: 4}' '{}' "$now"
  [ "$status" -eq 0 ]
}

@test "a job past its end, a disabled job and a running job are not due" {
  checks
  due ".end = \"$TODAY\"" '{}' 08:00
  [ "$status" -eq 0 ]
  job_file price ".end = \"$TODAY\""
  job="$(job_check price "$HC_JOBS/price.json" "$(days_after "$TODAY" -3)" 0)"
  run job_due "$job" '{}' "$(epoch_at "$(days_after "$TODAY" 1)" 08:00)"
  [ "$status" -eq 1 ]
  due '.enabled = false' '{}' 08:00
  [ "$status" -eq 1 ]
  due . '{"status": "running"}' 08:00
  [ "$status" -eq 1 ]
}
