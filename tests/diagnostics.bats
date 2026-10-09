load helpers

@test "diagnostics report memory and never fail" {
  load_lib env diagnostics
  export HC_MEMINFO="$BATS_TEST_TMPDIR/meminfo" HC_OFFLINE=1
  printf 'MemTotal: 8000000 kB\nMemAvailable: 4000000 kB\n' > "$HC_MEMINFO"
  run run_diagnostics
  [ "$status" -eq 0 ]
  [[ "$output" == *"memory: 3906 MB available of 7812 MB"* ]]
  [[ "$output" == *"/data is writable"* ]]
}

@test "diagnostics warn when memory is low" {
  load_lib env diagnostics
  export HC_MEMINFO="$BATS_TEST_TMPDIR/meminfo" HC_OFFLINE=1
  printf 'MemTotal: 2000000 kB\nMemAvailable: 200000 kB\n' > "$HC_MEMINFO"
  run run_diagnostics
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: less than 512 MB"* ]]
}
