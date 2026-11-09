# Both base images are named by digest, so the same Dockerfile builds the
# same image on any day. The weekly workflow moves them, with Claude Code.
FROM node:22-bookworm-slim@sha256:5ec23b7c622b00547753bc6ffd78085dd868a68aeb41c8e0a1418f033e13d96d AS node

FROM ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852

ARG BUILD_VERSION=dev
ARG BUILD_ARCH=unknown
ARG CLAUDE_CODE_VERSION=2.1.319

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
