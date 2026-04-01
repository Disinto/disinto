FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash curl git jq tmux cron python3 python3-pip openssh-client ca-certificates age shellcheck \
    && pip3 install --break-system-packages networkx \
    && rm -rf /var/lib/apt/lists/*

# Pre-built binaries (copied from docker/agents/bin/)
# SOPS — encrypted data decryption tool
COPY docker/agents/bin/sops /usr/local/bin/sops
RUN chmod +x /usr/local/bin/sops

# tea CLI — official Gitea/Forgejo CLI for issue/label/comment operations
COPY docker/agents/bin/tea /usr/local/bin/tea
RUN chmod +x /usr/local/bin/tea

# Claude CLI is mounted from the host via docker-compose volume.
# No internet access to cli.anthropic.com required at build time.

# Non-root user
RUN useradd -m -u 1000 -s /bin/bash agent

# Copy disinto code into the image
COPY . /home/agent/disinto

COPY docker/agents/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Entrypoint runs as root to start the cron daemon;
# cron jobs execute as the agent user (crontab -u agent).
WORKDIR /home/agent/disinto

ENTRYPOINT ["/entrypoint.sh"]
