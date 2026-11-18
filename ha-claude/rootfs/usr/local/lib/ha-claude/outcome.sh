# Reports the result of a command to Home Assistant as one fixed event
# Run by the add-on's own script as root, never by Claude. A third argument
# is the run's agent; it is sent as the field agent. A fourth is who started
# a run, jobs (the tick) or command; it is sent as the field by. Either is
# left out when it is empty.
raise_outcome() {
  local command="$1" outcome="$2" agent="${3:-}" by="${4:-}" body
  if [[ -z "${SUPERVISOR_TOKEN:-}" ]]; then
    log "outcome: $command=$outcome${agent:+ $agent} (not reported: no Supervisor token)"
    return 0
  fi
  # shellcheck disable=SC2016  # jq's variables, not the shell's
  body="$(jq -cn --arg c "$command" --arg o "$outcome" --arg a "$agent" --arg b "$by" \
            '{command:$c,outcome:$o} + (if $a != "" then {agent:$a} else {} end)
             + (if $b != "" then {by:$b} else {} end)')"
  # The token goes to curl on standard input, not as an argument: arguments
  # are readable by every user in the container.
  if curl -fsS -m 10 -o /dev/null -X POST \
       -H "Content-Type: application/json" \
       -d "$body" \
       -K - \
       "${HC_CORE_API:-http://supervisor/core/api}/events/ha_claude_outcome" \
       <<<"header = \"Authorization: Bearer $SUPERVISOR_TOKEN\""; then
    log "outcome: $command=$outcome"
  else
    log "outcome: $command=$outcome (could not reach Home Assistant)"
  fi
  return 0
}
