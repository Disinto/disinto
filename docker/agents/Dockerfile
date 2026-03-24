FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash curl git jq tmux cron python3 openssh-client ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Claude CLI
RUN curl -fsSL https://cli.anthropic.com/install.sh | sh \
    && mv /root/.claude/local/claude /usr/local/bin/claude || true

# Non-root user
RUN useradd -m -u 1000 -s /bin/bash agent

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER agent
WORKDIR /home/agent

ENTRYPOINT ["/entrypoint.sh"]
