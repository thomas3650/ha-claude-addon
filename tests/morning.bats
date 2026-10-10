load helpers

# A stand-in for Claude Code. as_claude scrubs the environment, so the
# stand-in reads what to do from a file beside itself: the mode on the first
# line, the file to write on the second.
stub_claude() {
  STUB="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB" "$HC_WORKSPACE/.claude/agents" "$HC_HANDOVER"
  touch "$HC_WORKSPACE/.claude/agents/morning-briefing.md"
  TODAY="$(date +%F)"
  TODAY_FILE="$HC_HANDOVER/$TODAY.md"
  printf '%s\n%s\n' "$1" "$TODAY_FILE" > "$STUB/mode"
  cat > "$STUB/claude" <<'EOT'
#!/usr/bin/env bash
here="$(dirname "$0")"
{ read -r mode; read -r file; } < "$here/mode"
printf '%s\n' "$@" > "$here/argv"
env > "$here/env"
pwd -P > "$here/cwd"
echo "stand-in output"
case "$mode" in
  write) printf '# written\n' > "$file" ;;
  error) printf '# written\n' > "$file"; exit 1 ;;
  nothing) ;;
  hang) exec sleep 30 ;;
esac
EOT
  chmod +x "$STUB/claude"
  export HC_CLAUDE_BIN="$STUB/claude"
  export HC_LIMIT_BIN="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/ha-claude-limit"
}

@test "without the agent file the outcome is not_configured and nothing is run" {
  load_lib options env morning
  stub_claude write
  rm "$HC_WORKSPACE/.claude/agents/morning-briefing.md"
  run_morning got
  [ "$got" = "not_configured" ]
  [ ! -e "$STUB/argv" ]
}

@test "a run that writes today's file is ok" {
  load_lib options env morning
  stub_claude write
  run_morning got
  [ "$got" = "ok" ]
}

@test "the run is the named agent, without a terminal, with the date, the file and the turn limit" {
  load_lib options env morning
  stub_claude write
  run_morning got
  args="$(cat "$STUB/argv")"
  [[ "$args" == *$'-p\n'*"Today is $TODAY."* ]]
  [[ "$args" == *"$TODAY_FILE"* ]]
  [[ "$args" == *$'--agent\nmorning-briefing'* ]]
  [[ "$args" == *$'--max-turns\n40'* ]]
  [[ "$args" == *$'--permission-mode\ndefault'* ]]
  [[ "$args" != *"dangerously"* ]]
}

@test "the run is in the working folder, with automatic memory off and without the token" {
  load_lib options env morning
  stub_claude write
  export SUPERVISOR_TOKEN=tok-123
  run_morning got
  [ "$(cat "$STUB/cwd")" = "$(cd "$HC_WORKSPACE" && pwd -P)" ]
  grep -qx "CLAUDE_CODE_DISABLE_AUTO_MEMORY=1" "$STUB/env"
  run grep "tok-123\|SUPERVISOR" "$STUB/env"
  [ "$status" -eq 1 ]
}

@test "the run's output goes to a file in the state folder and nowhere else" {
  load_lib options env morning
  stub_claude write
  run_morning got > "$BATS_TEST_TMPDIR/out" 2> "$BATS_TEST_TMPDIR/err"
  [ ! -s "$BATS_TEST_TMPDIR/out" ]
  run grep "stand-in output" "$BATS_TEST_TMPDIR/err"
  [ "$status" -eq 1 ]
  [ "$(cat "$HC_STATE/morning.log")" = "stand-in output" ]
  [ "$(stat -c %a "$HC_STATE/morning.log" 2>/dev/null || stat -f %Lp "$HC_STATE/morning.log")" = "600" ]
}

@test "a run that ends with an error is failed, also when it wrote the file" {
  load_lib options env morning
  stub_claude error
  run_morning got
  [ "$got" = "failed" ]
}

@test "a run that writes nothing is failed" {
  load_lib options env morning
  stub_claude nothing
  run_morning got
  [ "$got" = "failed" ]
}

@test "a file from earlier in the day that the run did not touch is failed" {
  load_lib options env morning
  stub_claude nothing
  printf '# earlier\n' > "$TODAY_FILE"
  touch -t 202001010000 "$TODAY_FILE"
  run_morning got
  [ "$got" = "failed" ]
  [ "$(cat "$TODAY_FILE")" = "# earlier" ]
}

@test "a run that takes longer than the limit is timeout" {
  load_lib options env morning
  stub_claude hang
  set_options '{"morning_timeout":1}'
  started=$SECONDS
  run_morning got
  [ "$got" = "timeout" ]
  (( SECONDS - started < 10 ))
}

@test "the turn limit comes from the options, and a value that is not a number gives the default" {
  load_lib options env morning
  stub_claude write
  set_options '{"morning_max_turns":12}'
  run_morning got
  [[ "$(cat "$STUB/argv")" == *$'--max-turns\n12'* ]]
  set_options '{"morning_max_turns":"many","morning_timeout":"long"}'
  run_morning got
  [ "$got" = "ok" ]
  [[ "$(cat "$STUB/argv")" == *$'--max-turns\n40'* ]]
}

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
