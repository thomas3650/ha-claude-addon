# The result file: an agent that ran without a terminal may leave a short
# result in the results folder, <agent>.json, with exactly three fields:
# count, verdict and text. The add-on's own script checks it and raises it
# as the event ha_claude_result. This is the one place where words Claude
# wrote leave the add-on, so the file is trusted with nothing: its kind, its
# age, its size and its shape are checked, and its content is never logged
# and never put on a command line.
: "${HC_RESULT_BYTES:=32768}"

# _result_body <agent> <file> - prints the event's body, or fails when the
# file is not a result. Control characters are removed; the line feed stays
# in the text only. The limits count characters, after the cleaning.
_result_body() {
  # shellcheck disable=SC2016  # jq's variables, not the shell's
  jq -ce --arg agent "$1" --arg time "$(date +%FT%T%z)" '
    def clean($nl): explode
      | map(select((. >= 32 and . != 127 and (. < 128 or . > 159)) or ($nl and . == 10)))
      | implode;
    if type != "object" or (keys != ["count", "text", "verdict"]) then error("shape") else . end
    | if (.count | type) != "number" or .count != (.count | floor) or .count < 0 or .count > 9999
      then error("count") else . end
    | if (.verdict | type) != "string" or (.text | type) != "string" then error("type") else . end
    | {agent: $agent, count: .count, verdict: (.verdict | clean(false)), text: (.text | clean(true)), time: $time}
    | if (.verdict | length) > 120 or (.text | length) > 4000 then error("length") else . end
  ' "$2" 2>/dev/null
}

# publish_result <agent> <marker> - raises the agent's result file as the
# event ha_claude_result. Returns 1, with one fixed word in the log, when
# the file is missing, not a regular file, older than the marker, too large
# or not a result. Returns 0 when it was raised, and also when Home
# Assistant could not be told: the file was good.
publish_result() {
  local agent="$1" marker="$2" file="$HC_RESULTS/$1.json" body="$HC_STATE/result.body" size
  if [[ -L "$file" || ! -f "$file" ]]; then
    log "result: $agent: missing"
    return 1
  fi
  if [[ "$file" -ot "$marker" ]]; then
    log "result: $agent: stale"
    return 1
  fi
  size="$(wc -c < "$file" 2>/dev/null)" || size=""
  if [[ ! "${size//[[:space:]]/}" =~ ^[0-9]+$ ]] || (( size > HC_RESULT_BYTES )); then
    log "result: $agent: too large"
    return 1
  fi
  mkdir -p "$HC_STATE"
  rm -f "$body"
  if ! ( umask 077; _result_body "$agent" "$file" > "$body" ); then
    rm -f "$body"
    log "result: $agent: malformed"
    return 1
  fi
  if [[ -z "${SUPERVISOR_TOKEN:-}" ]]; then
    log "result: $agent (not reported: no Supervisor token)"
    rm -f "$body"
    return 0
  fi
  # The body is read by curl from the file, and the token on standard
  # input: neither is an argument, which every user in the container can read.
  if curl -fsS -m 10 -o /dev/null -X POST \
       -H "Content-Type: application/json" \
       --data-binary "@$body" \
       -K - \
       "${HC_CORE_API:-http://supervisor/core/api}/events/ha_claude_result" \
       <<<"header = \"Authorization: Bearer $SUPERVISOR_TOKEN\""; then
    log "result: $agent"
  else
    log "result: $agent (could not reach Home Assistant)"
  fi
  rm -f "$body"
  return 0
}
