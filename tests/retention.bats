load helpers
bats_require_minimum_version 1.5.0

retention_setup() {
  load_lib retention
  mkdir -p "$HC_HANDOVER"
}

@test "_days_ago prints a date" {
  retention_setup
  run _days_ago 30
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

@test "a handover file dated more than 30 days ago is removed, and the log says so" {
  retention_setup
  old="$HC_HANDOVER/$(_days_ago 31).md"
  touch "$old"
  run --separate-stderr prune_handover
  [ "$status" -eq 0 ]
  [ ! -e "$old" ]
  [[ "$stderr" == *"handover: removed 1 file(s)"* ]]
}

@test "files dated 30 days ago and newer are kept, silently" {
  retention_setup
  edge="$HC_HANDOVER/$(_days_ago 30).md"
  new="$HC_HANDOVER/$(_days_ago 1).md"
  touch "$edge" "$new"
  run --separate-stderr prune_handover
  [ -e "$edge" ]
  [ -e "$new" ]
  [ -z "$stderr" ]
}

@test "a file is judged by the date in its name, not by when it was changed" {
  retention_setup
  old="$HC_HANDOVER/$(_days_ago 40).md"
  echo "edited today" > "$old"
  prune_handover
  [ ! -e "$old" ]
}

@test "anything that is not a dated handover file is left alone" {
  retention_setup
  touch "$HC_HANDOVER/notes.md" "$HC_HANDOVER/1999-01-01.txt" "$BATS_TEST_TMPDIR/target"
  mkdir "$HC_HANDOVER/1999-01-02.md"
  ln -s "$BATS_TEST_TMPDIR/target" "$HC_HANDOVER/1999-01-03.md"
  prune_handover
  [ -e "$HC_HANDOVER/notes.md" ]
  [ -e "$HC_HANDOVER/1999-01-01.txt" ]
  [ -d "$HC_HANDOVER/1999-01-02.md" ]
  [ -L "$HC_HANDOVER/1999-01-03.md" ]
  [ -e "$BATS_TEST_TMPDIR/target" ]
}

@test "an empty or missing handover folder is not an error" {
  load_lib retention
  run prune_handover
  [ "$status" -eq 0 ]
}

@test "a number of days that is not a whole number deletes nothing" {
  retention_setup
  old="$HC_HANDOVER/$(_days_ago 400).md"
  touch "$old"
  HC_HANDOVER_DAYS=-5 run prune_handover
  [ -e "$old" ]
  HC_HANDOVER_DAYS=soon run prune_handover
  [ -e "$old" ]
}
