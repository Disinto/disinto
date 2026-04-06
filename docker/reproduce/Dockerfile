FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash curl git jq docker.io docker-compose-plugin \
    nodejs npm chromium \
    && npm install -g @anthropic-ai/mcp-playwright \
    && rm -rf /var/lib/apt/lists/*
RUN useradd -m -u 1000 -s /bin/bash agent
COPY docker/reproduce/entrypoint-reproduce.sh /entrypoint-reproduce.sh
RUN chmod +x /entrypoint-reproduce.sh
WORKDIR /home/agent
ENTRYPOINT ["/entrypoint-reproduce.sh"]
