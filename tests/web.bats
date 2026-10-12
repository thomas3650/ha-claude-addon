load helpers
# The page the panel opens: a bar with two links over one terminal.
PAGE="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/share/ha-claude/index.html"
CONF="$BATS_TEST_DIRNAME/../ha-claude/rootfs/etc/nginx/templates/ingress.conf.tpl"

@test "the page offers Claude and a shell" {
  grep -q 'claude/' "$PAGE"
  grep -q 'shell/' "$PAGE"
}

@test "the page uses relative addresses only, so it works behind Ingress" {
  run grep -n -E '(href|src|action)="(/|https?:)' "$PAGE"
  [ "$status" -eq 1 ]
}

@test "the page loads nothing from outside the add-on" {
  run grep -n -i -E 'https?://|<script[^>]+src=|<link ' "$PAGE"
  [ "$status" -eq 1 ]
}

@test "nginx serves the page and both terminals, and keeps the allow-list" {
  grep -q 'location = /' "$CONF"
  grep -q 'location /claude/' "$CONF"
  grep -q 'location /shell/' "$CONF"
  grep -q '__ALLOW__' "$CONF"
}

@test "nginx answers nothing but the page and the two terminals" {
  grep -q 'location / { return 404; }' "$CONF"
}

@test "the second listener is on the container's own loopback only" {
  grep -q 'listen 127.0.0.1:7684;' "$CONF"
  [ "$(grep -c 'listen ' "$CONF")" -eq 2 ]
}

@test "the second listener forwards one address, POST only, and answers everything else itself" {
  block="$(sed -n '/listen 127.0.0.1:7684;/,$p' "$CONF")"
  grep -q 'location = /mcp {' <<<"$block"
  grep -q 'if ($request_method != POST) { return 405; }' <<<"$block"
  grep -q 'location / { return 404; }' <<<"$block"
  [ "$(grep -c 'location ' <<<"$block")" -eq 2 ]
  [ "$(grep -c 'proxy_pass ' <<<"$block")" -eq 1 ]
}

@test "the upstream is a variable, so a name that does not resolve cannot stop nginx" {
  grep -q 'set $mcp_upstream "__UPSTREAM__";' "$CONF"
  grep -q 'proxy_pass $mcp_upstream;' "$CONF"
  grep -q 'resolver __RESOLVER__ ' "$CONF"
}

@test "the token is not in the template: it comes from an included file" {
  grep -q 'include __AUTH__;' "$CONF"
  run grep -i 'bearer\|authorization' "$CONF"
  [ "$status" -eq 1 ]
}

@test "the token file is for root only and sets the header" {
  load_lib web
  export HC_PROXY_DIR="$BATS_TEST_TMPDIR/run" SUPERVISOR_TOKEN="tok-123.abc_DEF"
  write_proxy_auth
  [ "$(cat "$HC_PROXY_DIR/proxy-auth.conf")" = 'proxy_set_header Authorization "Bearer tok-123.abc_DEF";' ]
  mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
  [ "$(mode "$HC_PROXY_DIR/proxy-auth.conf")" = "600" ]
  [ "$(mode "$HC_PROXY_DIR")" = "700" ]
}

@test "a token file left with a wider mode is replaced, not written into" {
  load_lib web
  export HC_PROXY_DIR="$BATS_TEST_TMPDIR/run" SUPERVISOR_TOKEN="tok-123"
  mkdir -p "$HC_PROXY_DIR"
  echo old > "$HC_PROXY_DIR/proxy-auth.conf"
  chmod 644 "$HC_PROXY_DIR/proxy-auth.conf"
  write_proxy_auth
  [ "$(stat -c %a "$HC_PROXY_DIR/proxy-auth.conf" 2>/dev/null || stat -f %Lp "$HC_PROXY_DIR/proxy-auth.conf")" = "600" ]
  grep -q 'Bearer tok-123' "$HC_PROXY_DIR/proxy-auth.conf"
}

@test "a token file that cannot be written is logged" {
  load_lib web
  export HC_PROXY_DIR="$BATS_TEST_TMPDIR/file/run" SUPERVISOR_TOKEN="tok-123"
  : > "$BATS_TEST_TMPDIR/file"
  run write_proxy_auth
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not be written"* ]]
  [[ "$output" != *"tok-123"* ]]
}

