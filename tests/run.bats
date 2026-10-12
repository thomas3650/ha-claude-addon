load helpers

# A stand-in for Claude Code, as in morning.bats: the mode on the first
# line of a file beside it, the result file to write on the second.
stub_claude() {
  STUB="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB" "$HC_WORKSPACE/.claude/agents" "$HC_RESULTS"
  touch "$HC_WORKSPACE/.claude/agents/house-check.md"
  TODAY="$(date +%F)"
  RESULT="$HC_RESULTS/house-check.json"
  printf '%s\n%s\n' "$1" "$RESULT" > "$STUB/mode"
  cat > "$STUB/claude" <<'EOT'
#!/usr/bin/env bash
here="$(dirname "$0")"
{ read -r mode; read -r file; } < "$here/mode"
printf '%s\n' "$@" > "$here/argv"
env > "$here/env"
pwd -P > "$here/cwd"
echo "stand-in output"
good='{"count":2,"verdict":"2 ting","text":"one\ntwo"}'
case "$mode" in
  write) printf '%s' "$good" > "$file" ;;
  error) printf '%s' "$good" > "$file"; exit 1 ;;
  bad) printf '{"count":2}' > "$file" ;;
  nothing) ;;
  hang) exec sleep 30 ;;
esac
EOT
  chmod +x "$STUB/claude"
  export HC_CLAUDE_BIN="$STUB/claude"
  export HC_LIMIT_BIN="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/ha-claude-limit"
  export SUPERVISOR_TOKEN=tok-123
  SENT="$BATS_TEST_TMPDIR/sent"; mkdir -p "$SENT"
  curl() {
    printf '%s\n' "$*" >> "$SENT/args"
    local a
    for a in "$@"; do [[ "$a" == @* ]] && cat "${a#@}" > "$SENT/body"; done
    cat > /dev/null
  }
}

@test "without the agent file the outcome is not_configured and nothing is run" {
  load_lib options env morning result run
  stub_claude write
  rm "$HC_WORKSPACE/.claude/agents/house-check.md"
  run_agent got house-check
  [ "$got" = "not_configured" ]
  [ ! -e "$STUB/argv" ]
}

@test "a name that is not a plain agent name, or is one of the add-on's own two, runs nothing" {
  load_lib options env morning result run
  stub_claude write
  touch "$HC_WORKSPACE/.claude/agents/chat.md" "$HC_WORKSPACE/.claude/agents/morning-briefing.md" \
        "$HC_WORKSPACE/.claude/agents/Abc.md" "$HC_WORKSPACE/.claude/agents/a.b.md" \
        "$HC_WORKSPACE/.claude/x.md" "$HC_WORKSPACE/.claude/agents/a b.md"
  long="$(printf 'a%.0s' {1..33})"
  touch "$HC_WORKSPACE/.claude/agents/$long.md"
  for name in chat morning-briefing ../x a.b Abc "" "a b" "$long" -x 1a; do
    got=""
    run_agent got "$name"
    [ "$got" = "not_configured" ]
    [ ! -e "$STUB/argv" ]
  done
  touch "$HC_WORKSPACE/.claude/agents/$(printf 'a%.0s' {1..32}).md"
  run_agent got "$(printf 'a%.0s' {1..32})"
  [ -e "$STUB/argv" ]
}

@test "an agent file that is a link is not run" {
  load_lib options env morning result run
  stub_claude write
  rm "$HC_WORKSPACE/.claude/agents/house-check.md"
  touch "$BATS_TEST_TMPDIR/elsewhere.md"
  ln -s "$BATS_TEST_TMPDIR/elsewhere.md" "$HC_WORKSPACE/.claude/agents/house-check.md"
  run_agent got house-check
  [ "$got" = "not_configured" ]
}

