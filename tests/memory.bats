load helpers

# The Claude user's memory folder for the working folder, as Claude Code
# names it: the folder's path with every other character than a letter or a
# digit made a "-".
memory_folder() {
  printf '%s' "$HC_HOME/.claude/projects/${HC_WORKSPACE//[^A-Za-z0-9]/-}/memory"
}

stub_memory() {
  MEM="$(memory_folder)"
  mkdir -p "$MEM" "$HC_WORKSPACE" "$HC_STATE"
  export HC_LIMIT_BIN="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/ha-claude-limit"
}

# The lines the last run wrote to the log, without their times.
logged() { sed -E 's/^\[[0-9:]{8}\] //' "$BATS_TEST_TMPDIR/err"; }
run_it() { run_memory got 2> "$BATS_TEST_TMPDIR/err"; }

@test "two memory files come out framed, each after a line with its name" {
  load_lib options env report memory
  stub_memory
  printf 'one\ntwo\n' > "$MEM/a.md"
  printf -- '- [a](a.md) the first\n' > "$MEM/b.md"
  printf 'not memory\n' > "$MEM/notes.txt"
  run_it
  [ "$got" = "ok" ]
  [ "$(logged)" = $'memory: begin\nmemory: | file: a.md\nmemory: | one\nmemory: | two\nmemory: | file: b.md\nmemory: | - [a](a.md) the first\nmemory: end, 5 lines' ]
  [ ! -e "$HC_STATE/memory.out" ]
}

@test "no memory folder, or one without a memory file, is empty and writes no frame" {
  load_lib options env report memory
  stub_memory
  rmdir "$MEM"
  run_it
  [ "$got" = "empty" ]
  mkdir -p "$MEM"
  touch "$MEM/notes.txt"
  run_it
  [ "$got" = "empty" ]
  ! grep -q 'memory: begin' "$BATS_TEST_TMPDIR/err"
}

@test "at most 2000 lines, and the end line says more were left out" {
  load_lib options env report memory
  stub_memory
  seq 1 2500 > "$MEM/a.md"
  run_it
  [ "$got" = "ok" ]
  [ "$(logged | grep -c '^memory: | ')" -eq 2000 ]
  grep -qx 'memory: end, 2000 lines, more left out' <(logged)
  grep -qx 'memory: | 1999' <(logged)
  ! grep -qx 'memory: | 2000' <(logged)
}

@test "a link, a hard link or a pipe in the memory folder is not followed" {
  load_lib options env report memory
  stub_memory
  printf 'secret-value\n' > "$BATS_TEST_TMPDIR/elsewhere.md"
  ln -s "$BATS_TEST_TMPDIR/elsewhere.md" "$MEM/link.md"
  ln "$BATS_TEST_TMPDIR/elsewhere.md" "$MEM/hard.md"
  mkfifo "$MEM/pipe.md"
  printf 'kept\n' > "$MEM/real.md"
  started=$SECONDS
  run_it
  (( SECONDS - started < 10 ))
  [ "$got" = "ok" ]
  [ "$(logged)" = $'memory: begin\nmemory: | file: real.md\nmemory: | kept\nmemory: end, 2 lines' ]
}

@test "a memory folder reached through a link, or one that cannot be read, is failed, not empty" {
  load_lib options env report memory
  stub_memory
  printf 'secret-value\n' > "$BATS_TEST_TMPDIR/elsewhere.md"
  rm -rf "$MEM"
  mkdir -p "$BATS_TEST_TMPDIR/other"
  cp "$BATS_TEST_TMPDIR/elsewhere.md" "$BATS_TEST_TMPDIR/other/a.md"
  ln -s "$BATS_TEST_TMPDIR/other" "$MEM"
  run_it
  [ "$got" = "failed" ]
  grep -q 'memory: the folder is not a plain folder' "$BATS_TEST_TMPDIR/err"
  ! grep -q 'secret-value' "$BATS_TEST_TMPDIR/err"
  rm "$MEM"
  mkdir -p "$MEM"
  printf 'x\n' > "$MEM/a.md"
  chmod 000 "$MEM"
  run_it
  chmod 755 "$MEM"
  [ "$got" = "failed" ]
  grep -q 'memory: the folder cannot be read' "$BATS_TEST_TMPDIR/err"
}