@test "without a token, or with one that could end the string, the header is set empty" {
  load_lib web
  export HC_PROXY_DIR="$BATS_TEST_TMPDIR/run"
  unset SUPERVISOR_TOKEN
  write_proxy_auth 2>/dev/null
  [ "$(cat "$HC_PROXY_DIR/proxy-auth.conf")" = 'proxy_set_header Authorization "";' ]
  export SUPERVISOR_TOKEN='x"; return 200; #'
  run write_proxy_auth
  [[ "$output" == *"not usable"* ]]
  [[ "$output" != *"return 200"* ]]
  [ "$(cat "$HC_PROXY_DIR/proxy-auth.conf")" = 'proxy_set_header Authorization "";' ]
}

@test "the name server comes from the container's own settings, with a default" {
  load_lib web
  printf 'search local\nnameserver fe80::1\nnameserver 172.30.32.3\nnameserver 1.1.1.1\n' > "$BATS_TEST_TMPDIR/resolv"
  HC_RESOLV="$BATS_TEST_TMPDIR/resolv"
  [ "$(proxy_resolver)" = "172.30.32.3" ]
  HC_RESOLV="$BATS_TEST_TMPDIR/none"
  [ "$(proxy_resolver)" = "127.0.0.11" ]
}

@test "the configuration is the template with every mark replaced" {
  load_lib web
  export HC_PROXY_DIR="$BATS_TEST_TMPDIR/run" HC_RESOLV="$BATS_TEST_TMPDIR/none"
  out="$(render_nginx_conf "$CONF")"
  run grep '__[A-Z]*__' <<<"$out"
  [ "$status" -eq 1 ]
  grep -q 'allow 172.30.32.2; deny all;' <<<"$out"
  grep -q 'set $mcp_upstream "http://supervisor/core/api/mcp";' <<<"$out"
  grep -q "include $HC_PROXY_DIR/proxy-auth.conf;" <<<"$out"
  grep -q 'resolver 127.0.0.11 ' <<<"$out"
  HC_INGRESS_ALLOW=all HC_MCP_UPSTREAM=http://127.0.0.1:1/x run render_nginx_conf "$CONF"
  [[ "$output" != *"deny all"* ]]
  [[ "$output" == *'set $mcp_upstream "http://127.0.0.1:1/x";'* ]]
}

@test "an upstream with a character that would change the configuration is replaced by the default" {
  load_lib web
  export HC_PROXY_DIR="$BATS_TEST_TMPDIR/run" HC_RESOLV="$BATS_TEST_TMPDIR/none"
  for bad in 'http://h/a?x=1&y=2' 'http://h/a|b' 'http://h/"; return 200; #' 'file:///etc/passwd'; do
    HC_MCP_UPSTREAM="$bad" run render_nginx_conf "$CONF"
    [[ "$output" == *'set $mcp_upstream "http://supervisor/core/api/mcp";'* ]]
    [[ "$output" == *"not usable"* ]]
  done
}

@test "the check at start logs how Home Assistant answered, and only the status code" {
  load_lib web
  curl() { printf '%s\n' "$*" > "$BATS_TEST_TMPDIR/curl-args"; printf '404'; }
  run check_proxy
  [[ "$output" == *"proxy: Home Assistant answered 404 through the listener"* ]]
  grep -q -- '-X POST' "$BATS_TEST_TMPDIR/curl-args"
  grep -q 'http://127.0.0.1:7684/mcp' "$BATS_TEST_TMPDIR/curl-args"
  curl() { return 7; }
  run check_proxy
  [[ "$output" == *"answered nothing"* ]]
}

@test "the terminals are not buffered, so nginx writes no temporary files for them" {
  for where in /claude/ /shell/; do
    sed -n "\\|location $where {|,/}/p" "$CONF" | grep -q 'proxy_buffering off;'
  done
}

