FROM node:22-bookworm-slim AS node

FROM ubuntu:24.04

ARG BUILD_VERSION=dev
ARG BUILD_ARCH=unknown
ARG CLAUDE_CODE_VERSION=2.1.295

ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq nginx-light openssh-client procps tmux ttyd tzdata util-linux \
 && rm -rf /var/lib/apt/lists/* /etc/nginx/sites-enabled/default \
 && ttyd --version

COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && npm cache clean --force \
 && claude --version | grep -F "${CLAUDE_CODE_VERSION}"

RUN useradd --no-create-home --home-dir /data/home --shell /bin/bash --uid 1500 claude

COPY rootfs/ /

LABEL io.hass.version="${BUILD_VERSION}" io.hass.type="app" io.hass.arch="${BUILD_ARCH}"

CMD ["/usr/local/bin/addon-run"]
