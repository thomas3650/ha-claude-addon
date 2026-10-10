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