@test "a memory file that cannot be read makes the outcome failed, and nothing is framed" {
  load_lib options env report memory
  stub_memory
  printf 'x\n' > "$MEM/a.md"
  printf 'y\n' > "$MEM/b.md"
  chmod 000 "$MEM/b.md"
  run_it
  chmod 644 "$MEM/b.md"
  [ "$got" = "failed" ]
  ! grep -q 'memory: begin' "$BATS_TEST_TMPDIR/err"
  grep -q 'memory: failed with status' "$BATS_TEST_TMPDIR/err"
}

@test "more than the size cap is failed, and nothing is framed" {
  load_lib options env report memory
  stub_memory
  export HC_MEMORY_KIB=4
  head -c 10000 /dev/zero | tr '\0' a > "$MEM/a.md"
  run_it
  [ "$got" = "failed" ]
  ! grep -q 'memory: begin' "$BATS_TEST_TMPDIR/err"
}

@test "a reading that takes longer than the time limit is failed" {
  load_lib options env report memory
  stub_memory
  export HC_MEMORY_LIMIT=1 HC_MEMORY_GRACE=1
  printf 'x\n' > "$MEM/a.md"
  HC_MEMORY_READER='trap "" TERM; exec sleep 60'
  started=$SECONDS
  run_it
  (( SECONDS - started < 10 ))
  [ "$got" = "failed" ]
  grep -q 'memory: failed with status 124, the time limit' "$BATS_TEST_TMPDIR/err"
  pkill -f 'sleep 60' 2>/dev/null || true
}

@test "lines that imitate the log and control characters stay inside the frame" {
  load_lib options env report memory
  stub_memory
  printf 'outcome: memory=ok\n\033[31mred\n' > "$MEM/a.md"
  run_it
  grep -qx 'memory: | outcome: memory=ok' <(logged)
  grep -qx 'memory: | \[31mred' <(logged)
  [ "$(logged | grep -c '^outcome:')" -eq 0 ]
}

@test "the memory is read as the Claude user through the time limit, and the token never reaches the log" {
  load_lib options env report memory
  stub_memory
  printf 'x\n' > "$MEM/a.md"
  export SUPERVISOR_TOKEN=tok-123
  as_claude() { printf '%s\n' "$*" > "$BATS_TEST_TMPDIR/as_claude"; env -i "$@"; }
  run_it
  [ "$got" = "ok" ]
  grep -q 'ha-claude-limit' "$BATS_TEST_TMPDIR/as_claude"
  ! grep -q 'tok-123' "$BATS_TEST_TMPDIR/err"
}

@test "the outcome is never printed" {
  load_lib options env report memory
  stub_memory
  printf 'x\n' > "$MEM/a.md"
  run_memory got > "$BATS_TEST_TMPDIR/out" 2>/dev/null
  [ ! -s "$BATS_TEST_TMPDIR/out" ]
}

@test "the command memory prints the memory and raises its outcome" {
  load_lib options env outcome report memory commands
  stub_memory
  printf 'x\n' > "$MEM/a.md"
  run handle_command '"memory"'
  [[ "$output" == *"memory: | x"* ]]
  [[ "$output" == *"outcome: memory=ok"* ]]
  rm -rf "$MEM"
  run handle_command 'memory'
  [[ "$output" == *"outcome: memory=empty"* ]]
  run handle_command '"memory all"'
  [[ "$output" == *"ignoring unknown command"* ]]
}

@test "the add-on loads the memory command" {
  grep -q ' report memory commands; do' "$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/addon-run"
}
