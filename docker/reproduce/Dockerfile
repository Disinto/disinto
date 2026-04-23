FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/debian bookworm stable" \
      > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends \
      bash git jq docker-ce-cli docker-compose-plugin \
      nodejs npm chromium \
    && npm install -g @anthropic-ai/mcp-playwright \
    && rm -rf /var/lib/apt/lists/*
RUN useradd -m -u 1000 -s /bin/bash agent
COPY docker/reproduce/entrypoint-reproduce.sh /entrypoint-reproduce.sh
RUN chmod +x /entrypoint-reproduce.sh
VOLUME /home/agent/data
VOLUME /home/agent/repos

WORKDIR /home/agent
ENTRYPOINT ["/entrypoint-reproduce.sh"]
