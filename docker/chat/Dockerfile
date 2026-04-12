# disinto-chat — minimal HTTP+WebSocket backend for Claude chat UI
#
# Small Debian slim base with Python runtime and websockets library.
# Chosen for simplicity and small image size (~100MB vs ~150MB for Go).
#
# Image size: ~100MB (well under the 200MB ceiling)
#
# The claude binary is mounted from the host at runtime via docker-compose,
# not baked into the image — same pattern as the agents container.

FROM debian:bookworm-slim

# Install Python and websockets (no build-time network access needed)
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    && pip3 install --break-system-packages websockets \
    && rm -rf /var/lib/apt/lists/*

# Non-root user
RUN useradd -m -u 1000 -s /bin/bash chat

# Copy application files
COPY server.py /usr/local/bin/server.py
COPY entrypoint-chat.sh /entrypoint-chat.sh
COPY ui/ /var/chat/ui/

RUN chmod +x /entrypoint-chat.sh /usr/local/bin/server.py

USER chat
WORKDIR /var/chat

ENTRYPOINT ["/entrypoint-chat.sh"]
