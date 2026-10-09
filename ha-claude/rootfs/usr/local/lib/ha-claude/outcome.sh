# Reports the result of a command to Home Assistant as one fixed event
# Run by the add-on's own script as root, never by Claude.
raise_outcome() {
  local command="$1" outcome="$2" body
  if [[ -z "${SUPERVISOR_TOKEN:-}" ]]; then
    log "outcome: $command=$outcome (not reported: no Supervisor token)"
    return 0
  fi
  body="$(jq -cn --arg c "$command" --arg o "$outcome" '{command:$c,outcome:$o}')"
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
