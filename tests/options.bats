load helpers

@test "opt returns the value of an option" {
  load_lib options
  set_options '{"session_name":"Office"}'
  run opt '.session_name' 'Home'
  [ "$output" = "Office" ]
}

@test "opt returns the default when the option is missing or empty" {
  load_lib options
  set_options '{"session_name":""}'
  run opt '.session_name' 'Home'
  [ "$output" = "Home" ]
  run opt '.nothing' 'fallback'
  [ "$output" = "fallback" ]
}

@test "opt returns the default when there is no options file" {
  load_lib options
  run opt '.session_name' 'Home'
  [ "$status" -eq 0 ]
  [ "$output" = "Home" ]
}

@test "paths derive from HC_DATA" {
  load_lib
  [ "$HC_WORKSPACE" = "$HC_DATA/workspace/assistant" ]
  [ "$HC_HANDOVER" = "$HC_DATA/handover" ]
}
