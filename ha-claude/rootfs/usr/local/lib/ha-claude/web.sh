# The add-on's nginx: the panel's page and terminals, and Claude's way to
# Home Assistant. The second is a listener on the container's own loopback
# that forwards one address and adds the token Home Assistant gave the
# add-on. The token is kept in a file only root can read.
: "${HC_PROXY_DIR:=/run/ha-claude}"
HC_MCP_DEFAULT=http://supervisor/core/api/mcp
: "${HC_MCP_UPSTREAM:=$HC_MCP_DEFAULT}"
: "${HC_RESOLV:=/etc/resolv.conf}"

# Prints the name server nginx asks for the upstream's address.
proxy_resolver() {
  local ip=""
  ip="$(awk '$1 == "nameserver" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $2; exit }' "$HC_RESOLV" 2>/dev/null)"
  printf '%s' "${ip:-127.0.0.11}"
}

# Prints the usable entries of the option extra_mcp, one per line, as
# name=upstream. HC_EXTRA_MCP, newline-separated, replaces the option for
# the smoke test. An entry is checked against the schema's own class here
# too: only root sets it, but a character with a meaning to nginx would give
# a broken configuration, and with it no panel. A refused entry is logged by
# its name and never by its upstream, which may hold a secret path.
extra_mcp_entries() {
  local re='^[a-z][a-z0-9-]{0,31}=https?://[A-Za-z0-9._:/-]+$' entry name
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    if [[ "$entry" =~ $re ]]; then
      printf '%s\n' "$entry"
    else
      name="${entry%%=*}"
      name="${name//[^a-z0-9-]/}"
      log "proxy: ignoring extra_mcp entry '${name:0:32}'"
    fi
  done < <(if [[ -n "${HC_EXTRA_MCP:-}" ]]; then printf '%s\n' "$HC_EXTRA_MCP"
           elif [[ -f "$HC_OPTIONS" ]]; then jq -r '.extra_mcp[]? | strings' "$HC_OPTIONS" 2>/dev/null; fi)
}

# Prints one nginx location per extra_mcp entry: POST only, no token, the
# upstream's errors kept out of the log, a longer read timeout than /mcp.
render_extra_mcp() {
  local entry name upstream var
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    name="${entry%%=*}"
    upstream="${entry#*=}"
    var="mcp_upstream_${name//-/_}"
    printf '    location = /mcp/%s {\n' "$name"
    # shellcheck disable=SC2016  # nginx's variable, not the shell's
    printf '      if ($request_method != POST) { return 405; }\n'
    printf '      error_log stderr crit;\n'
    printf '      set $%s "%s";\n' "$var" "$upstream"
    printf '      proxy_pass $%s;\n' "$var"
    printf '      proxy_http_version 1.1;\n'
    printf '      proxy_set_header Connection "";\n'
    printf '      proxy_set_header Authorization "";\n'
    printf '      proxy_buffering off;\n'
    printf '      proxy_read_timeout 300s;\n'
    printf '    }\n'
  done < <(extra_mcp_entries)
}

# Writes the nginx directive that sets the token. A token with a character
# that could end the string is not used, and is never logged.
write_proxy_auth() {
  local line='proxy_set_header Authorization "";'
  if [[ -z "${SUPERVISOR_TOKEN:-}" ]]; then
    log "proxy: no token from Home Assistant; requests will be refused there"
  elif [[ "$SUPERVISOR_TOKEN" =~ ^[A-Za-z0-9._~+/=-]+$ ]]; then
    line="proxy_set_header Authorization \"Bearer $SUPERVISOR_TOKEN\";"
  else
    log "proxy: the token from Home Assistant is not usable; requests will be refused there"
  fi
  # A new file each time, so the token is never written into a file with
  # an older mode. Without the file nginx does not start: say so.
  if ! { mkdir -p "$HC_PROXY_DIR" && chmod 700 "$HC_PROXY_DIR" \
         && rm -f "$HC_PROXY_DIR/proxy-auth.conf" \
         && ( umask 077; printf '%s\n' "$line" > "$HC_PROXY_DIR/proxy-auth.conf" ); }; then
    log "proxy: the token file could not be written; nginx will not start"
    return 1
  fi
}

# render_nginx_conf <template> - prints the configuration.
render_nginx_conf() {
  local allow="allow 172.30.32.2; deny all;" upstream="$HC_MCP_UPSTREAM" line
  # HC_INGRESS_ALLOW=all is for the container smoke test only.
  [[ "${HC_INGRESS_ALLOW:-}" == "all" ]] && allow=""
  # Only root sets the upstream, but a character with a meaning to sed or to
  # nginx would give a broken configuration, and with it no panel.
  if [[ ! "$upstream" =~ ^https?://[A-Za-z0-9._:/-]+$ ]]; then
    log "proxy: the upstream is not usable; using $HC_MCP_DEFAULT"
    upstream="$HC_MCP_DEFAULT"
  fi
  # The extra locations are printed in place of their mark, never through
  # sed: an entry is checked, but it is not sed's to parse.
  while IFS= read -r line; do
    if [[ "$line" == *__EXTRA_MCP__* ]]; then
      render_extra_mcp
    else
      printf '%s\n' "$line"
    fi
  done < <(sed -e "s|__ALLOW__|$allow|" \
               -e "s|__RESOLVER__|$(proxy_resolver)|" \
               -e "s|__UPSTREAM__|$upstream|" \
               -e "s|__AUTH__|$HC_PROXY_DIR/proxy-auth.conf|" "$1")
}

# Posts one MCP request through the listener. Arguments: the method, then
# curl options.
_proxy_post() {
  local method="$1"; shift
  curl -s -m 15 -X POST \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\"}" \
    "$@" http://127.0.0.1:7684/mcp 2>/dev/null
}

# Asks Home Assistant once through the listener and logs the status code.
# What the codes mean is in DOCS.md. When Home Assistant answers, the names
# of the tools it offers are logged as well, since permission rules are
# written by tool name. Nothing else of an answer is logged, and a name is
# logged only when it is made of letters, digits, "_" and "-". A script
# that is exposed is offered as a tool under its own name.
check_proxy() {
  local code="" names=""
  code="$(_proxy_post ping -o /dev/null -w '%{http_code}')" || code=""
  log "proxy: Home Assistant answered ${code:-nothing} through the listener"
  [[ "$code" == 2* ]] || return 0
  names="$(_proxy_post tools/list | sed -n -e 's/^data: \{0,1\}//' -e '/^{/p' \
            | jq -r '[.result.tools[]?.name? | strings | select(test("^[A-Za-z0-9_-]{1,64}$"))] | .[:80] | join(" ")' 2>/dev/null \
            | head -n 1 | grep -E '^[A-Za-z0-9_ -]+$')" || names=""
  [[ -n "$names" ]] && log "proxy: Home Assistant offers these tools: $names"
  return 0
}
