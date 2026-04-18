FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash curl git jq tmux nodejs npm python3 python3-pip openssh-client ca-certificates age shellcheck procps gosu \
    && pip3 install --break-system-packages networkx tomlkit \
    && rm -rf /var/lib/apt/lists/*

# Pre-built binaries (copied from docker/agents/bin/)
# SOPS — encrypted data decryption tool
# Download sops binary (replaces manual COPY of vendored binary)
ARG SOPS_VERSION=3.9.4
RUN curl -fsSL "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.amd64" \
    -o /usr/local/bin/sops && chmod +x /usr/local/bin/sops

# tea CLI — official Gitea/Forgejo CLI for issue/label/comment operations
# Download tea binary (replaces manual COPY of vendored binary)
ARG TEA_VERSION=0.9.2
RUN curl -fsSL "https://dl.gitea.com/tea/${TEA_VERSION}/tea-${TEA_VERSION}-linux-amd64" \
    -o /usr/local/bin/tea && chmod +x /usr/local/bin/tea

# Install Claude Code CLI — agent runtime for all LLM backends (llama, Claude API).
# The CLI is the execution environment; ANTHROPIC_BASE_URL selects the model provider.
RUN npm install -g @anthropic-ai/claude-code@2.1.84

# Non-root user
RUN useradd -m -u 1000 -s /bin/bash agent

# Copy disinto code into the image
COPY . /home/agent/disinto

COPY docker/agents/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Entrypoint runs polling loop directly, dropping to agent user via gosu.
# All scripts execute as the agent user (UID 1000) while preserving env vars.
VOLUME /home/agent/data
VOLUME /home/agent/repos

WORKDIR /home/agent/disinto

ENTRYPOINT ["/entrypoint.sh"]
