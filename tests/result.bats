load helpers

# curl's stand-in: its arguments to one file, what it would send (the file
# named with --data-binary) to another, its standard input to a third.
stub_curl() {
  export SUPERVISOR_TOKEN=tok-123
  export HC_LIMIT_BIN="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/ha-claude-limit"
  SENT="$BATS_TEST_TMPDIR/sent"; mkdir -p "$SENT"
  curl() {
    printf '%s\n' "$*" >> "$SENT/args"
    local a
    for a in "$@"; do
      [[ "$a" == @* ]] && cat "${a#@}" > "$SENT/body"
    done
    cat > "$SENT/stdin"
  }
}

# good_file [json] - writes the agent's result file and an older marker.
good_file() {
  mkdir -p "$HC_RESULTS" "$HC_STATE"
  MARKER="$HC_STATE/run.started"
  : > "$MARKER"
  touch -t 202001010000 "$MARKER"
  printf '%s' "${1:-{\"count\":3,\"verdict\":\"3 ting\",\"text\":\"a\\nb\"\}}" > "$HC_RESULTS/house-check.json"
}

refused() {
  run publish_result house-check "$MARKER"
  [ "$status" -eq 1 ]
  [ ! -e "$SENT/args" ]
  [ ! -e "$HC_STATE/result.body" ]
  [ ! -e "$HC_STATE/result.in" ]
}

@test "a good result is raised as one event with five fields" {
  load_lib options env result; stub_curl; good_file
  publish_result house-check "$MARKER"
  [ "$(wc -l < "$SENT/args")" -eq 1 ]
  grep -q "/events/ha_claude_result" "$SENT/args"
  [ "$(jq -c 'keys' "$SENT/body")" = '["agent","count","text","time","verdict"]' ]
  [ "$(jq -r '.agent' "$SENT/body")" = "house-check" ]
  [ "$(jq -r '.count' "$SENT/body")" = "3" ]
  [ "$(jq -r '.verdict' "$SENT/body")" = "3 ting" ]
  [ "$(jq -r '.text' "$SENT/body")" = $'a\nb' ]
  [ ! -e "$HC_STATE/result.body" ]
}

@test "the token and the text are not on curl's command line or in the log" {
  load_lib options env result; stub_curl
  good_file '{"count":1,"verdict":"v","text":"a\"b\\c $(id) æøå"}'
  run publish_result house-check "$MARKER"
  [ "$status" -eq 0 ]
  run grep "tok-123" "$SENT/args"
  [ "$status" -eq 1 ]
  grep -q "Bearer tok-123" "$SENT/stdin"
  run grep "æøå" "$SENT/args"
  [ "$status" -eq 1 ]
  run publish_result house-check "$MARKER"
  [[ "$output" != *"æøå"* ]]
  [ "$(jq -r '.text' "$SENT/body")" = 'a"b\c $(id) æøå' ]
}

@test "a missing file is refused" {
  load_lib options env result; stub_curl; good_file
  rm "$HC_RESULTS/house-check.json"
  refused
  [[ "$output" == *"result: house-check: missing"* ]]
}

@test "a folder is refused, and a pipe costs a few seconds and is refused" {
  load_lib options env result; stub_curl; good_file
  rm "$HC_RESULTS/house-check.json"
  mkdir "$HC_RESULTS/house-check.json"
  refused
  [[ "$output" == *"unreadable"* ]]
  rmdir "$HC_RESULTS/house-check.json"
  mkfifo "$HC_RESULTS/house-check.json"
  HC_RESULT_WAIT=1
  started=$SECONDS
  refused
  [[ "$output" == *"unreadable"* ]]
  (( SECONDS - started < 8 ))
}

@test "the file is copied before it is checked: what is checked is what is sent" {
  load_lib options env result; stub_curl; good_file
  # The stand-in for the Claude user's copy swaps the file after copying.
  as_claude() { "$@"; local rc=$?; printf 'swapped' > "$HC_RESULTS/house-check.json"; return $rc; }
  publish_result house-check "$MARKER"
  [ "$(jq -r '.verdict' "$SENT/body")" = "3 ting" ]
}

@test "a link is read as the Claude user reads it, never by the add-on's own process" {
  load_lib options env result; stub_curl; good_file
  mv "$HC_RESULTS/house-check.json" "$BATS_TEST_TMPDIR/real.json"
  ln -s "$BATS_TEST_TMPDIR/real.json" "$HC_RESULTS/house-check.json"
  as_claude() { echo "as_claude $*" >> "$SENT/as"; "$@"; }
  publish_result house-check "$MARKER"
  grep -q "head -c" "$SENT/as"
  [ "$(jq -r '.count' "$SENT/body")" = "3" ]
}

