# disinto-chat — minimal HTTP backend for Claude chat UI
#
# Small Debian slim base with Python runtime and Node.js.
# Chosen for simplicity and small image size (~100MB).
#
# Image size: ~100MB (well under the 200MB ceiling)
#
# Claude CLI is baked into the image — same pattern as the agents container.

FROM debian:bookworm-slim

# Install Node.js (required for Claude CLI) and Python
RUN apt-get update && apt-get install -y --no-install-recommends \
    nodejs npm python3 \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code CLI — chat backend runtime
RUN npm install -g @anthropic-ai/claude-code@2.1.84

# Non-root user — fixed UID 10001 for sandbox hardening (#706)
RUN useradd -m -u 10001 -s /bin/bash chat

# Copy application files
COPY server.py /usr/local/bin/server.py
COPY entrypoint-chat.sh /entrypoint-chat.sh
COPY ui/ /var/chat/ui/

RUN chmod +x /entrypoint-chat.sh /usr/local/bin/server.py

USER chat
WORKDIR /var/chat

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')" || exit 1

ENTRYPOINT ["/entrypoint-chat.sh"]
