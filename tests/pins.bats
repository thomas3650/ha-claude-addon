# What the build takes from outside is named exactly: the base images by
# digest, Claude Code by version, the workflow actions by commit.
ROOT="$BATS_TEST_DIRNAME/.."
DF="$ROOT/ha-claude/Dockerfile"
WF="$ROOT/.github/workflows"

@test "every image the Dockerfile builds on is named by tag and digest" {
  [ "$(grep -c '^FROM ' "$DF")" -eq 2 ]
  grep -qE '^FROM node:22-bookworm-slim@sha256:[0-9a-f]{64} AS node$' "$DF"
  grep -qE '^FROM ubuntu:24\.04@sha256:[0-9a-f]{64}$' "$DF"
  grep -qE '^ARG CLAUDE_CODE_VERSION=[0-9]+\.[0-9]+\.[0-9]+$' "$DF"
}

@test "the weekly workflow moves all three, with the patterns the Dockerfile has" {
  bump="$WF/bump-claude-code.yml"
  cp "$DF" "$BATS_TEST_TMPDIR/Dockerfile"
  new="sha256:$(printf '%064d' 7)"
  # The three expressions as the workflow has them, with its variables set.
  claude=9.8.7 node="$new" ubuntu="$new"
  sed -i.bak -E \
    -e "s/^ARG CLAUDE_CODE_VERSION=.*/ARG CLAUDE_CODE_VERSION=$claude/" \
    -e "s|^(FROM node:22-bookworm-slim)@sha256:[0-9a-f]{64}|\\1@$node|" \
    -e "s|^(FROM ubuntu:24.04)@sha256:[0-9a-f]{64}|\\1@$ubuntu|" "$BATS_TEST_TMPDIR/Dockerfile"
  grep -qx "FROM node:22-bookworm-slim@$new AS node" "$BATS_TEST_TMPDIR/Dockerfile"
  grep -qx "FROM ubuntu:24.04@$new" "$BATS_TEST_TMPDIR/Dockerfile"
  grep -qx "ARG CLAUDE_CODE_VERSION=9.8.7" "$BATS_TEST_TMPDIR/Dockerfile"
  [ "$(diff "$DF" "$BATS_TEST_TMPDIR/Dockerfile" | grep -c '^>')" -eq 3 ]
  # And the workflow holds those same three expressions.
  grep -qF 's/^ARG CLAUDE_CODE_VERSION=.*/ARG CLAUDE_CODE_VERSION=$claude/' "$bump"
  grep -qF 's|^(FROM node:22-bookworm-slim)@sha256:[0-9a-f]{64}|\\1@$node|' "$bump"
  grep -qF 's|^(FROM ubuntu:24.04)@sha256:[0-9a-f]{64}|\\1@$ubuntu|' "$bump"
}

@test "every action a workflow uses is named by its commit, with the version beside it" {
  [ "$(grep -h 'uses:' "$WF"/*.yml | wc -l)" -ge 6 ]
  run grep -hEvc 'uses: [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$' <(grep -h 'uses:' "$WF"/*.yml)
  [ "$output" -eq 0 ]
}

# perms JOB NEXT - the permission lines of one job of the release workflow.
perms() {
  sed -n "/^  $1:/,/^  ${2:-zzz}:/p" "$WF/release.yml" \
    | sed -n '/^    permissions:$/,/^    [a-z]/p' | grep '^      [a-z-]*: ' | sed 's/^ *//' | sort | tr '\n' ' '
}

@test "the release workflow gives nothing by default, and each job exactly what it uses" {
  grep -qx 'permissions: {}' "$WF/release.yml"
  [ "$(grep -c '^    permissions:$' "$WF/release.yml")" -eq 3 ]
  [ "$(perms release-please image)" = "contents: write issues: write pull-requests: write " ]
  [ "$(perms image publish)" = "contents: read packages: write " ]
  [ "$(perms publish)" = "contents: write packages: write " ]
  grep -qx '  contents: read' "$WF/ci.yml"
}
