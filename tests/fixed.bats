load helpers

# Fixed jobs: files of the working folder's jobs/ placed in the jobs folder,
# and checked against it. The agents are made up.

setup_file() {
  export TZ=Europe/Copenhagen
}

fixed_setup() {
  load_lib options env layout result jobs fixed
  export HC_LIMIT_BIN="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/ha-claude-limit"
  ensure_layout
  mkdir -p "$HC_STATE" "$HC_WORKSPACE/jobs" "$HC_WORKSPACE/.claude/agents"
  # The tests run as one user: as_claude only records the call, then runs it.
  AS="$BATS_TEST_TMPDIR/as-claude"; : > "$AS"
  HOOK="$BATS_TEST_TMPDIR/hook"; : > "$HOOK"
  as_claude() { printf '%s\n' "$*" >> "$AS"; "$@"; }
  jobs_on_change() { printf '%s\n' "$1" >> "$HOOK"; }
  ALPHA='{"agent":"alpha-run","run_by":"automation","schedule":{"time":"06:30"},"task":"Test.","enabled":true}'
  printf '%s\n' "$ALPHA" > "$HC_WORKSPACE/jobs/alpha-run.json"
  touch "$HC_WORKSPACE/.claude/agents/alpha-run.md"
}

# copy_with <jq-update> - a copy of the repo file, changed, in $COPY.
copy_with() {
  COPY="$BATS_TEST_TMPDIR/copy.json"
  jq -c "$1" "$HC_WORKSPACE/jobs/alpha-run.json" > "$COPY"
}

@test "fixed_list prints the plain files with a job name, in order" {
  fixed_setup
  printf '%s\n' "${ALPHA//alpha-run/beta-run}" > "$HC_WORKSPACE/jobs/beta-run.json"
  printf '%s\n' "$ALPHA" > "$HC_WORKSPACE/jobs/Bad.json"
  ln -s alpha-run.json "$HC_WORKSPACE/jobs/gamma-run.json"
  mkdir "$HC_WORKSPACE/jobs/dir-run.json"
  run fixed_list
  [ "$status" -eq 0 ]
  [ "$output" = $'alpha-run\nbeta-run' ]
  fixed_is alpha-run
  if fixed_is gamma-run; then false; fi
  if fixed_is Bad; then false; fi
  if fixed_is nothing; then false; fi
}

@test "fixed_check passes the repo's file in its normal form" {
  fixed_setup
  run fixed_check alpha-run "$HC_WORKSPACE/jobs/alpha-run.json"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.end' <<<"$output")" = null ]
  [ "$(jq -r '.schedule.days | join(",")' <<<"$output")" = "mon,tue,wed,thu,fri,sat,sun" ]
  [ "$(jq -r '[.agent, .run_by, .schedule.time, .task, .enabled] | join("|")' <<<"$output")" = "alpha-run|automation|06:30|Test.|true" ]
}

@test "fixed_check refuses what is not the fixed shape" {
  fixed_setup
  copy_with '. + {type: "web"}'
  run fixed_check alpha-run "$COPY"; [ "$status" -eq 1 ]; [ "$output" = shape ]
  copy_with 'del(.task)'
  run fixed_check alpha-run "$COPY"; [ "$output" = shape ]
  copy_with '.enabled = "yes"'
  run fixed_check alpha-run "$COPY"; [ "$output" = shape ]
  printf '{"agent":"alpha-run","agent":"alpha-run","run_by":"automation","schedule":{"time":"06:30"},"task":"Test.","enabled":true}' > "$COPY"
  run fixed_check alpha-run "$COPY"; [ "$output" = shape ]
  printf 'not json' > "$COPY"
  run fixed_check alpha-run "$COPY"; [ "$output" = shape ]
}

@test "fixed_check refuses another agent, another run_by, a missing agent file" {
  fixed_setup
  copy_with '.agent = "beta-run"'
  run fixed_check alpha-run "$COPY"; [ "$status" -eq 1 ]; [ "$output" = agent ]
  copy_with '.run_by = "jobs"'
  run fixed_check alpha-run "$COPY"; [ "$status" -eq 1 ]; [ "$output" = run_by ]
  rm "$HC_WORKSPACE/.claude/agents/alpha-run.md"
  run fixed_check alpha-run "$HC_WORKSPACE/jobs/alpha-run.json"
  [ "$status" -eq 1 ]; [ "$output" = agent ]
}

@test "fixed_check refuses a bad schedule and a field that differs from the repo's" {
  fixed_setup
  copy_with '.schedule.time = "25:00"'
  run fixed_check alpha-run "$COPY"; [ "$output" = schedule ]
  copy_with '.schedule.days = ["mon", "mon"]'
  run fixed_check alpha-run "$COPY"; [ "$output" = schedule ]
  copy_with '.task = "Other."'
  run fixed_check alpha-run "$COPY"; [ "$status" -eq 1 ]; [ "$output" = differs ]
  copy_with '.schedule.time = "07:30"'
  run fixed_check alpha-run "$COPY"; [ "$output" = differs ]
  # Days given in full or in another order are the same schedule; enabled is the switch's.
  copy_with '.schedule.days = ["sun","sat","fri","thu","wed","tue","mon"] | .enabled = false'
  run fixed_check alpha-run "$COPY"; [ "$status" -eq 0 ]
}

