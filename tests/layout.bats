load helpers

@test "ensure_layout creates the folders" {
  load_lib layout
  ensure_layout
  [ -d "$HC_HOME" ] && [ -d "$HC_HANDOVER" ] && [ -d "$HC_STATE" ] && [ -d "$HC_WORKSPACE" ]
}

@test "as root, the workspace is not writable by the Claude user" {
  [ "$(id -u)" -eq 0 ] || skip "needs root; runs in the container test"
  HC_USER=claude
  load_lib layout
  ensure_layout
  [ "$(stat -c %U "$HC_WORKSPACE")" = "root" ]
  [ "$(stat -c %U "$HC_HANDOVER")" = "claude" ]
  [ "$(stat -c %a "$HC_STATE")" = "700" ]
  run runuser -u claude -- touch "$HC_WORKSPACE/x"
  [ "$status" -ne 0 ]
}
