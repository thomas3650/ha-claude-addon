#!/usr/bin/env bash
# Smoke test against a built image. Usage: tests/container.sh <image>
set -euo pipefail
image="$1"
name="hc-smoke-$$"
logs() { docker logs "$name" 2>&1; }
fail() { echo "FAIL: $*" >&2; logs >&2 || true; docker rm -f "$name" >/dev/null 2>&1; exit 1; }

docker run -d -i --name "$name" -e SUPERVISOR_TOKEN=smoke-secret -e HC_INGRESS_ALLOW=all -e HC_MCP_UPSTREAM=http://mcp.invalid/api/mcp "$image" >/dev/null

for _ in $(seq 1 30); do
  grep -q "ready" <<<"$(logs)" && break
  sleep 1
done
grep -q "ready" <<<"$(logs)" || fail "the add-on never logged ready"

# Not logged in: the add-on stays up and says so.
status="$(docker exec "$name" ha-claude-status)"
grep -q "claude login: no" <<<"$status" || fail "expected 'claude login: no'"
grep -q "chat session: running" <<<"$status" || fail "the tmux session is not running"

# The status command also works in the web terminal, which runs as the Claude user.
status="$(docker exec -u claude "$name" ha-claude-status)"
grep -q "chat session: running" <<<"$status" || fail "the Claude user does not see the chat session"
grep -q "last sync: never (none)" <<<"$status" || fail "the Claude user cannot read the sync status"

# Ingress answers: the page with its two links, and a terminal behind each.
page="$(docker exec "$name" curl -fsS http://127.0.0.1:7681/)" || fail "nginx does not answer on 7681"
grep -q 'href="claude/"' <<<"$page" || fail "the page has no link to Claude"
grep -q 'href="shell/"' <<<"$page" || fail "the page has no link to the shell"
docker exec "$name" curl -fsS -o /dev/null http://127.0.0.1:7681/claude/ || fail "the Claude terminal does not answer"
docker exec "$name" curl -fsS -o /dev/null http://127.0.0.1:7681/shell/ || fail "the shell terminal does not answer"
docker exec "$name" curl -fsS -o /dev/null http://127.0.0.1:7681/claude/token || fail "the Claude terminal's own addresses do not work under its path"

# Claude's way to Home Assistant: one address, POST only. The upstream here
# is a name that does not exist: nginx has started all the same, and a POST
# is answered 502, which only a forwarded request gets. Anything the
# listener does not forward is its own 404 or 405.
code() { docker exec -u claude "$name" curl -s -m 20 -o /dev/null -w '%{http_code}' "$@"; }
[[ "$(code -X POST http://127.0.0.1:7684/mcp)" == 502 ]] || fail "the listener did not try to forward a POST to its one address"
[[ "$(code http://127.0.0.1:7684/mcp)" == 405 ]] || fail "the listener forwarded something other than a POST"
[[ "$(code -X POST http://127.0.0.1:7684/mcp/x)" == 404 ]] || fail "the listener forwarded a second address"
[[ "$(code -X POST http://127.0.0.1:7684/)" == 404 ]] || fail "the listener forwarded the root address"
for _ in $(seq 1 20); do
  grep -q "proxy: Home Assistant answered" <<<"$(logs)" && break
  sleep 1
done
grep -q "proxy: Home Assistant answered 502 through the listener" <<<"$(logs)" || fail "the check at start did not log the answer"

# The token is in a file the Claude user cannot read, and not in the
# configuration, which it can.
docker exec "$name" grep -q 'Bearer smoke-secret' /run/ha-claude/proxy-auth.conf || fail "the token file does not hold the token"
docker exec -u claude "$name" cat /run/ha-claude/proxy-auth.conf >/dev/null 2>&1 && fail "the Claude user can read the token file"
conf="$(docker exec -u claude "$name" cat /etc/nginx/nginx.conf)" || fail "the Claude user cannot read the nginx configuration"
grep -q 'mcp_upstream' <<<"$conf" || fail "the nginx configuration has no upstream"
if grep -q 'smoke-secret' <<<"$conf"; then fail "the token is in a file the Claude user can read"; fi
docker exec -u claude "$name" nginx -T >/dev/null 2>&1 && fail "the Claude user can have nginx print its configuration"

# The shell behind the second link runs as the Claude user, without the token.
who="$(docker exec "$name" /usr/local/bin/ha-claude-shell -c 'id -un; env | grep -c SUPERVISOR')" || true
[[ "$who" == $'claude\n0' ]] || fail "the web terminal's shell is not a clean shell for the Claude user: '$who'"

# Nothing owned by the Claude user can see the Supervisor token.
# Read as the Claude user: root in a container may not read another user's
# environment, and a check that cannot read must fail, not pass.
for pid in $(docker exec "$name" pgrep -u claude); do
  environ="$(docker exec -u claude "$name" sh -c "tr '\0' '\n' < /proc/$pid/environ")" \
    || fail "cannot read the environment of process $pid"
  grep -q "HOME=" <<<"$environ" || fail "the environment of process $pid is empty"
  if grep -q "smoke-secret\|SUPERVISOR_TOKEN" <<<"$environ"; then
    fail "process $pid of user claude has the Supervisor token"
  fi
done
docker exec "$name" pgrep -u claude tmux >/dev/null || fail "tmux is not running as claude"

# The Claude user cannot write the workspace or read the state folder.
docker exec "$name" runuser -u claude -- touch /data/workspace/assistant/x 2>/dev/null && fail "workspace is writable by claude"
docker exec "$name" runuser -u claude -- ls /data/state >/dev/null 2>&1 && fail "state is readable by claude"
docker exec "$name" runuser -u claude -- touch /data/handover/ok || fail "handover is not writable by claude"

