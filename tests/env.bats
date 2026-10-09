load helpers

@test "claude_env has HOME and no Supervisor token" {
  load_lib env
  export SUPERVISOR_TOKEN=secret
  run claude_env
  [[ "$output" == *"HOME=$HC_HOME"* ]]
  [[ "$output" != *"SUPERVISOR_TOKEN"* ]]
  [[ "$output" != *"secret"* ]]
}

@test "as_claude runs a command without the Supervisor token" {
  load_lib env
  export SUPERVISOR_TOKEN=secret HASSIO_TOKEN=secret2
  run as_claude env
  [ "$status" -eq 0 ]
  [[ "$output" != *"secret"* ]]
  [[ "$output" == *"DISABLE_AUTOUPDATER=1"* ]]
}

@test "resolve_tz keeps a TZ that is set" {
  load_lib env
  export TZ=America/New_York
  resolve_tz
  [ "$TZ" = "America/New_York" ]
}

@test "resolve_tz falls back to UTC and says so" {
  load_lib env
  unset TZ
  run bash -c "source '$LIB/paths.sh'; source '$LIB/log.sh'; source '$LIB/env.sh'; resolve_tz; echo TZ=\$TZ"
  [[ "$output" == *"TZ=UTC"* ]]
  [[ "$output" == *"no time zone"* ]]
}
