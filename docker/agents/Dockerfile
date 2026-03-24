FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash curl git jq tmux cron python3 openssh-client ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Claude CLI is mounted from the host via docker-compose volume.
# No internet access to cli.anthropic.com required at build time.

# Non-root user
RUN useradd -m -u 1000 -s /bin/bash agent

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Entrypoint runs as root to start the cron daemon;
# cron jobs execute as the agent user (crontab -u agent).
WORKDIR /home/agent

ENTRYPOINT ["/entrypoint.sh"]
