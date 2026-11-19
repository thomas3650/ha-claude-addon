load helpers

# ha-claude-job-check: the add-on's job checks as a command, for the job
# server, which runs as the Claude user. Every example of the job schemas
# gives the same normal form or word through it as through the functions.

CMD="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/ha-claude-job-check"
SCHEMAS="$BATS_TEST_DIRNAME/../ha-claude/schemas"

# check <args...> < file - the command, run from the source tree.
check() { HC_LIB="$LIB" "$CMD" "$@"; }


# The working folder as the add-on has it: the repo file under its agent's
# name, and the agent's file. A repo example is its own repo file, so a valid
# one is the same as itself.
repo_setup() {
  local file="$1" name="$2"
  load_lib
  mkdir -p "$HC_WORKSPACE/jobs" "$HC_WORKSPACE/.claude/agents"
  cp "$file" "$HC_WORKSPACE/jobs/$name.json"
  : > "$HC_WORKSPACE/.claude/agents/$name.md"
}

repo_name() { jq -r '.agent // "plant-check" | strings' "$1" 2>/dev/null || echo plant-check; }

@test "the command is executable in git, and the image copies rootfs" {
  [ -x "$CMD" ]
  [ "$(git -C "$BATS_TEST_DIRNAME/.." ls-files -s -- ha-claude/rootfs/usr/local/bin/ha-claude-job-check | cut -c1-6)" = 100755 ]
  grep -qF 'COPY rootfs/ /' "$BATS_TEST_DIRNAME/../ha-claude/Dockerfile"
}

