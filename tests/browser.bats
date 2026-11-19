load helpers

# ha-claude-browser-mcp: Playwright MCP with fixed flags. A stand-in server
# writes down how it was started; the real browser is the container test's.

W="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/ha-claude-browser-mcp"

# stub - a stand-in server that writes down its environment and arguments,
# and W2, a copy of the wrapper that starts it in place of the real one.
stub() {
  STUB="$BATS_TEST_TMPDIR/playwright-mcp"
  printf '#!/bin/sh\nenv > "%s/env"\nprintf "%%s\\n" "$PLAYWRIGHT_BROWSERS_PATH" "$@" > "%s/args"\n' \
    "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" > "$STUB"
  chmod +x "$STUB"
  W2="$BATS_TEST_TMPDIR/wrapper"
  sed "s#/usr/local/bin/playwright-mcp#$STUB#" "$W" > "$W2"
  chmod +x "$W2"
}

@test "the wrapper is executable in git and passes shellcheck" {
  [ "$(git -C "$BATS_TEST_DIRNAME/.." ls-files -s -- ha-claude/rootfs/usr/local/bin/ha-claude-browser-mcp | cut -c1-6)" = 100755 ]
  shellcheck "$W"
}

@test "it starts the server with the sandbox on, a profile in memory, no page tools, no snapshot files and no images" {
  [ "$(id -u)" -ne 0 ] || skip "the wrapper refuses root; runs as another user in CI"
  stub
  HOME="$BATS_TEST_TMPDIR/home" run "$W2"
  [ "$status" -eq 0 ]
  [ "$(head -n 1 "$BATS_TEST_TMPDIR/args")" = /usr/share/ha-claude/browsers ]
  args="$(tail -n +2 "$BATS_TEST_TMPDIR/args")"
  for f in --browser chromium --headless --isolated --sandbox --no-webmcp --snapshot-mode none --image-responses omit; do
    grep -qxF -- "$f" <<<"$args" || { echo "no $f"; false; }
  done
  ! grep -qx -- --no-sandbox <<<"$args"
  ! grep -q -- --caps <<<"$args"
  grep -qxF -- "$BATS_TEST_TMPDIR/home/.cache/ha-claude/browser" <<<"$args"
}

@test "arguments given to it are not passed on" {
  [ "$(id -u)" -ne 0 ] || skip "the wrapper refuses root; runs as another user in CI"
  stub
  HOME="$BATS_TEST_TMPDIR/home" run "$W2" --no-sandbox --caps devtools --user-data-dir /x
  [ "$status" -eq 0 ]
  ! grep -qx -- --no-sandbox "$BATS_TEST_TMPDIR/args"
  ! grep -q -- devtools "$BATS_TEST_TMPDIR/args"
  ! grep -q -- --user-data-dir "$BATS_TEST_TMPDIR/args"
}

@test "the caller's environment does not reach the server, nor a browsers folder of its own" {
  [ "$(id -u)" -ne 0 ] || skip "the wrapper refuses root; runs as another user in CI"
  stub
  HOME="$BATS_TEST_TMPDIR/home" PLAYWRIGHT_MCP_CONFIG=/x PLAYWRIGHT_MCP_CDP_ENDPOINT=ws://x NODE_OPTIONS=--require=/x \
    PLAYWRIGHT_BROWSERS_PATH=/elsewhere PATH="/elsewhere:$PATH" run "$W2"
  [ "$status" -eq 0 ]
  ! grep -q '^PLAYWRIGHT_MCP_' "$BATS_TEST_TMPDIR/env"
  ! grep -q '^NODE_OPTIONS=' "$BATS_TEST_TMPDIR/env"
  grep -qx 'PATH=/usr/local/bin:/usr/bin:/bin' "$BATS_TEST_TMPDIR/env"
  grep -qx 'PLAYWRIGHT_BROWSERS_PATH=/usr/share/ha-claude/browsers' "$BATS_TEST_TMPDIR/env"
}

@test "as root it refuses to start" {
  [ "$(id -u)" -eq 0 ] || skip "needs root"
  stub
  run "$W2"
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/args" ]
}

@test "the image pins Playwright MCP and installs only its headless Chromium" {
  D="$BATS_TEST_DIRNAME/../ha-claude/Dockerfile"
  grep -qE '^ARG PLAYWRIGHT_MCP_VERSION=[0-9]+\.[0-9]+\.[0-9]+$' "$D"
  grep -qF 'playwright-mcp install-browser --with-deps --only-shell chromium' "$D"
  grep -qF 'ENV PLAYWRIGHT_BROWSERS_PATH=/usr/share/ha-claude/browsers' "$D"
}
