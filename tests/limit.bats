load helpers
LIMIT="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/ha-claude-limit"

@test "the command's own exit status is passed on" {
  run "$LIMIT" 10 true
  [ "$status" -eq 0 ]
  run "$LIMIT" 10 bash -c 'exit 7'
  [ "$status" -eq 7 ]
}

@test "a command that ends early is not waited for" {
  started=$SECONDS
  run "$LIMIT" 30 true
  [ "$status" -eq 0 ]
  (( SECONDS - started < 5 ))
}

@test "a command that runs too long is asked to stop, and the status is 124" {
  started=$SECONDS
  run "$LIMIT" 1 sleep 20
  [ "$status" -eq 124 ]
  (( SECONDS - started < 8 ))
}

@test "a command that ignores the request is killed after the grace time" {
  started=$SECONDS
  HC_LIMIT_GRACE=1 run "$LIMIT" 1 bash -c 'trap "" TERM; while :; do :; done'
  [ "$status" -eq 124 ]
  (( SECONDS - started < 10 ))
}

@test "the command's arguments are passed on unchanged" {
  run "$LIMIT" 10 printf '%s|' "a b" "c"
  [ "$output" = "a b|c|" ]
}

@test "what the command started is stopped with it" {
  command -v setsid >/dev/null || skip "no setsid here"
  mark="$BATS_TEST_TMPDIR/child-alive"
  run "$LIMIT" 1 bash -c "( sleep 4; touch '$mark' ) & wait"
  [ "$status" -eq 124 ]
  sleep 5
  [ ! -e "$mark" ]
}
