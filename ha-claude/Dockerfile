# Both base images are named by digest, so the same Dockerfile builds the
# same image on any day. The weekly workflow moves them, with Claude Code.
FROM node:22-bookworm-slim@sha256:5ec23b7c622b00547753bc6ffd78085dd868a68aeb41c8e0a1418f033e13d96d AS node

FROM ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852

ARG BUILD_VERSION=dev
ARG BUILD_ARCH=unknown
ARG CLAUDE_CODE_VERSION=2.1.319
ARG PLAYWRIGHT_MCP_VERSION=0.0.84

ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq mosquitto-clients nginx-light openssh-client poppler-utils procps tmux ttyd tzdata util-linux \
 && rm -rf /var/lib/apt/lists/* /etc/nginx/sites-enabled/default \
 && ttyd --version \
 && command -v pdftoppm

COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && npm cache clean --force \
 && claude --version | grep -F "${CLAUDE_CODE_VERSION}"

# The browser: Playwright MCP, pinned, and the headless Chromium its own
# Playwright names, with the libraries it needs, in a folder root owns and
# every user can read and no one but root can write.
ENV PLAYWRIGHT_BROWSERS_PATH=/usr/share/ha-claude/browsers
RUN npm install -g "@playwright/mcp@${PLAYWRIGHT_MCP_VERSION}" \
 && apt-get update \
 && playwright-mcp install-browser --with-deps --only-shell chromium \
 && shell="$(find "$PLAYWRIGHT_BROWSERS_PATH" -path '*chromium_headless_shell-*' -type f -name chrome-headless-shell | head -n 1)" \
 && [ -x "$shell" ] && ln -s "$shell" "$PLAYWRIGHT_BROWSERS_PATH/chrome-headless-shell" \
 && rm -rf /var/lib/apt/lists/* \
 && npm cache clean --force \
 && chown -R root:root "$PLAYWRIGHT_BROWSERS_PATH" /usr/local/lib/node_modules/@playwright \
 && chmod -R a+rX,go-w "$PLAYWRIGHT_BROWSERS_PATH" /usr/local/lib/node_modules/@playwright \
 && playwright-mcp --version | grep -F "${PLAYWRIGHT_MCP_VERSION}"

RUN useradd --no-create-home --home-dir /data/home --shell /bin/bash --uid 1500 claude

COPY rootfs/ /
COPY schemas/ /usr/share/ha-claude/schemas/

LABEL io.hass.version="${BUILD_VERSION}" io.hass.type="app" io.hass.arch="${BUILD_ARCH}"

CMD ["/usr/local/bin/addon-run"]
