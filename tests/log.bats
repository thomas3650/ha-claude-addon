load helpers
bats_require_minimum_version 1.5.0

@test "log writes to standard error by default" {
  load_lib
  run --separate-stderr log "hello"
  [ -z "$output" ]
  [[ "$stderr" == *"] hello" ]]
}

@test "log writes to HC_LOG when it is set, and not to standard error" {
  load_lib
  export HC_LOG="$BATS_TEST_TMPDIR/main.log"
  run --separate-stderr log "hello"
  [ -z "$stderr" ]
  grep -q '\] hello$' "$HC_LOG"
}

@test "log falls back to standard error when HC_LOG cannot be written" {
  load_lib
  export HC_LOG="$BATS_TEST_TMPDIR/missing/main.log"
  run --separate-stderr log "hello"
  [[ "$stderr" == *"] hello" ]]
  [ "${#stderr_lines[@]}" -eq 1 ]
}

@test "log_lines writes every line with the time, in one go, to standard error" {
  load_lib
  printf 'one\ntwo\n' | log_lines 2> "$BATS_TEST_TMPDIR/err"
  [ "$(wc -l < "$BATS_TEST_TMPDIR/err")" -eq 2 ]
  grep -qE '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] one$' "$BATS_TEST_TMPDIR/err"
  grep -qE '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] two$' "$BATS_TEST_TMPDIR/err"
}

@test "log_lines goes to HC_LOG when it is set, and writes nothing for no input" {
  load_lib
  export HC_LOG="$BATS_TEST_TMPDIR/log"
  printf 'one\n' | log_lines 2> "$BATS_TEST_TMPDIR/err"
  [ ! -s "$BATS_TEST_TMPDIR/err" ]
  grep -q '\] one$' "$HC_LOG"
  printf '' | log_lines
  [ "$(wc -l < "$HC_LOG")" -eq 1 ]
}
