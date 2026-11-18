# The result file: an agent that ran without a terminal may leave a short
# result in the results folder, <agent>.json: verdict and text, and
# optionally count and notify, the same for every run (the schema is
# schemas/result.schema.json). The add-on's own script checks it and raises
# it as the event ha_claude_result. This is the one place where words Claude
# wrote leave the add-on, so the file is trusted with nothing: its kind, its
# age, its size and its shape are checked, and its content is never logged
# and never put on a command line.
: "${HC_RESULT_BYTES:=32768}"
: "${HC_RESULT_WAIT:=5}"
: "${HC_LIMIT_BIN:=/usr/local/bin/ha-claude-limit}"

# The cleaning, in jq, shared with the jobs' results.
# shellcheck disable=SC2016  # jq's variables, not the shell's
HC_JQ_CLEAN='
    def clean($nl): explode
      | map(select(((. >= 32 and . != 127 and (. < 128 or . > 159))
                    and (. < 8232 or . > 8238) and (. < 8294 or . > 8297))
                   or ($nl and . == 10)))
      | implode;'

# result_body <file> - prints the result, cleaned, as one JSON object
# {verdict, text, count, notify}, or fails when the file is not one result:
# one JSON value and no more, with verdict and text, and count and notify
# only besides. One check for every run, a fixed run's and a job's. A count
# that is absent is 0 and a notify that is absent is false, so what reads
# the body never meets an empty value. The count must be written as a
# plain whole number, 0 to 9999, so what is sent is what was checked.
# Control characters are removed, and the characters that break or turn a
# line; the line feed stays in the text only. The limits count characters,
# after the cleaning. jq's message goes to standard error; the caller takes
# from it only which check failed (_result_reason).
result_body() {
  jq -cen "$HC_JQ_CLEAN"'
    [inputs] | if length != 1 then error("shape") else .[0] end
    | if type != "object" or ((keys - ["count", "notify"]) != ["text", "verdict"]) then error("shape") else . end
    | if has("count") and ((.count | type) != "number" or (.count | tojson | test("^(0|[1-9][0-9]{0,3})$") | not))
      then error("count") else . end
    | if (.verdict | type) != "string" or (.text | type) != "string"
         or (has("notify") and (.notify | type) != "boolean")
      then error("type") else . end
    | {verdict: (.verdict | clean(false)), text: (.text | clean(true)), count: (.count // 0), notify: (.notify // false)}
    | if (.verdict | length) > 120 or (.text | length) > 4000 then error("length") else . end
  ' "$1"
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

# claude_copy <file> <copy> <bytes> <seconds> [tail] - copies a file the Claude
# user may swap at any moment into a file only root can reach, the way
# publish_result explains below: the Claude user reads it, with a time limit,
# and no more than one byte over the size cap. Returns 0 with the copy, 1
# when it could not be read in time (the copy is removed) and 2 when it is
# larger than the cap (the copy is removed). With tail, the copy is the
# file's last <bytes> bytes, and a larger file is not refused.
claude_copy() {
  local file="$1" copy="$2" bytes="$3" wait_s="$4" size rc=0
  local -a reader=(head -c "$((bytes + 1))")
  [[ "${5:-}" == tail ]] && reader=(tail -c "$bytes")
  rm -f "$copy"
  ( umask 077; : > "$copy" )
  as_claude env HC_LIMIT_GRACE=1 "$HC_LIMIT_BIN" "$wait_s" \
    "${reader[@]}" -- "$file" </dev/null >>"$copy" 2>/dev/null &
  wait $! || rc=$?
  if (( rc != 0 )); then
    rm -f "$copy"
    return 1
  fi
  size="$(wc -c < "$copy")"
  if (( size > bytes )); then
    rm -f "$copy"
    return 2
  fi
  return 0
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
  local copy="$HC_STATE/result.in" body="$HC_STATE/result.body" rc=0
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
  rm -f "$body" "$err"
  claude_copy "$file" "$copy" "$HC_RESULT_BYTES" "$HC_RESULT_WAIT" || rc=$?
  if (( rc == 1 )); then
    log "result: $agent: unreadable"
    return 1
  elif (( rc != 0 )); then
    log "result: $agent: too large"
    return 1
  fi
  if ! ( umask 077; result_body "$copy" > "$body" 2> "$err" ); then
    log "result: $agent: malformed ($(_result_reason "$err"))"
    rm -f "$copy" "$body" "$err"
    return 1
  fi
  rm -f "$err"
  rm -f "$copy"
  # The event: the cleaned result as the agent's, with the time. notify is
  # not in it; it is for a job's runner.
  # shellcheck disable=SC2016  # jq's variables, not the shell's
  if ! ( umask 077; jq -c --arg agent "$agent" --arg time "$(date +%FT%T%z)" \
           '{agent: $agent, count, verdict, text, time: $time}' "$body" > "$body.event" \
         && mv -f -- "$body.event" "$body" ); then
    rm -f "$body" "$body.event"
    log "result: $agent: malformed (other)"
    return 1
  fi
  # A fixed run's finding is read from this body afterwards (fixed_run_end):
  # kept for root alone, before the body is removed, whether or not Home
  # Assistant is told. Failing to keep it does not change the result.
  if ( umask 077; cat -- "$body" > "$HC_STATE/fixed-$agent.body.tmp" ) 2>/dev/null; then
    mv -f -- "$HC_STATE/fixed-$agent.body.tmp" "$HC_STATE/fixed-$agent.body" 2>/dev/null       || rm -f -- "$HC_STATE/fixed-$agent.body.tmp"
  else
    rm -f -- "$HC_STATE/fixed-$agent.body.tmp"
  fi
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