@test "a file with more than one value is refused" {
  load_lib options env result; stub_curl
  good='{"count":1,"verdict":"v","text":"t"}'
  for bad in "$good$good" "[1]$good" "$good 7" ""; do
    good_file "$bad"
    [ -n "$bad" ] || : > "$HC_RESULTS/house-check.json"
    refused
  done
}

@test "a count that is not written as a plain whole number is refused" {
  load_lib options env result; stub_curl
  for n in 1.0 -0 12345; do
    good_file "{\"count\":$n,\"verdict\":\"v\",\"text\":\"t\"}"
    refused
  done
  for n in 0 7 9999; do
    good_file "{\"count\":$n,\"verdict\":\"v\",\"text\":\"t\"}"
    publish_result house-check "$MARKER"
    [ "$(jq -r '.count' "$SENT/body")" = "$n" ]
  done
}

@test "characters that break or turn a line are removed from the verdict and the text" {
  load_lib options env result; stub_curl
  good_file '{"count":0,"verdict":"a\u2028b\u2029c\u202ed\u2066e","text":"a\u2028b\u202ec"}'
  publish_result house-check "$MARKER"
  [ "$(jq -r '.verdict' "$SENT/body")" = "abcde" ]
  [ "$(jq -r '.text' "$SENT/body")" = "abc" ]
}

@test "a file older than the run is refused" {
  load_lib options env result; stub_curl; good_file
  touch -t 201901010000 "$HC_RESULTS/house-check.json"
  refused
  [[ "$output" == *"stale"* ]]
}

@test "a file over the size limit is refused" {
  load_lib options env result; stub_curl; good_file
  HC_RESULT_BYTES=20
  refused
  [[ "$output" == *"too large"* ]]
}

@test "a file of another shape is refused, and its content is not logged" {
  load_lib options env result; stub_curl
  for bad in 'not json SECRET' '[1,2]' '"SECRET"' \
             '{"count":1,"verdict":"v","text":"t","more":"SECRET"}' \
             '{"count":1,"verdict":"SECRET"}' \
             '{"count":-1,"verdict":"v","text":"t"}' \
             '{"count":1.5,"verdict":"v","text":"t"}' \
             '{"count":10000,"verdict":"v","text":"t"}' \
             '{"count":"3","verdict":"v","text":"t"}' \
             '{"count":1,"verdict":7,"text":"t"}' \
             '{"count":1,"verdict":"v","text":["SECRET"]}'; do
    good_file "$bad"
    refused
    [[ "$output" == *"malformed"* ]]
    [[ "$output" != *"SECRET"* ]]
  done
}

@test "a verdict of 121 characters and a text of 4001 are refused; 120 and 4000 pass" {
  load_lib options env result; stub_curl
  v120="$(printf 'æ%.0s' {1..120})"
  t4000="$(printf 'x%.0s' {1..4000})"
  good_file "{\"count\":0,\"verdict\":\"$v120\",\"text\":\"$t4000\"}"
  publish_result house-check "$MARKER"
  [ -e "$SENT/body" ]
  rm -r "$SENT"; mkdir "$SENT"
  good_file "{\"count\":0,\"verdict\":\"${v120}x\",\"text\":\"t\"}"
  refused
  good_file "{\"count\":0,\"verdict\":\"v\",\"text\":\"${t4000}x\"}"
  refused
}

@test "the verdict loses its line feed; the text keeps line feeds and loses other control characters" {
  load_lib options env result; stub_curl
  good_file '{"count":0,"verdict":"one\ntwo","text":"a\nb\u0000c\u001bd\u0085e\u007ff"}'
  publish_result house-check "$MARKER"
  [ "$(jq -r '.verdict' "$SENT/body")" = "onetwo" ]
  [ "$(jq -r '.text' "$SENT/body")" = $'a\nbcdef' ]
}

@test "without a Supervisor token a good file is still good, and nothing is sent" {
  load_lib options env result; stub_curl; good_file
  unset SUPERVISOR_TOKEN
  run publish_result house-check "$MARKER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not reported"* ]]
  [ ! -e "$SENT/args" ]
}

@test "raise_outcome sends the agent as a third field only when one is given" {
  load_lib outcome; stub_curl
  curl() { printf '%s\n' "$*" > "$SENT/args"; cat > /dev/null; }
  raise_outcome run ok house-check
  grep -q -- '-d {"command":"run","outcome":"ok","agent":"house-check"}' "$SENT/args"
  raise_outcome ping ok
  grep -q -- '-d {"command":"ping","outcome":"ok"} ' "$SENT/args"
}
