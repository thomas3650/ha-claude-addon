# The add-on's nginx: the panel's page and terminals, and Claude's way to
# Home Assistant. The second is a listener on the container's own loopback
# that forwards one address and adds the token Home Assistant gave the
# add-on. The token is kept in a file only root can read.
: "${HC_PROXY_DIR:=/run/ha-claude}"
HC_MCP_DEFAULT=http://supervisor/core/api/mcp
: "${HC_MCP_UPSTREAM:=$HC_MCP_DEFAULT}"
: "${HC_RESOLV:=/etc/resolv.conf}"
: "${HC_CA_BUNDLE:=/etc/ssl/certs/ca-certificates.crt}"

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
  local re='^[a-z][a-z0-9-]{0,31}=https?://[A-Za-z0-9._:/-]+$' entry name seen=" " quiet="${1:-}"
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    name="${entry%%=*}"
    if [[ ! "$entry" =~ $re ]]; then
      # The name is logged only when it is a name: an entry without "=" is
      # all "name", and may be a secret path.
      if [[ "$name" =~ ^[a-z][a-z0-9-]{0,31}$ ]]; then
        [[ "$quiet" == quiet ]] || log "proxy: ignoring extra_mcp entry '$name'"
      else
        [[ "$quiet" == quiet ]] || log "proxy: ignoring an extra_mcp entry with no usable name"
      fi
      continue
    fi
    # Two locations with one name would stop nginx, and with it the panel.
    if [[ "$seen" == *" $name "* ]]; then
      [[ "$quiet" == quiet ]] || log "proxy: ignoring a second extra_mcp entry named '$name'"
      continue
    fi
    seen+="$name "
    printf '%s\n' "$entry"
  done < <(if [[ -n "${HC_EXTRA_MCP:-}" ]]; then printf '%s\n' "$HC_EXTRA_MCP"
           elif [[ -f "$HC_OPTIONS" ]]; then jq -r '.extra_mcp[]? | strings' "$HC_OPTIONS" 2>/dev/null; fi)
}

# Prints the entries of the option extra_mcp_auth, one name=token per line.
# HC_EXTRA_MCP_AUTH, newline-separated, replaces the option for the tests.
_extra_mcp_auth_entries() {
  if [[ -n "${HC_EXTRA_MCP_AUTH:-}" ]]; then
    printf '%s\n' "$HC_EXTRA_MCP_AUTH"
  elif [[ -f "$HC_OPTIONS" ]]; then
    jq -r '.extra_mcp_auth[]? | strings' "$HC_OPTIONS" 2>/dev/null
  fi
}

