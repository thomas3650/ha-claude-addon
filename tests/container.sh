#!/usr/bin/env bash
# Smoke test against a built image. Usage: tests/container.sh <image>
set -euo pipefail
image="$1"
name="hc-smoke-$$"
logs() { docker logs "$name" 2>&1; }
fail() { echo "FAIL: $*" >&2; logs >&2 || true; docker rm -f "$name" >/dev/null 2>&1; exit 1; }

docker run -d -i --name "$name" -e SUPERVISOR_TOKEN=smoke-secret -e HC_INGRESS_ALLOW=all "$image" >/dev/null

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

docker rm -f "$name" >/dev/null
echo "container smoke test passed"
