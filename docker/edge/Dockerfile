FROM caddy:latest
RUN apk add --no-cache bash jq curl git docker-cli python3 openssh-client autossh \
    nodejs npm unzip
# Claude Code CLI — chat backend runtime (merged from docker/chat, #1083)
RUN npm install -g @anthropic-ai/claude-code@2.1.84
# Nomad CLI — chat-Claude factory control surface (#650). Pinned nomad binary
# for `nomad job ...` / `nomad alloc ...` calls via the Bash allow-list in
# chat-settings.json. Version should track the nomad server version deployed
# by lib/init/nomad/install.sh.
ARG NOMAD_VERSION=1.8.4
RUN set -eux; \
    arch="$(apk --print-arch)"; \
    case "$arch" in \
      x86_64)  nomad_arch=amd64 ;; \
      aarch64) nomad_arch=arm64 ;; \
      *) echo "unsupported arch for nomad: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_linux_${nomad_arch}.zip" -o /tmp/nomad.zip; \
    unzip -o /tmp/nomad.zip -d /usr/local/bin; \
    rm -f /tmp/nomad.zip; \
    chmod 0755 /usr/local/bin/nomad; \
    /usr/local/bin/nomad --version
COPY docker/edge/entrypoint-edge.sh /usr/local/bin/entrypoint-edge.sh
# Chat-Claude control surface (#650): settings.json + .mcp.json templates and
# the disinto-cli MCP wrapper. Templates are copied into $CHAT_WORKSPACE_DIR
# at container start by entrypoint-edge.sh.
COPY docker/edge/chat-settings.json /var/chat/config-templates/settings.json
COPY docker/edge/chat-mcp.json /var/chat/config-templates/mcp.json
COPY docker/edge/disinto-mcp /usr/local/bin/disinto-mcp
RUN chmod 0755 /usr/local/bin/disinto-mcp
# Chat server and UI (merged from docker/chat into edge, #1083)
COPY docker/chat/server.py /usr/local/bin/chat-server.py
COPY docker/chat/ui/ /var/chat/ui/

VOLUME /data

ENTRYPOINT ["bash", "/usr/local/bin/entrypoint-edge.sh"]
