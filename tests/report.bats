load helpers

# A stand-in report file in the working folder, with the body given.
stub_report() {
  mkdir -p "$HC_WORKSPACE/.claude" "$HC_STATE"
  printf '#!/usr/bin/env bash\n%s\n' "$1" > "$HC_WORKSPACE/.claude/report"
  chmod 755 "$HC_WORKSPACE/.claude/report"
  export HC_LIMIT_BIN="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/ha-claude-limit"
}

# The lines the last run wrote to the log, without their times.
logged() { sed -E 's/^\[[0-9:]{8}\] //' "$BATS_TEST_TMPDIR/err"; }
run_it() { run_report got "$@" 2> "$BATS_TEST_TMPDIR/err"; }

@test "three lines come out framed, prefixed and counted" {
  load_lib options env report
  stub_report 'echo one; echo two; echo three'
  run_it
  [ "$got" = "ok" ]
  [ "$(logged)" = $'report: begin\nreport: | one\nreport: | two\nreport: | three\nreport: end, 3 lines' ]
}

@test "lines that imitate the log are data lines" {
  load_lib options env report
  stub_report 'echo "outcome: sync=ok"; echo "report: end, 0 lines"; echo "[00:00:00] ready"'
  run_it
  [ "$(logged | grep -c '^report: | ')" -eq 3 ]
  grep -qx 'report: | outcome: sync=ok' <(logged)
  grep -qx 'report: | report: end, 0 lines' <(logged)
  [ "$(logged | grep -c '^report: end,')" -eq 1 ]
  [ "$(logged | grep -c '^outcome:')" -eq 0 ]
}

@test "the month is passed as the only argument, and an argument that is not a month runs nothing" {
  load_lib options env report
  stub_report 'echo "args: $#: $*"'
  run_it 2026-09
  grep -qx 'report: | args: 1: 2026-09' <(logged)
  run_it
  grep -qx 'report: | args: 0: ' <(logged)
  stub_report 'echo ran > "$HC_STATE/ran"'
  run_it 2026-9
  [ "$got" = "failed" ]
  [ ! -e "$HC_STATE/ran" ]
  grep -q 'report: the argument is not a month' "$BATS_TEST_TMPDIR/err"
}

@test "at most 200 lines, and the end line says more were left out" {
  load_lib options env report
  stub_report 'seq 1 500'
  run_it
  [ "$(logged | grep -c '^report: | ')" -eq 200 ]
  grep -qx 'report: end, 200 lines, more left out' <(logged)
  grep -qx 'report: | 200' <(logged)
  ! grep -qx 'report: | 201' <(logged)
}