@test "fixed_place writes the file as the Claude user, beside it and then moved" {
  fixed_setup
  fixed_place
  [ "$(jq -cS . "$HC_JOBS/alpha-run.json")" = "$(jq -cS . <<<"$ALPHA")" ]
  grep -q 'alpha-run.json' "$AS"
  grep -q 'mv -f' "$AS"
  grep -q '\.new' "$AS"
  [ ! -e "$HC_JOBS/alpha-run.json.new" ]
  [ "$(cat "$HC_JOB_STATE/fixed.list")" = alpha-run ]
  grep -qx alpha-run "$HOOK"
  # A second placing changes nothing: no write, no hook.
  : > "$AS"; : > "$HOOK"
  fixed_place
  if grep -q 'mv -f' "$AS"; then false; fi
  [ ! -s "$HOOK" ]
}

@test "fixed_place keeps a placed file's enabled" {
  fixed_setup
  fixed_place
  jq -c '.enabled = false' "$HC_JOBS/alpha-run.json" > "$BATS_TEST_TMPDIR/off" && mv "$BATS_TEST_TMPDIR/off" "$HC_JOBS/alpha-run.json"
  fixed_place
  [ "$(jq -r '.enabled' "$HC_JOBS/alpha-run.json")" = false ]
}

@test "fixed_place puts the repo's schedule back and keeps enabled" {
  fixed_setup
  fixed_place
  jq -c '.enabled = false | .schedule.time = "01:00"' "$HC_JOBS/alpha-run.json" > "$BATS_TEST_TMPDIR/x" && mv "$BATS_TEST_TMPDIR/x" "$HC_JOBS/alpha-run.json"
  fixed_place
  [ "$(jq -r '.schedule.time' "$HC_JOBS/alpha-run.json")" = "06:30" ]
  [ "$(jq -r '.enabled' "$HC_JOBS/alpha-run.json")" = false ]
}

@test "fixed_place keeps no enabled from a file that is not a valid fixed file" {
  fixed_setup
  fixed_place
  jq -c '.enabled = false | . + {extra: 1}' "$HC_JOBS/alpha-run.json" > "$BATS_TEST_TMPDIR/x" && mv "$BATS_TEST_TMPDIR/x" "$HC_JOBS/alpha-run.json"
  fixed_place
  [ "$(jq -cS . "$HC_JOBS/alpha-run.json")" = "$(jq -cS . <<<"$ALPHA")" ]
  [ -z "$(ls "$HC_JOBS/ended")" ]
}

@test "fixed_place moves a chat file under a fixed name to ended/ and says so" {
  fixed_setup
  jq -n '{type: "web", task: "Find a kettle.", schedule: {every_hours: 4}, end: "2026-12-01", enabled: true, created: "2026-11-18"}' \
    > "$HC_JOBS/alpha-run.json"
  fixed_place
  [ "$(jq -r .type "$HC_JOBS/ended/alpha-run.json")" = web ]
  [ "$(jq -cS . "$HC_JOBS/alpha-run.json")" = "$(jq -cS . <<<"$ALPHA")" ]
  [ "$(jq -r '.enabled' "$HC_JOBS/alpha-run.json")" = true ]
}

@test "fixed_place logs the move of a chat file" {
  fixed_setup
  LOGGED="$BATS_TEST_TMPDIR/logged"; : > "$LOGGED"
  log() { printf '%s\n' "$*" >> "$LOGGED"; }
  jq -n '{type: "all", task: "T", schedule: {time: "05:00"}, end: "2026-12-01", enabled: false, created: "2026-11-18"}' \
    > "$HC_JOBS/alpha-run.json"
  fixed_place
  grep -q 'alpha-run was a job of the chat.s; its file is moved to ended/' "$LOGGED"
}

@test "fixed_place deletes the placed file of a name gone from the repo, with its state" {
  fixed_setup
  fixed_place
  printf '{"status":"ok"}\n' > "$HC_JOB_STATE/alpha-run.json"
  : > "$HOOK"
  rm "$HC_WORKSPACE/jobs/alpha-run.json"
  fixed_place
  [ ! -e "$HC_JOBS/alpha-run.json" ]
  [ -z "$(ls "$HC_JOBS/ended")" ]
  [ ! -e "$HC_JOB_STATE/alpha-run.json" ]
  if grep -qx alpha-run "$HC_JOB_STATE/fixed.list"; then false; fi
  grep -qx alpha-run "$HOOK"
}

@test "fixed_place does not place a file the working folder's own check refuses" {
  fixed_setup
  jq -c '.run_by = "jobs"' "$HC_WORKSPACE/jobs/alpha-run.json" > "$BATS_TEST_TMPDIR/x" && mv "$BATS_TEST_TMPDIR/x" "$HC_WORKSPACE/jobs/alpha-run.json"
  fixed_place
  [ ! -e "$HC_JOBS/alpha-run.json" ]
}

@test "fixed_place replaces a link under a fixed name by the file" {
  fixed_setup
  ln -s /etc/hostname "$HC_JOBS/alpha-run.json"
  fixed_place
  [ ! -L "$HC_JOBS/alpha-run.json" ]
  [ "$(jq -cS . "$HC_JOBS/alpha-run.json")" = "$(jq -cS . <<<"$ALPHA")" ]
}
