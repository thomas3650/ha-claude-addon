load helpers

@test "ensure_layout creates the folders" {
  load_lib layout
  ensure_layout
  [ -d "$HC_HOME" ] && [ -d "$HC_HANDOVER" ] && [ -d "$HC_STATE" ] && [ -d "$HC_WORKSPACE" ]
  [ -d "$HC_STATUS" ]
  [ -d "$HC_RESULTS" ]
}

@test "as root, the workspace is not writable by the Claude user" {
  [ "$(id -u)" -eq 0 ] || skip "needs root; runs in the container test"
  HC_USER=claude
  load_lib layout
  ensure_layout
  [ "$(stat -c %U "$HC_WORKSPACE")" = "root" ]
  [ "$(stat -c %U "$HC_HANDOVER")" = "claude" ]
  [ "$(stat -c %U "$HC_RESULTS")" = "claude" ]
  [ "$(stat -c %a "$HC_STATE")" = "700" ]
  [ "$(stat -c %U:%a "$HC_STATUS")" = "root:755" ]
  run runuser -u claude -- touch "$HC_WORKSPACE/x"
  [ "$status" -ne 0 ]
}

@test "ensure_layout creates the jobs folder and the jobs' results folder" {
  load_lib layout
  ensure_layout
  [ -d "$HC_JOBS" ]
  [ -d "$HC_JOB_RESULTS" ]
  [ -d "$HC_JOB_STATE" ]
}

@test "as root, the jobs folders are the Claude user's, and a link in the results folder is not followed" {
  [ "$(id -u)" -eq 0 ] || skip "needs root; runs in the container test"
  HC_USER=claude
  load_lib layout
  # The Claude user makes the results' jobs folder, so it must reach it, as
  # it reaches /data in the add-on.
  d="$HC_DATA"
  while [ "$d" != / ]; do chmod o+x "$d"; d="$(dirname "$d")"; done
  ensure_layout
  [ "$(stat -c %U "$HC_JOBS")" = "claude" ]
  [ "$(stat -c %U "$HC_JOB_RESULTS")" = "claude" ]
  [ "$(stat -c %U "$HC_JOB_STATE")" = "root" ]
  rm -r "$HC_JOB_RESULTS"
  mkdir -p "$BATS_TEST_TMPDIR/rootdir"
  ln -s "$BATS_TEST_TMPDIR/rootdir" "$HC_JOB_RESULTS"
  chown -h claude:claude "$HC_JOB_RESULTS"
  ensure_layout
  [ "$(stat -c %U "$BATS_TEST_TMPDIR/rootdir")" = "root" ]
}
