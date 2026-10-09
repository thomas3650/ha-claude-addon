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
}

as_claude() {
  local -a vars
  mapfile -t vars < <(claude_env)
  if [[ "$(id -u)" == 0 ]]; then
    env -i "${vars[@]}" runuser -u "$HC_USER" -- "$@"
  else
    env -i "${vars[@]}" "$@"
  fi
}