@test "when Home Assistant answers, the names of the tools it offers are logged, and nothing else" {
  load_lib web
  curl() {
    if [[ "$*" == *tools/list* ]]; then
      printf '%s' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"HassTurnOn","description":"secret words"},{"name":"GetLiveContext"},{"name":"bad name; rm"},{"name":"two\\nlines"},{"name":7}]}}'
    else
      printf '200'
    fi
  }
  run check_proxy
  [[ "$output" == *"answered 200 through the listener"* ]]
  [[ "$output" == *"proxy: Home Assistant offers these tools: HassTurnOn GetLiveContext"* ]]
  [[ "$output" != *"secret words"* ]]
  [[ "$output" == *"offers these tools: HassTurnOn GetLiveContext" ]]
  [[ "$output" != *"rm"* ]]
  [[ "$output" != *"lines"* ]]
}

@test "an answer sent as an event stream is read too, and no tool list is asked for after an error" {
  load_lib web
  curl() {
    if [[ "$*" == *tools/list* ]]; then
      printf 'event: message\ndata: {"result":{"tools":[{"name":"HassTurnOff"}]}}\n\n'
    else
      printf '200'
    fi
  }
  run check_proxy
  [[ "$output" == *"offers these tools: HassTurnOff" ]]
  curl() { [[ "$*" != *tools/list* ]] || echo asked >> "$BATS_TEST_TMPDIR/asked"; printf '404'; }
  run check_proxy
  [ ! -e "$BATS_TEST_TMPDIR/asked" ]
  [[ "$output" != *"offers"* ]]
}

@test "extra_mcp entries render one POST-only location each, without the token" {
  load_lib options web
  export HC_PROXY_DIR="$BATS_TEST_TMPDIR/run" HC_RESOLV="$BATS_TEST_TMPDIR/none"
  set_options '{"extra_mcp":["tools=http://my-mcp:8000/private_x1","two=https://h:1/p"]}'
  out="$(render_nginx_conf "$CONF")"
  run grep '__[A-Z_]*__' <<<"$out"
  [ "$status" -eq 1 ]
  grep -q 'location = /mcp/tools {' <<<"$out"
  grep -q 'location = /mcp/two {' <<<"$out"
  block="$(sed -n '/location = \/mcp\/tools {/,/^    }/p' <<<"$out")"
  grep -q 'if ($request_method != POST) { return 405; }' <<<"$block"
  grep -q 'set $mcp_upstream_tools "http://my-mcp:8000/private_x1";' <<<"$block"
  grep -q 'proxy_pass $mcp_upstream_tools;' <<<"$block"
  grep -q "include $HC_PROXY_DIR/extra-auth-tools.conf;" <<<"$block"
  run grep -i 'bearer\|proxy_set_header Authorization\|proxy-auth.conf' <<<"$block"
  [ "$status" -eq 1 ]
  grep -q 'error_log stderr crit;' <<<"$block"
  grep -q 'proxy_read_timeout 300s;' <<<"$block"
  grep -q 'proxy_buffering off;' <<<"$block"
  [ "$(grep -c 'location ' <<<"$out")" -eq 8 ]
}

@test "an https upstream is sent its name and its certificate is checked; an http one has neither line" {
  load_lib options web
  export HC_PROXY_DIR="$BATS_TEST_TMPDIR/run" HC_RESOLV="$BATS_TEST_TMPDIR/none"
  set_options '{"extra_mcp":["plain=http://my-mcp:8000/x","safe=https://api.example.com/mcp/x"]}'
  out="$(render_nginx_conf "$CONF")"
  safe="$(sed -n '/location = \/mcp\/safe {/,/^    }/p' <<<"$out")"
  grep -q 'proxy_ssl_server_name on;' <<<"$safe"
  grep -q 'proxy_ssl_verify on;' <<<"$safe"
  grep -q 'proxy_ssl_verify_depth 4;' <<<"$safe"
  grep -q 'proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;' <<<"$safe"
  plain="$(sed -n '/location = \/mcp\/plain {/,/^    }/p' <<<"$out")"
  run grep 'proxy_ssl' <<<"$plain"
  [ "$status" -eq 1 ]
}

