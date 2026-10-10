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
