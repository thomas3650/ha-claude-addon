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

@test "the extra_mcp schema accepts a name=upstream entry and refuses characters nginx or sed would read" {
  re="$(sed -n 's/^    - match(\(.*\))$/\1/p' "$BATS_TEST_DIRNAME/../ha-claude/config.yaml" | grep 'https' | head -n 1)"
  [ -n "$re" ]
  [[ "tools=http://my-mcp:8000/private_x1" =~ $re ]]
  [[ "two=https://h:1/p" =~ $re ]]
  for bad in 'x=http://h/a;b' 'x=http://h/a|b' 'x=http://h/a}' 'x=http://h/a b' 'x=http://h/a?b' 'x=http://h/"' 'X=http://h/a' '=http://h/a' 'x=ftp://h/a'; do
    if [[ "$bad" =~ $re ]]; then echo "accepted: $bad"; false; fi
  done
}

@test "the tokens of extra servers are a list of passwords, empty by default" {
  f="$BATS_TEST_DIRNAME/../ha-claude/config.yaml"
  grep -qx '  extra_mcp_auth: \[\]' "$f"
  [ "$(sed -n '/^  extra_mcp_auth:$/{n;p;}' "$f")" = "    - password" ]
}