# Prints the token extra_mcp_auth holds for one extra_mcp name, or nothing.
# Only a token made of characters that cannot end nginx's string, and short
# enough for nginx to take, is used. The first entry for a name counts; a
# second one is logged. Nothing of an entry is ever logged but the name of
# an extra_mcp entry, which the caller already knows to be one.
extra_mcp_token() {
  local want="$1" entry found=0
  while IFS= read -r entry; do
    [[ "$entry" == "$want="* ]] || continue
    if (( found )); then
      log "proxy: ignoring a second extra_mcp_auth entry for '$want'"
      continue
    fi
    found=1
    entry="${entry#*=}"
    if [[ "$entry" =~ ^[A-Za-z0-9._~+/=-]+$ ]] && (( ${#entry} <= 2048 )); then
      printf '%s' "$entry"
    else
      log "proxy: the token for '$want' is not usable; none is sent"
    fi
  done < <(_extra_mcp_auth_entries)
}

# Writes, for every extra_mcp entry, the file its location includes: the
# Authorization header with the entry's token from extra_mcp_auth, or the
# empty header when it has none. Every entry gets a file, because nginx does
# not start without an included file, and with it goes the panel. The files
# are for root only and made new each time, like the Supervisor token's. A
# token for a name that is no extra_mcp entry is counted in the log and not
# named: an entry pasted without its name would be logged as one.
write_extra_auth() {
  local entry name upstream token line known=" " file stray=0
  if ! { mkdir -p "$HC_PROXY_DIR" && chmod 700 "$HC_PROXY_DIR"; }; then
    log "proxy: the folder for the token files could not be made; nginx will not start"
    return 1
  fi
  rm -f "$HC_PROXY_DIR"/extra-auth-*.conf
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    name="${entry%%=*}"
    upstream="${entry#*=}"
    known+="$name "
    token="$(extra_mcp_token "$name")"
    line='proxy_set_header Authorization "";'
    if [[ -n "$token" ]]; then
      line="proxy_set_header Authorization \"Bearer $token\";"
      [[ "$upstream" == https://* ]] || log "proxy: the token for '$name' is sent over http, unencrypted"
    fi
    file="$HC_PROXY_DIR/extra-auth-$name.conf"
    if ! ( umask 077; printf '%s\n' "$line" > "$file" ); then
      log "proxy: the token file for '$name' could not be written; nginx will not start"
      return 1
    fi
  done < <(extra_mcp_entries quiet)
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    name="${entry%%=*}"
    [[ "$entry" == *=* && "$known" == *" $name "* ]] || stray=$((stray + 1))
  done < <(_extra_mcp_auth_entries)
  (( stray )) && log "proxy: ignoring $stray extra_mcp_auth entry(ies) that name no extra_mcp entry"
  return 0
}

# Prints one nginx location per extra_mcp entry: POST only, the upstream's
# errors kept out of the log, a longer read timeout than /mcp. The
# Authorization header comes from the entry's included file (see
# write_extra_auth): the Supervisor's token is never sent. An https
# upstream is sent its own name and its certificate is checked against the
# system's authorities; without that, anything that answered would be taken
# for it.
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
    printf '      include %s/extra-auth-%s.conf;\n' "$HC_PROXY_DIR" "$name"
    if [[ "$upstream" == https://* ]]; then
      printf '      proxy_ssl_server_name on;\n'
      printf '      proxy_ssl_verify on;\n'
      printf '      proxy_ssl_verify_depth 4;\n'
      printf '      proxy_ssl_trusted_certificate %s;\n' "$HC_CA_BUNDLE"
    fi
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

# Posts one MCP request through the listener. Arguments: the method, the
# address, the JSON params, then curl options.
_proxy_post() {
  local method="$1" url="$2" params="$3"; shift 3
  curl -s -m 15 -X POST \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\",\"params\":$params}" \
    "$@" "$url" 2>/dev/null
}

# Posts one MCP notification through the listener: no id, no answer
# expected. Arguments: the method, the address, then curl options.
_proxy_notify() {
  local method="$1" url="$2"; shift 2
  curl -s -m 15 -X POST \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\"}" \
    "$@" -o /dev/null "$url" 2>/dev/null
}

# Reads the tool names out of an answer, plain or as an event stream: only
# names made of letters, digits, "_" and "-", at most the given number, on
# one line.
_tool_names() {
  sed -n -e 's/^data: \{0,1\}//' -e '/^{/p' \
    | jq -r --argjson n "$1" '[.result.tools[]?.name? | strings | select(test("^[A-Za-z0-9_-]{1,64}$"))] | .[:$n] | join(" ")' 2>/dev/null \
    | head -n 1 | grep -E '^[A-Za-z0-9_ -]+$'
}

# Asks Home Assistant once through the listener and logs the status code.
# What the codes mean is in DOCS.md. When Home Assistant answers, the names
# of the tools it offers are logged as well, since permission rules are
# written by tool name. Nothing else of an answer is logged. A script that
# is exposed is offered as a tool named after it, as script__<name> since
# Home Assistant 2026.9.
check_proxy() {
  local code="" names=""
  code="$(_proxy_post ping http://127.0.0.1:7684/mcp '{}' -o /dev/null -w '%{http_code}')" || code=""
  log "proxy: Home Assistant answered ${code:-nothing} through the listener"
  [[ "$code" == 2* ]] || return 0
  names="$(_proxy_post tools/list http://127.0.0.1:7684/mcp '{}' | _tool_names 80)" || names=""
  [[ -n "$names" ]] && log "proxy: Home Assistant offers these tools: $names"
  return 0
}

# Probes each extra_mcp entry the way an MCP client does: initialize, keep
# the session the server names, say that the client is initialized, then
# ask for the tools. Logs the entry's name only, never its upstream. A
# refused entry was already logged when the configuration was rendered.
check_extra_mcp() {
  local entry name url code headers session names
  local -a hdr
  local init='{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"ha-claude","version":"0"}}'
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    name="${entry%%=*}"
    url="http://127.0.0.1:7684/mcp/$name"
    headers="$(mktemp)"
    # The code is kept when one came back, also when curl then timed out
    # on a stream the server holds open.
    code="$(_proxy_post initialize "$url" "$init" -o /dev/null -w '%{http_code}' -D "$headers")" || true
    [[ "$code" =~ ^[0-9]{3}$ && "$code" != 000 ]] || code=""
    log "proxy: $name answered ${code:-nothing} through the listener"
    if [[ "$code" == 2* ]]; then
      session="$(grep -i '^mcp-session-id:' "$headers" | head -n 1 | sed 's/^[^:]*: *//' | tr -d '\r' | grep -E '^[A-Za-z0-9._-]{1,200}$')" || session=""
      hdr=()
      [[ -n "$session" ]] && hdr=(-H "Mcp-Session-Id: $session")
      _proxy_notify notifications/initialized "$url" "${hdr[@]}" || true
      names="$(_proxy_post tools/list "$url" '{}' "${hdr[@]}" | _tool_names 200)" || names=""
      [[ -n "$names" ]] && log "proxy: $name offers these tools: $names"
    fi
    rm -f "$headers"
  done < <(extra_mcp_entries quiet)
  return 0
}
