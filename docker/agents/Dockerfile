FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash curl git jq tmux cron python3 python3-pip openssh-client ca-certificates age shellcheck \
    && pip3 install --break-system-packages networkx \
    && curl -sL https://github.com/getsops/sops/releases/download/v3.9.4/sops-v3.9.4.linux.amd64 \
       -o /usr/local/bin/sops \
    && curl -sL https://github.com/getsops/sops/releases/download/v3.9.4/sops-v3.9.4.checksums.txt \
       -o /tmp/sops-checksums.txt \
    && sha256sum -c --ignore-missing /tmp/sops-checksums.txt \
    && rm -f /tmp/sops-checksums.txt \
    && chmod +x /usr/local/bin/sops \
    && rm -rf /var/lib/apt/lists/*

# tea CLI — official Gitea/Forgejo CLI for issue/label/comment operations
# Checksum from https://dl.gitea.com/tea/0.9.2/tea-0.9.2-linux-amd64.sha256
RUN curl -sL https://dl.gitea.com/tea/0.9.2/tea-0.9.2-linux-amd64 -o /usr/local/bin/tea \
    && echo "be10cdf9a619e3c0f121df874960ed19b53e62d1c7036cf60313a28b5227d54d  /usr/local/bin/tea" | sha256sum -c - \
    && chmod +x /usr/local/bin/tea

# Claude CLI is mounted from the host via docker-compose volume.
# No internet access to cli.anthropic.com required at build time.

# Non-root user
RUN useradd -m -u 1000 -s /bin/bash agent

# Copy disinto code into the image
COPY . /home/agent/disinto

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Entrypoint runs as root to start the cron daemon;
# cron jobs execute as the agent user (crontab -u agent).
WORKDIR /home/agent/disinto

ENTRYPOINT ["/entrypoint.sh"]