@test "a run that writes a good result is ok, and the result is raised" {
  load_lib options env morning result run
  stub_claude write
  run_agent got house-check
  [ "$got" = "ok" ]
  grep -q "/events/ha_claude_result" "$SENT/args"
  [ "$(jq -r '.agent + " " + (.count | tostring)' "$SENT/body")" = "house-check 2" ]
}

@test "the run is the named agent, without a terminal, with the date, the result path and the turn limit" {
  load_lib options env morning result run
  stub_claude write
  run_agent got house-check
  args="$(cat "$STUB/argv")"
  [[ "$args" == *$'-p\n'"Today is $TODAY. Your result file is $RESULT. Do your run."* ]]
  [[ "$args" == *$'--agent\nhouse-check'* ]]
  [[ "$args" == *$'--max-turns\n60'* ]]
  [[ "$args" == *"--no-session-persistence"* ]]
  [[ "$args" == *$'--permission-mode\ndefault'* ]]
  [[ "$args" != *"dangerously"* ]]
}

@test "the run is in the working folder, marked as unattended, with automatic memory off and without the token" {
  load_lib options env morning result run
  stub_claude write
  run_agent got house-check
  [ "$(cat "$STUB/cwd")" = "$(cd "$HC_WORKSPACE" && pwd -P)" ]
  grep -qx "HA_CLAUDE_UNATTENDED=house-check" "$STUB/env"
  grep -qx "CLAUDE_CODE_DISABLE_AUTO_MEMORY=1" "$STUB/env"
  run grep "tok-123\|SUPERVISOR" "$STUB/env"
  [ "$status" -eq 1 ]
}

@test "the run's output goes to a file of its own in the state folder and nowhere else" {
  load_lib options env morning result run
  stub_claude write
  run_agent got house-check > "$BATS_TEST_TMPDIR/out" 2> "$BATS_TEST_TMPDIR/err"
  [ ! -s "$BATS_TEST_TMPDIR/out" ]
  run grep "stand-in output" "$BATS_TEST_TMPDIR/err"
  [ "$status" -eq 1 ]
  [ "$(cat "$HC_STATE/run-house-check.log")" = "stand-in output" ]
  [ "$(stat -c %a "$HC_STATE/run-house-check.log" 2>/dev/null || stat -f %Lp "$HC_STATE/run-house-check.log")" = "600" ]
}

@test "a run that ends with an error is failed, also when it wrote a good result, and raises nothing" {
  load_lib options env morning result run
  stub_claude error
  run_agent got house-check
  [ "$got" = "failed" ]
  [ ! -e "$SENT/args" ]
}

@test "a run that writes nothing, or a result of another shape, is failed" {
  load_lib options env morning result run
  stub_claude nothing
  run_agent got house-check
  [ "$got" = "failed" ]
  stub_claude bad
  run_agent got house-check
  [ "$got" = "failed" ]
  [ ! -e "$SENT/args" ]
}

@test "a result from before the run is removed before the run starts" {
  load_lib options env morning result run
  stub_claude nothing
  printf '{"count":0,"verdict":"old","text":"old"}' > "$RESULT"
  run_agent got house-check
  [ "$got" = "failed" ]
  [ ! -e "$SENT/args" ]
  [ ! -e "$RESULT" ]
}

@test "a run that takes longer than the limit is timeout" {
  load_lib options env morning result run
  stub_claude hang
  set_options '{"run_timeout":1}'
  started=$SECONDS
  run_agent got house-check
  [ "$got" = "timeout" ]
  (( SECONDS - started < 10 ))
}

@test "the turn limit comes from the options, and a value that is not a number gives the default" {
  load_lib options env morning result run
  stub_claude write
  set_options '{"run_max_turns":12}'
  run_agent got house-check
  [[ "$(cat "$STUB/argv")" == *$'--max-turns\n12'* ]]
  set_options '{"run_max_turns":"many","run_timeout":"long"}'
  run_agent got house-check
  [ "$got" = "ok" ]
  [[ "$(cat "$STUB/argv")" == *$'--max-turns\n60'* ]]
}
