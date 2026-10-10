load helpers
bats_require_minimum_version 1.5.0

managed_setup() {
  load_lib managed
  export HC_MANAGED_DIR="$BATS_TEST_TMPDIR/etc-claude-code"
  mkdir -p "$HC_WORKSPACE/.claude"
  SRC="$HC_WORKSPACE/.claude/managed-settings.json"
  DST="$HC_MANAGED_DIR/managed-settings.json"
}

@test "a valid file in the working folder is installed" {
  managed_setup
  echo '{"a":1}' > "$SRC"
  run install_managed_settings
  [ "$status" -eq 0 ]
  [ "$(cat "$DST")" = '{"a":1}' ]
}

@test "nothing is installed when the working folder has no file" {
  managed_setup
  run install_managed_settings
  [ "$status" -eq 0 ]
  [ ! -e "$DST" ]
}

@test "a broken file never replaces a good one, and says so" {
  managed_setup
  echo '{"a":1}' > "$SRC"
  install_managed_settings
  echo '{ broken' > "$SRC"
  run --separate-stderr install_managed_settings
  [ "$status" -eq 0 ]
  [ "$(cat "$DST")" = '{"a":1}' ]
  [[ "$stderr" == *"keeping the last good copy"* ]]
}

@test "a file that is JSON but not an object is treated as broken" {
  managed_setup
  echo '{"a":1}' > "$SRC"
  install_managed_settings
  echo '[1,2]' > "$SRC"
  install_managed_settings
  [ "$(cat "$DST")" = '{"a":1}' ]
}

@test "the last good copy is installed again after the install folder is lost" {
  managed_setup
  echo '{"a":1}' > "$SRC"
  install_managed_settings
  rm -rf "$HC_MANAGED_DIR"
  echo '{ broken' > "$SRC"
  install_managed_settings
  [ "$(cat "$DST")" = '{"a":1}' ]
}

@test "removing the file from the working folder removes the installed one" {
  managed_setup
  echo '{"a":1}' > "$SRC"
  install_managed_settings
  rm "$SRC"
  run --separate-stderr install_managed_settings
  [ ! -e "$DST" ]
  [ ! -e "$HC_STATUS/managed-settings.json" ]
}

@test "a link out of the working folder is refused like a broken file" {
  managed_setup
  echo '{"a":1}' > "$SRC"
  install_managed_settings
  rm "$SRC"
  echo '{"deploy_key":"secret"}' > "$BATS_TEST_TMPDIR/outside.json"
  ln -s "$BATS_TEST_TMPDIR/outside.json" "$SRC"
  run --separate-stderr install_managed_settings
  [ "$status" -eq 0 ]
  [ "$(cat "$DST")" = '{"a":1}' ]
  [[ "$stderr" == *"keeping the last good copy"* ]]
}

@test "a linked .claude folder is refused, and nothing is installed without a good copy" {
  managed_setup
  rmdir "$HC_WORKSPACE/.claude"
  mkdir "$BATS_TEST_TMPDIR/elsewhere"
  echo '{"deploy_key":"secret"}' > "$BATS_TEST_TMPDIR/elsewhere/managed-settings.json"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$HC_WORKSPACE/.claude"
  run --separate-stderr install_managed_settings
  [ "$status" -eq 0 ]
  [ ! -e "$DST" ]
}

@test "two JSON values in one file are treated as broken" {
  managed_setup
  echo '{"a":1}' > "$SRC"
  install_managed_settings
  echo '[] {"b":2}' > "$SRC"
  install_managed_settings
  [ "$(cat "$DST")" = '{"a":1}' ]
}
