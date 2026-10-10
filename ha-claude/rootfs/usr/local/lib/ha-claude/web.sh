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
  local allow="allow 172.30.32.2; deny all;" upstream="$HC_MCP_UPSTREAM"
  # HC_INGRESS_ALLOW=all is for the container smoke test only.
  [[ "${HC_INGRESS_ALLOW:-}" == "all" ]] && allow=""
  # Only root sets the upstream, but a character with a meaning to sed or to
  # nginx would give a broken configuration, and with it no panel.
  if [[ ! "$upstream" =~ ^https?://[A-Za-z0-9._:/-]+$ ]]; then
    log "proxy: the upstream is not usable; using $HC_MCP_DEFAULT"
    upstream="$HC_MCP_DEFAULT"
  fi
  sed -e "s|__ALLOW__|$allow|" \
      -e "s|__RESOLVER__|$(proxy_resolver)|" \
      -e "s|__UPSTREAM__|$upstream|" \
      -e "s|__AUTH__|$HC_PROXY_DIR/proxy-auth.conf|" "$1"
}

# Asks Home Assistant once through the listener and logs the status code,
# and nothing else of the answer. What the codes mean is in DOCS.md.
check_proxy() {
  local code=""
  code="$(curl -s -o /dev/null -m 15 -w '%{http_code}' -X POST \
            -H 'Content-Type: application/json' \
            -H 'Accept: application/json, text/event-stream' \
            -d '{"jsonrpc":"2.0","id":1,"method":"ping"}' \
            http://127.0.0.1:7684/mcp 2>/dev/null)" || code=""
  log "proxy: Home Assistant answered ${code:-nothing} through the listener"
}