@test "every extra entry gets a root-only header file: its token from extra_mcp_auth, or the empty header" {
  load_lib options web
  export HC_PROXY_DIR="$BATS_TEST_TMPDIR/run"
  set_options '{"extra_mcp":["tools=http://h/a","safe=https://h/b"],"extra_mcp_auth":["safe=tok_123.abc-DEF"]}'
  mkdir -p "$HC_PROXY_DIR"; echo stale > "$HC_PROXY_DIR/extra-auth-gone.conf"
  write_extra_auth
  [ "$(cat "$HC_PROXY_DIR/extra-auth-safe.conf")" = 'proxy_set_header Authorization "Bearer tok_123.abc-DEF";' ]
  [ "$(cat "$HC_PROXY_DIR/extra-auth-tools.conf")" = 'proxy_set_header Authorization "";' ]
  [ ! -e "$HC_PROXY_DIR/extra-auth-gone.conf" ]
  mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
  [ "$(mode "$HC_PROXY_DIR/extra-auth-safe.conf")" = "600" ]
  [ "$(mode "$HC_PROXY_DIR")" = "700" ]
  # Every location's include exists.
  out="$(render_nginx_conf "$CONF")"
  while IFS= read -r f; do [ -f "$f" ]; done < <(sed -n 's/^ *include \(.*extra-auth-.*\);$/\1/p' <<<"$out")
  [ "$(grep -c 'extra-auth-' <<<"$out")" -eq 2 ]
}

@test "a token that could end the string is not used and never logged; a token for no entry is logged by its name" {
  load_lib options web
  export HC_PROXY_DIR="$BATS_TEST_TMPDIR/run"
  set_options "$(jq -cn '{extra_mcp: ["safe=https://h/b"], extra_mcp_auth: ["safe=x\"; return 200; #", "other=s3cret", "nonamesecret", "BAD NAME=s3cret2"]}')"
  run write_extra_auth
  [ "$status" -eq 0 ]
  [ "$(cat "$HC_PROXY_DIR/extra-auth-safe.conf")" = 'proxy_set_header Authorization "";' ]
  [[ "$output" == *"the token for 'safe' is not usable"* ]]
  [[ "$output" == *"ignoring extra_mcp_auth entry 'other'"* ]]
  [[ "$output" == *"no usable name"* ]]
  [[ "$output" != *"return 200"* && "$output" != *"s3cret"* && "$output" != *"nonamesecret"* ]]
  [ ! -e "$HC_PROXY_DIR/extra-auth-other.conf" ]
}

@test "the token of an extra entry is in no rendered configuration and the Supervisor's token is in no extra file" {
  load_lib options web
  export HC_PROXY_DIR="$BATS_TEST_TMPDIR/run" HC_RESOLV="$BATS_TEST_TMPDIR/none" SUPERVISOR_TOKEN=sup-tok
  set_options '{"extra_mcp":["safe=https://h/b"],"extra_mcp_auth":["safe=ext-tok"]}'
  write_proxy_auth; write_extra_auth
  out="$(render_nginx_conf "$CONF")"
  run grep 'ext-tok\|sup-tok' <<<"$out"
  [ "$status" -eq 1 ]
  run grep 'sup-tok' "$HC_PROXY_DIR/extra-auth-safe.conf"
  [ "$status" -eq 1 ]
}

@test "without extra_mcp the marker is replaced by nothing" {
  load_lib options web
  export HC_PROXY_DIR="$BATS_TEST_TMPDIR/run" HC_RESOLV="$BATS_TEST_TMPDIR/none"
  out="$(render_nginx_conf "$CONF")"
  run grep '__[A-Z_]*__' <<<"$out"
  [ "$status" -eq 1 ]
  [ "$(grep -c 'location ' <<<"$out")" -eq 6 ]
}

@test "a bad extra_mcp entry is skipped and logged by its name only" {
  load_lib options web
  export HC_PROXY_DIR="$BATS_TEST_TMPDIR/run" HC_RESOLV="$BATS_TEST_TMPDIR/none"
  for bad in 'x=http://h/a?b=1' 'x=http://h/a;b' 'x=http://h/a|b' 'x=http://h/"; return 200; #' 'X=http://h/a' 'x y=http://h/a' '=http://h/a' 'x=file:///etc/passwd' 'x=http://h/a}'; do
    set_options "$(jq -cn --arg e "$bad" '{extra_mcp: [$e]}')"
    run render_nginx_conf "$CONF"
    [[ "$output" != *"location = /mcp/"* ]]
    [[ "$output" == *"ignoring extra_mcp entry"* || "$output" == *"no usable name"* ]]
    [[ "$output" != *"return 200"* ]]
    [[ "$output" != *"passwd"* ]]
  done
}