# A session started from the web terminal is logged in the add-on's log.
# Without a terminal the attach itself fails; the start before it is the test.
docker exec "$name" bash -c 'runuser -u claude -- tmux -L hc kill-server; /usr/local/bin/ha-claude-attach' >/dev/null 2>&1 || true
grep -q "web terminal: no chat session, starting one" <<<"$(logs)" \
  || fail "a session started from the web terminal was not logged"
docker exec "$name" pgrep -u claude tmux >/dev/null || fail "the web terminal did not start the chat session"

# Managed settings: a file in the working folder is installed by the sync
# command, readable by the Claude user and not writable by it.
docker exec "$name" bash -c 'mkdir -p /data/workspace/assistant/.claude && echo "{\"smoke\":1}" > /data/workspace/assistant/.claude/managed-settings.json'
printf '"sync"\n' | timeout -s KILL 5 docker attach --sig-proxy=false "$name" >/dev/null 2>&1 || true
for _ in $(seq 1 20); do
  grep -q "outcome: sync=ok" <<<"$(logs)" && break
  sleep 1
done
docker exec "$name" runuser -u claude -- grep -q smoke /etc/claude-code/managed-settings.json \
  || fail "the Claude user cannot read the managed settings"
docker exec "$name" runuser -u claude -- sh -c 'echo x >> /etc/claude-code/managed-settings.json' 2>/dev/null \
  && fail "the Claude user can write the managed settings"

# Commands on standard input: unknown is ignored, ping is handled.
# KILL, because the Docker client does not exit on a single TERM.
printf '"nonsense"\n"ping"\n' | timeout -s KILL 5 docker attach --sig-proxy=false "$name" >/dev/null 2>&1 || true
for _ in $(seq 1 20); do
  grep -q "outcome: ping=ok" <<<"$(logs)" && break
  sleep 1
done
grep -q "ignoring unknown command" <<<"$(logs)" || fail "unknown command was not ignored"
grep -q "outcome: ping=ok" <<<"$(logs)" || fail "ping was not handled"
docker inspect -f '{{.State.Running}}' "$name" | grep -q true || fail "the add-on stopped"

# The morning command: with the agent in place and nobody logged in, the run
# fails or is stopped, the outcome is reported, the chat session is started
# again, and what the run printed is out of the Claude user's reach.
docker exec "$name" bash -c 'mkdir -p /data/workspace/assistant/.claude/agents && touch /data/workspace/assistant/.claude/agents/morning-briefing.md && echo "{\"morning_timeout\":20}" > /data/options.json'
starts_before="$(logs | grep -c 'chat: starting a new session')"
printf '"morning"\n' | timeout -s KILL 5 docker attach --sig-proxy=false "$name" >/dev/null 2>&1 || true
for _ in $(seq 1 90); do
  grep -q "outcome: morning=" <<<"$(logs)" && break
  sleep 1
done
grep -q -E "outcome: morning=(failed|timeout)" <<<"$(logs)" || fail "the morning command did not report failed or timeout"
docker exec "$name" test -f /data/state/morning.log || fail "the morning run's output was not kept"
docker exec "$name" runuser -u claude -- cat /data/state/morning.log >/dev/null 2>&1 && fail "the Claude user can read the morning run's output"
[[ "$(logs | grep -c 'chat: starting a new session')" -gt "$starts_before" ]] || fail "no new chat session after the morning command"
for _ in $(seq 1 10); do
  docker exec "$name" pgrep -u claude tmux >/dev/null && break
  sleep 1
done
docker exec "$name" pgrep -u claude tmux >/dev/null || fail "no chat session after the morning command"

# Retention: a handover file dated long ago is gone after a restart.
docker exec "$name" runuser -u claude -- touch /data/handover/1999-01-01.md /data/handover/keep.md
docker restart "$name" >/dev/null
for _ in $(seq 1 60); do
  [[ "$(logs | grep -c '\] ready$')" -ge 2 ]] && break
  sleep 1
done
[[ "$(logs | grep -c '\] ready$')" -ge 2 ]] || fail "the add-on did not log ready after the restart"
docker exec "$name" test ! -e /data/handover/1999-01-01.md || fail "an old handover file survived a restart"
docker exec "$name" test -e /data/handover/keep.md || fail "retention removed a file that is not a handover file"

docker rm -f "$name" >/dev/null

# What the listener sends on: a second container whose upstream is a
# stand-in that answers with the method, the address and the token it got.
# The token is the add-on's also when the client sent another, and the
# client's query string is dropped.
docker run -d -i --name "$name" -e SUPERVISOR_TOKEN=smoke-secret -e HC_INGRESS_ALLOW=all \
  -e HC_MCP_UPSTREAM=http://127.0.0.1:7690/core/api/mcp "$image" >/dev/null
for _ in $(seq 1 30); do
  grep -q "ready" <<<"$(logs)" && break
  sleep 1
done
docker exec -d "$name" node -e 'require("http").createServer((q, s) => s.end(q.method + " " + q.url + " " + (q.headers.authorization || "none"))).listen(7690, "127.0.0.1")'
sent=""
for _ in $(seq 1 10); do
  sent="$(docker exec -u claude "$name" curl -s -m 10 -X POST -H 'Authorization: Bearer other' -d '{}' 'http://127.0.0.1:7684/mcp?x=1')" || true
  [[ "$sent" == POST* ]] && break
  sleep 1
done
[[ "$sent" == "POST /core/api/mcp Bearer smoke-secret" ]] || fail "the listener sent on '$sent'"

docker rm -f "$name" >/dev/null
echo "container smoke test passed"
