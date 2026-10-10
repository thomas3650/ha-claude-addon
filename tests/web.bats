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
