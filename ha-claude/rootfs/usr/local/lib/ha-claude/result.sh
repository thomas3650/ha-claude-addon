# The result file: an agent that ran without a terminal may leave a short
# result in the results folder, <agent>.json, with exactly three fields:
# count, verdict and text. The add-on's own script checks it and raises it
# as the event ha_claude_result. This is the one place where words Claude
# wrote leave the add-on, so the file is trusted with nothing: its kind, its
# age, its size and its shape are checked, and its content is never logged
# and never put on a command line.
: "${HC_RESULT_BYTES:=32768}"
: "${HC_RESULT_WAIT:=5}"
: "${HC_LIMIT_BIN:=/usr/local/bin/ha-claude-limit}"

# _result_body <agent> <file> - prints the event's body, or fails when the
# file is not one result: one JSON value and no more. The count must be
# written as a plain whole number, so what is sent is what was checked.
# Control characters are removed, and the characters that break or turn a
# line; the line feed stays in the text only. The limits count characters,
# after the cleaning. jq's message goes to standard error; the caller takes
# from it only which check failed (_result_reason).
_result_body() {
  # shellcheck disable=SC2016  # jq's variables, not the shell's
  jq -cen --arg agent "$1" --arg time "$(date +%FT%T%z)" '
    def clean($nl): explode
      | map(select(((. >= 32 and . != 127 and (. < 128 or . > 159))
                    and (. < 8232 or . > 8238) and (. < 8294 or . > 8297))
                   or ($nl and . == 10)))
      | implode;
    [inputs] | if length != 1 then error("shape") else .[0] end
    | if type != "object" or (keys != ["count", "text", "verdict"]) then error("shape") else . end
    | if (.count | type) != "number" or (.count | tojson | test("^(0|[1-9][0-9]{0,3})$") | not)
      then error("count") else . end
    | if (.verdict | type) != "string" or (.text | type) != "string" then error("type") else . end
    | {agent: $agent, count: .count, verdict: (.verdict | clean(false)), text: (.text | clean(true)), time: $time}
    | if (.verdict | length) > 120 or (.text | length) > 4000 then error("length") else . end
  ' "$2"
}

# _result_reason <file> - prints which check refused the result, one fixed
# word, from jq's message in the file: shape, count, type or length when
# one of them did, "not json" for any other jq error (the file did not
# parse), and "other" when jq gave no error line at all (jq missing or
# killed, the body not written). Nothing else of the message is printed.
_result_reason() {
  local last
  last="$(tail -n 1 -- "$1" 2>/dev/null)"
  case "$last" in
    *': shape') echo shape ;;
    *': count') echo count ;;
    *': type') echo type ;;
    *': length') echo length ;;
    'jq: error'*) echo 'not json' ;;
    *) echo other ;;
  esac
}

# clear_result <agent> - removes the agent's result file before a run, as
# the Claude user, so a run starts without one: what is there afterwards is
# this run's, and the agent writes a new file, not over an old one.
clear_result() {
  as_claude rm -f -- "$HC_RESULTS/$1.json" </dev/null >/dev/null 2>&1 || true
}

# publish_result <agent> <marker> - raises the agent's result file as the
# event ha_claude_result. Returns 1, with one fixed reason in the log, when
# the file is missing, older than the marker, cannot be read in time, is too
# large or is not a result. Returns 0 when it was raised, and also when Home
# Assistant could not be told: the file was good.
#
# The folder and the file are the Claude user's, who can swap the file for a
# link, a pipe or a larger file at any moment. So this script never opens
# that path itself: the Claude user copies it, with a time limit and a size
# cap, into a file only root can reach, and that copy is what is checked.
# A link then gives nothing the Claude user could not read anyway, and a
# pipe costs a few seconds. Both waits are in the background, so a stop
# signal is handled at once.
publish_result() {
  local agent="$1" marker="$2" file="$HC_RESULTS/$1.json"
  local copy="$HC_STATE/result.in" body="$HC_STATE/result.body" size rc=0
  local err="$HC_STATE/result.err"
  if [[ ! -e "$file" ]]; then
    log "result: $agent: missing"
    return 1
  fi
  if [[ "$file" -ot "$marker" ]]; then
    log "result: $agent: stale"
    return 1
  fi
  mkdir -p "$HC_STATE"
  rm -f "$copy" "$body" "$err"
  ( umask 077; : > "$copy" )
  as_claude env HC_LIMIT_GRACE=1 "$HC_LIMIT_BIN" "$HC_RESULT_WAIT" \
    head -c "$((HC_RESULT_BYTES + 1))" -- "$file" </dev/null >>"$copy" 2>/dev/null &
  wait $! || rc=$?
  if (( rc != 0 )); then
    rm -f "$copy"
    log "result: $agent: unreadable"
    return 1
  fi
  size="$(wc -c < "$copy")"
  if (( size > HC_RESULT_BYTES )); then
    rm -f "$copy"
    log "result: $agent: too large"
    return 1
  fi
  if ! ( umask 077; _result_body "$agent" "$copy" > "$body" 2> "$err" ); then
    log "result: $agent: malformed ($(_result_reason "$err"))"
    rm -f "$copy" "$body" "$err"
    return 1
  fi
  rm -f "$err"
  rm -f "$copy"
  if [[ -z "${SUPERVISOR_TOKEN:-}" ]]; then
    log "result: $agent (not reported: no Supervisor token)"
    rm -f "$body"
    return 0
  fi
  # The body is read by curl from the file, and the token on standard
  # input: neither is an argument, which every user in the container can read.
  rc=0
  curl -fsS -m 10 -o /dev/null -X POST \
       -H "Content-Type: application/json" \
       --data-binary "@$body" \
       -K - \
       "${HC_CORE_API:-http://supervisor/core/api}/events/ha_claude_result" \
       <<<"header = \"Authorization: Bearer $SUPERVISOR_TOKEN\"" &
  wait $! || rc=$?
  if (( rc == 0 )); then
    log "result: $agent"
  else
    log "result: $agent (could not reach Home Assistant)"
  fi
  rm -f "$body"
  return 0
}