@test "HC_EXTRA_MCP overrides the option, for the smoke test" {
  load_lib options web
  export HC_PROXY_DIR="$BATS_TEST_TMPDIR/run" HC_RESOLV="$BATS_TEST_TMPDIR/none"
  set_options '{"extra_mcp":["tools=http://h/a"]}'
  HC_EXTRA_MCP=$'x=http://127.0.0.1:7691/s\ny=http://127.0.0.1:7692/t' run render_nginx_conf "$CONF"
  [[ "$output" == *"location = /mcp/x {"* ]]
  [[ "$output" == *"location = /mcp/y {"* ]]
  [[ "$output" != *"location = /mcp/tools {"* ]]
}

@test "each extra_mcp entry is probed at start with a handshake, and its tools are logged by the entry's name" {
  load_lib options web
  set_options '{"extra_mcp":["tools=http://h:1/private_s3cret"]}'
  curl() {
    printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/curl-args"
    if [[ "$*" == *initialize* ]]; then
      hf="$(awk '{for (i = 1; i <= NF; i++) if ($i == "-D") print $(i + 1)}' <<<"$*")"
      [[ -n "$hf" ]] && printf 'HTTP/1.1 200 OK\r\nMcp-Session-Id: sess-42\r\n\r\n' > "$hf"
      printf '200'
    elif [[ "$*" == *tools/list* ]]; then
      printf '%s' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"ha_get_state"},{"name":"ha_call_service"},{"name":"bad name"}]}}'
    fi
  }
  run check_extra_mcp
  [[ "$output" == *"proxy: tools answered 200 through the listener"* ]]
  [[ "$output" == *"proxy: tools offers these tools: ha_get_state ha_call_service"* ]]
  [[ "$output" != *"private_s3cret"* ]]
  [[ "$output" != *"bad name"* ]]
  grep -q 'http://127.0.0.1:7684/mcp/tools' "$BATS_TEST_TMPDIR/curl-args"
  [ "$(grep -n 'notifications/initialized' "$BATS_TEST_TMPDIR/curl-args" | head -n 1 | cut -d: -f1)" -lt "$(grep -n 'tools/list' "$BATS_TEST_TMPDIR/curl-args" | head -n 1 | cut -d: -f1)" ]
  grep -q 'Mcp-Session-Id: sess-42' "$BATS_TEST_TMPDIR/curl-args"
}

@test "an extra entry that does not answer is logged as nothing, and no tool list is asked for" {
  load_lib options web
  set_options '{"extra_mcp":["tools=http://h:1/p"]}'
  curl() { [[ "$*" != *tools/list* ]] || echo asked >> "$BATS_TEST_TMPDIR/asked"; return 7; }
  run check_extra_mcp
  [[ "$output" == *"proxy: tools answered nothing through the listener"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/asked" ]
}

@test "the tool names of an extra entry are capped at 200" {
  load_lib options web
  set_options '{"extra_mcp":["tools=http://h:1/p"]}'
  many="$(jq -cn '[range(0; 250) | {name: ("t" + tostring)}] | {result: {tools: .}}')"
  curl() {
    if [[ "$*" == *initialize* ]]; then printf '200'
    elif [[ "$*" == *tools/list* ]]; then printf '%s' "$many"; fi
  }
  run check_extra_mcp
  [[ "$output" == *"t199"* ]]
  [[ "$output" != *"t200"* ]]
}

@test "a second entry with the same name is skipped, so nginx keeps starting; an entry without a name is logged without its value" {
  load_lib options web
  export HC_PROXY_DIR="$BATS_TEST_TMPDIR/run" HC_RESOLV="$BATS_TEST_TMPDIR/none"
  set_options '{"extra_mcp":["tools=http://h:1/a","tools=http://h:2/b","http://h:3/private_s3cret"]}'
  run render_nginx_conf "$CONF"
  [ "$(grep -c 'location = /mcp/tools {' <<<"$output")" -eq 1 ]
  [[ "$output" == *'set $mcp_upstream_tools "http://h:1/a";'* ]]
  [[ "$output" == *"ignoring a second extra_mcp entry named 'tools'"* ]]
  [[ "$output" == *"ignoring an extra_mcp entry with no usable name"* ]]
  [[ "$output" != *"private_s3cret"* ]]
  [[ "$output" != *"s3cret"* ]]
}
