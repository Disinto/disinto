FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash curl git jq tmux cron python3 openssh-client ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Claude CLI — install and verify
RUN curl -fsSL https://cli.anthropic.com/install.sh | sh \
    && cp "$(find /root -name claude -type f 2>/dev/null | head -1)" /usr/local/bin/claude \
    && claude --version

# Non-root user
RUN useradd -m -u 1000 -s /bin/bash agent

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Entrypoint runs as root to start the cron daemon;
# cron jobs execute as the agent user (crontab -u agent).
WORKDIR /home/agent

ENTRYPOINT ["/entrypoint.sh"]
