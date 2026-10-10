load helpers
bats_require_minimum_version 1.5.0

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

@test "assistant_env passes entries whose names start with ASSISTANT_" {
  load_lib options env
  set_options '{"assistant_env":["ASSISTANT_ONE=http://example.test:1/mcp","ASSISTANT_TWO=b c"]}'
  run --separate-stderr assistant_env
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "ASSISTANT_ONE=http://example.test:1/mcp" ]
  [ "${lines[1]}" = "ASSISTANT_TWO=b c" ]
  [ -z "$stderr" ]
}

@test "assistant_env ignores other names and logs the name, not the value" {
  load_lib options env
  set_options '{"assistant_env":["PATH=/tmp/evil","HOME=/tmp","ANTHROPIC_API_KEY=sk-secret","assistant_lower=x","ASSISTANT_OK=1"]}'
  run --separate-stderr assistant_env
  [ "$status" -eq 0 ]
  [ "$output" = "ASSISTANT_OK=1" ]
  [[ "$stderr" == *"ignoring assistant_env entry 'PATH'"* ]]
  [[ "$stderr" == *"ignoring assistant_env entry 'ANTHROPIC_API_KEY'"* ]]
  [[ "$stderr" != *"sk-secret"* ]]
  [[ "$stderr" != *"/tmp/evil"* ]]
}

@test "assistant_env refuses a whole entry that holds a line break" {
  load_lib options env
  set_options '{"assistant_env":["ASSISTANT_A=1\nASSISTANT_B=2","ASSISTANT_OK=1"]}'
  run --separate-stderr assistant_env
  [ "$status" -eq 0 ]
  [ "$output" = "ASSISTANT_OK=1" ]
}

@test "assistant_env never logs an entry that has no name" {
  load_lib options env
  set_options '{"assistant_env":["sk-pasted-secret with spaces"]}'
  run --separate-stderr assistant_env
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" != *"pasted"* ]]
}

@test "assistant_env prints nothing without the option or the options file" {
  load_lib options env
  run --separate-stderr assistant_env
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  set_options '{}'
  run --separate-stderr assistant_env
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "claude_env includes the assistant's variables" {
  load_lib options env
  set_options '{"assistant_env":["ASSISTANT_ONE=1"]}'
  run claude_env
  [[ "$output" == *"ASSISTANT_ONE=1"* ]]
  [[ "$output" == *"HOME=$HC_HOME"* ]]
}
