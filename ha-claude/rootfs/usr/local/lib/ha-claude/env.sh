# The environment of everything that runs as the Claude user. Nothing from the
# container's own environment is passed on, so the token Home Assistant
# injects (SUPERVISOR_TOKEN) never reaches Claude Code.

resolve_tz() {
  if [[ -z "${TZ:-}" ]]; then
    log "no time zone from Home Assistant; using UTC"
    TZ=UTC
  fi
  export TZ
}

# Extra variables for the Claude user, from the option assistant_env. Only
# names starting with ASSISTANT_ are accepted, so an option cannot replace
# HOME, PATH or a variable Claude Code itself reads. Each entry is judged
# whole, inside jq, so an entry with a line break cannot become two. A
# refused entry is logged by the name before its "=" and never by more: the
# rest, or an entry with no "=", may be a secret pasted into the wrong field.
assistant_env() {
  local re='\AASSISTANT_[A-Z0-9_]+=[^\x00-\x1f\x7f]*\z' name
  [[ -f "$HC_OPTIONS" ]] || return 0
  jq -r --arg re "$re" '.assistant_env[]? | strings | select(test($re))' "$HC_OPTIONS" 2>/dev/null
  while IFS= read -r name; do
    if [[ -n "$name" ]]; then
      log "options: ignoring assistant_env entry '$name'"
    else
      log "options: ignoring an assistant_env entry without a name"
    fi
  done < <(jq -r --arg re "$re" \
            '.assistant_env[]? | strings | select(test($re) | not) | ([capture("\\A(?<n>[A-Za-z0-9_]+)=").n][0] // "")' \
            "$HC_OPTIONS" 2>/dev/null)
  return 0
}

claude_env() {
  printf '%s\n' \
    "HOME=$HC_HOME" \
    "USER=$HC_USER" \
    "LOGNAME=$HC_USER" \
    "SHELL=/bin/bash" \
    "PATH=/usr/local/bin:/usr/bin:/bin" \
    "TERM=${TERM:-xterm-256color}" \
    "LANG=C.UTF-8" \
    "TZ=${TZ:-UTC}" \
    "HC_DATA=$HC_DATA" \
    "DISABLE_AUTOUPDATER=1"
  assistant_env 2>/dev/null
}

as_claude() {
  local -a vars
  local runuser_bin
  mapfile -t vars < <(claude_env)
  if [[ "$(id -u)" == 0 ]]; then
    # Resolved here: env looks a command up in the new PATH, which has no sbin.
    runuser_bin="$(command -v runuser || echo /usr/sbin/runuser)"
    env -i "${vars[@]}" "$runuser_bin" -u "$HC_USER" -- "$@"
  else
    env -i "${vars[@]}" "$@"
  fi
}