@test "chat examples give the functions' normal form or word" {
  load_lib options env result jobs fixed
  local f out want rc wrc
  for f in "$SCHEMAS"/examples/valid/job-chat/*.json "$SCHEMAS"/examples/invalid/job-chat/*.json; do
    want="$(job_check example "$f" 2026-11-18 0)" && wrc=0 || wrc=$?
    out="$(check --origin chat --since 2026-11-18 --others 0 --name example < "$f")" && rc=0 || rc=$?
    [ "$rc" -eq "$wrc" ] || { echo "$f: exit $rc, wanted $wrc"; false; }
    [ "$out" = "$want" ] || { echo "$f: gave $out, wanted $want"; false; }
  done
}

@test "repo examples give the functions' normal form or word" {
  load_lib options env result jobs fixed
  local f out want rc wrc name
  for f in "$SCHEMAS"/examples/valid/job-repo/*.json "$SCHEMAS"/examples/invalid/job-repo/*.json; do
    name="$(repo_name "$f")"
    want="$(_fixed_normal "$name" "$f")" && wrc=0 || wrc=$?
    rm -rf "$HC_WORKSPACE"; repo_setup "$f" "$name"
    out="$(check --origin repo --since 2026-11-18 --others 0 --name "$name" < "$f")" && rc=0 || rc=$?
    [ "$rc" -eq "$wrc" ] || { echo "$f: exit $rc, wanted $wrc"; false; }
    [ "$out" = "$want" ] || { echo "$f: gave $out, wanted $want"; false; }
  done
}

@test "a repo file is compared with the working folder's, and differs where it is not the same" {
  local f="$SCHEMAS/examples/valid/job-repo/briefing.json" name
  name="$(repo_name "$f")"
  repo_setup "$f" "$name"
  run check --origin repo --since 2026-11-18 --others 0 --name "$name" < "$f"
  [ "$status" -eq 0 ]
  jq '.timeout = 5' "$f" > "$BATS_TEST_TMPDIR/changed.json"
  run check --origin repo --since 2026-11-18 --others 0 --name "$name" < "$BATS_TEST_TMPDIR/changed.json"
  [ "$status" -eq 1 ]
  [ "$output" = differs ]
  # A name with no repo file is not a repo job.
  run check --origin repo --since 2026-11-18 --others 0 --name nothing-here < "$f"
  [ "$status" -eq 1 ]
  [ "$output" = shape ]
}

@test "a chat file that carries the name of a repo file is the shape, and the limit and the 28 days hold" {
  local f="$SCHEMAS/examples/valid/job-chat/daily-web.json"
  repo_setup "$SCHEMAS/examples/valid/job-repo/briefing.json" briefing
  run check --origin chat --since 2026-11-18 --others 0 --name briefing < "$f"
  [ "$status" -eq 1 ]; [ "$output" = shape ]
  run check --origin chat --since 2026-11-18 --others 10 --name example < "$f"
  [ "$status" -eq 1 ]; [ "$output" = limit ]
  run check --origin chat --since 2020-01-01 --others 0 --name example < "$f"
  [ "$status" -eq 1 ]; [ "$output" = end ]
  run check --origin chat --since 2026-11-18 --others 0 --name Bad_Name < "$f"
  [ "$status" -eq 1 ]; [ "$output" = name ]
}

@test "input that is not a job, or too large, gives shape" {
  run check --origin chat --since 2026-11-18 --others 0 --name example <<< 'not json'
  [ "$status" -eq 1 ]; [ "$output" = shape ]
  head -c 20000 /dev/zero | tr '\0' ' ' > "$BATS_TEST_TMPDIR/big.json"
  run check --origin chat --since 2026-11-18 --others 0 --name example < "$BATS_TEST_TMPDIR/big.json"
  [ "$status" -eq 1 ]; [ "$output" = shape ]
}

@test "it works as the test user with the job state unreadable, and reads nothing there" {
  local f="$SCHEMAS/examples/valid/job-chat/daily-web.json"
  export HC_STATE="$BATS_TEST_TMPDIR/state" HC_JOB_STATE="$BATS_TEST_TMPDIR/state/jobs"
  mkdir -p "$HC_JOB_STATE"
  echo secret > "$HC_JOB_STATE/example.status"
  chmod 000 "$HC_JOB_STATE" "$HC_STATE"
  run check --origin chat --since 2026-11-18 --others 0 --name example < "$f"
  chmod 755 "$HC_STATE"; chmod 755 "$HC_JOB_STATE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r .name <<<"$output")" = example ]
  # Nothing of the state leaked or was touched.
  [ "$(cat "$HC_JOB_STATE/example.status")" = secret ]
  [ -z "$(find "$HC_STATE" -newer "$f" -type f ! -name example.status)" ]
}

@test "it leaves no temporary file behind" {
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
  check --origin chat --since 2026-11-18 --others 0 --name example < "$SCHEMAS/examples/valid/job-chat/daily-web.json" >/dev/null
  check --origin chat --since 2026-11-18 --others 0 --name example <<< x >/dev/null || true
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "bad arguments exit 2 with a usage line" {
  local a
  for a in "" "--origin chat" "--origin web --since 2026-11-18 --others 0 --name x" \
           "--origin chat --since yesterday --others 0 --name x" \
           "--origin chat --since 2026-11-18 --others -1 --name x" \
           "--origin chat --since 2026-11-18 --others 0" \
           "--origin chat --since 2026-11-18 --others 0 --name x --extra" \
           "--origin chat --since 2026-11-18 --others 0 --name"; do
    # shellcheck disable=SC2086
    run bash -c 'HC_LIB="$1" "$2" '"$a"' 2>&1 >/dev/null </dev/null' _ "$LIB" "$CMD"
    [ "$status" -eq 2 ] || { echo "[$a] exit $status"; false; }
    [[ "$output" == usage:* ]] || { echo "[$a] $output"; false; }
  done
}

@test "a writer that stalls is the shape, after the wait and not before" {
  local start=$SECONDS
  run env HC_LIB="$LIB" HC_JOB_WAIT=1 "$CMD" --origin chat --since 2026-11-18 --others 0 --name example \
    < <( { echo "{"; sleep 8; } 2>/dev/null 3>&- )
  [ "$status" -eq 1 ]
  [ "$output" = shape ]
  (( SECONDS - start < 6 ))
}