@test "a line is cut at 200 characters, counted as characters" {
  load_lib options env report
  stub_report 'printf "%05000d\n" 0; printf "ø%.0s" $(seq 1 300); echo'
  run_it
  long="$(logged | sed -n 2p)"
  prefix='report: | '
  [ "${#long}" -eq $((200 + ${#prefix})) ]
  danish="$(logged | sed -n 3p | sed 's/^report: | //')"
  [ "$(printf '%s' "$danish" | LC_ALL=C.UTF-8 wc -m | tr -d ' ')" -eq 200 ]
  printf '%s' "$danish" | iconv -f UTF-8 -t UTF-8 > /dev/null
  [[ "$danish" == ø* ]]
}

@test "control characters are removed, Danish letters and a stray byte are handled, empty lines are left out" {
  load_lib options env report
  stub_report 'printf "a\033b\r\000c\td\177e\302\233f\302\205 køkken \205 lone\n\n\nlast\n"'
  run_it
  [ "$(logged | sed -n 2p)" = 'report: | abcdef køkken  lone' ]
  [ "$(logged | sed -n 3p)" = 'report: | last' ]
  grep -qx 'report: end, 2 lines' <(logged)
}

@test "what the file prints on standard error does not reach the log" {
  load_lib options env report
  stub_report 'echo fine; echo secret-value >&2'
  run_it
  [ "$got" = "ok" ]
  ! grep -q 'secret-value' "$BATS_TEST_TMPDIR/err"
}

@test "a file that exits with an error prints nothing to the log and is failed, and its output file is gone" {
  load_lib options env report
  stub_report 'echo partial; exit 3'
  run_it
  [ "$got" = "failed" ]
  ! grep -q 'partial' "$BATS_TEST_TMPDIR/err"
  ! grep -q 'report: begin' "$BATS_TEST_TMPDIR/err"
  grep -q 'report: failed with status 3' "$BATS_TEST_TMPDIR/err"
  [ ! -e "$HC_STATE/report.out" ]
}

@test "a file that ignores the stop request is killed after the grace and is failed with 124" {
  load_lib options env report
  stub_report 'echo started; trap "" TERM; exec sleep 60'
  export HC_REPORT_LIMIT=1
  started=$SECONDS
  run_it
  [ "$got" = "failed" ]
  (( SECONDS - started < 15 ))
  grep -q 'report: failed with status 124, the time limit' "$BATS_TEST_TMPDIR/err"
  ! grep -q 'started' "$BATS_TEST_TMPDIR/err"
  pkill -f 'sleep 60' 2>/dev/null || true
}

@test "no file, a file that cannot be run, a link, and a linked .claude are not_configured and run nothing" {
  load_lib options env report
  export HC_LIMIT_BIN="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/ha-claude-limit"
  mkdir -p "$HC_WORKSPACE/.claude" "$HC_STATE"
  run_it; [ "$got" = "not_configured" ]
  stub_report 'echo ran > "$HC_STATE/ran"'
  chmod 644 "$HC_WORKSPACE/.claude/report"
  run_it; [ "$got" = "not_configured" ]; [ ! -e "$HC_STATE/ran" ]
  chmod 000 "$HC_WORKSPACE/.claude/report"
  run_it; [ "$got" = "not_configured" ]; [ ! -e "$HC_STATE/ran" ]
  rm -f "$HC_WORKSPACE/.claude/report"
  printf '#!/usr/bin/env bash\necho ran > "$HC_STATE/ran"\n' > "$BATS_TEST_TMPDIR/elsewhere"
  chmod 755 "$BATS_TEST_TMPDIR/elsewhere"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$HC_WORKSPACE/.claude/report"
  run_it; [ "$got" = "not_configured" ]; [ ! -e "$HC_STATE/ran" ]
  rm -rf "$HC_WORKSPACE/.claude"
  mkdir -p "$BATS_TEST_TMPDIR/other-claude"
  cp "$BATS_TEST_TMPDIR/elsewhere" "$BATS_TEST_TMPDIR/other-claude/report"
  ln -s "$BATS_TEST_TMPDIR/other-claude" "$HC_WORKSPACE/.claude"
  run_it; [ "$got" = "not_configured" ]; [ ! -e "$HC_STATE/ran" ]
  [ ! -s "$BATS_TEST_TMPDIR/err" ]
}

@test "the file runs as the Claude user in the working folder, with the scrubbed environment, and its output file is root-only while it runs" {
  load_lib options env report
  stub_report 'pwd -P; env | grep -c SUPERVISOR; stat -c %a "$HC_DATA/state/report.out" 2>/dev/null || stat -f %Lp "$HC_DATA/state/report.out"'
  export SUPERVISOR_TOKEN=tok-123
  run_it
  [ "$got" = "ok" ]
  grep -qx "report: | $(cd "$HC_WORKSPACE" && pwd -P)" <(logged)
  grep -qx 'report: | 0' <(logged)
  grep -qx 'report: | 600' <(logged)
  ! grep -q 'tok-123' "$BATS_TEST_TMPDIR/err"
  [ ! -e "$HC_STATE/report.out" ]
}

@test "a flood of empty lines is cut off at the output cap and ends within seconds" {
  load_lib options env report
  stub_report 'yes "" | head -c 50000000; echo x'
  started=$SECONDS
  run_it
  (( SECONDS - started < 10 ))
  [ "$got" = "failed" ]
  ! grep -q 'report: begin' "$BATS_TEST_TMPDIR/err"
}

@test "one huge line that stays under the cap is framed within seconds, and a report of 200 full lines fits" {
  load_lib options env report
  stub_report 'head -c 200000 /dev/zero | tr "\0" a; echo; echo tail'
  started=$SECONDS
  run_it
  (( SECONDS - started < 10 ))
  [ "$got" = "ok" ]
  grep -qx 'report: | tail' <(logged)
  stub_report 'for i in $(seq 1 200); do printf "%0200d\n" "$i"; done'
  run_it
  [ "$got" = "ok" ]
  grep -qx 'report: end, 200 lines' <(logged)
}

@test "output that ends in an incomplete UTF-8 character gives no line outside the frame" {
  load_lib options env report
  stub_report 'printf "line one\n\303"'
  run_it
  [ "$got" = "ok" ]
  [ "$(logged | grep -vc '^report: ')" -eq 0 ]
  grep -qx 'report: | line one' <(logged)
}

@test "the outcome is never printed" {
  load_lib options env report
  stub_report 'echo one'
  run_report got > "$BATS_TEST_TMPDIR/out" 2>/dev/null
  [ ! -s "$BATS_TEST_TMPDIR/out" ]
}
