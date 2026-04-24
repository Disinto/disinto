# Multi-stage build: Nomad 1.8+ is glibc-fortified and requires __vdprintf_chk,
# which Alpine's musl (and gcompat / sgerrand's alpine-pkg-glibc) do not provide
# (#699). Switch the runtime base to frolvlad/alpine-glibc, which ships a full
# glibc with FORTIFY support, and copy Caddy from the official image so the
# Caddy build stays identical to what `caddy:latest` ships.
FROM caddy:latest AS caddy-src

FROM frolvlad/alpine-glibc
COPY --from=caddy-src /usr/bin/caddy         /usr/bin/caddy
COPY --from=caddy-src /etc/caddy/Caddyfile   /etc/caddy/Caddyfile
COPY --from=caddy-src /usr/share/caddy/      /usr/share/caddy/
RUN apk add --no-cache bash jq curl git docker-cli python3 py3-pip openssh-client autossh \
    nodejs npm unzip
# Voice bridge (#662): isolated venv so Alpine's system Python stays clean.
# google-genai provides the Gemini Live client; websockets is the asyncio
# server used by docker/voice/bridge.py. Invoked from entrypoint-edge.sh as
# `/opt/voice-venv/bin/python3 /usr/local/bin/voice-bridge.py`.
RUN python3 -m venv /opt/voice-venv && \
    /opt/voice-venv/bin/pip install --no-cache-dir \
        "google-genai>=0.8.0" \
        "websockets>=12.0"
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
# Voice bridge — Gemini Live ↔ `think` tool ↔ claude -r (#662)
COPY docker/voice/bridge.py /usr/local/bin/voice-bridge.py
# Voice UI — mic + Silero VAD + WebSocket client (#663). Caddy serves
# /voice/ and /voice/static/* directly out of /var/voice/ui via file_server
# (see Caddyfile in nomad/jobs/edge.hcl); no chat-server.py path involvement.
COPY docker/voice/ui/ /var/voice/ui/

VOLUME /data

ENTRYPOINT ["bash", "/usr/local/bin/entrypoint-edge.sh"]
