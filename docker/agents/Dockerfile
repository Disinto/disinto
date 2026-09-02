FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash curl git jq tmux python3 python3-pip openssh-client ca-certificates age shellcheck procps gosu bats zstd \
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

# Install yq — YAML processor (used by supervisor recipe evaluator)
ARG YQ_VERSION=4.45.1
RUN curl -fsSL "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" \
    -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq

# Node 24 LTS — Debian bookworm ships Node 18, but @deepseek-ai/dsh needs
# util.parseEnv (Node >= 20.12). Official tarball into /usr/local so it
# wins PATH over any distro nodejs. Pinned version for reproducibility.
RUN curl -fsSL https://nodejs.org/dist/v24.14.0/node-v24.14.0-linux-x64.tar.gz -o /tmp/node.tar.xz \
    && tar -xzf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
    && rm /tmp/node.tar.xz \
    && node --version && npm --version

# Install Claude Code CLI — agent runtime for all LLM backends (llama, Claude API).
# The CLI is the execution environment; ANTHROPIC_BASE_URL selects the model provider.
RUN npm install -g @anthropic-ai/claude-code@2.1.84

# Install dsh — dsh agent harness (run via _agent_run_dsh, #1106)
RUN npm install -g @deepseek-ai/dsh@0.1.1-rc.2

# Seed the dsh headless profile for hired dsh agents (--harness dsh, #1107).
# dsh headless runs as `dsh --profile headless` with DSH_HOME pointing at the
# agent's persistent config dir ($DSH_HOME/profiles/headless.json). The seed
# lives at a stable non-volume path; entrypoint.sh copies it into $DSH_HOME
# on first start (compose named volumes inherit image contents on init, but
# Nomad host volumes do not, so the entrypoint copy is the single seeding
# point for both backends).
RUN mkdir -p /opt/dsh/profiles \
    && printf '{\n  "name": "headless",\n  "permissionMode": "danger-full-access",\n  "contextWindow": 163840\n}\n' \
    > /opt/dsh/profiles/headless.json

# Provider settings template for the dsh harness — dsh reads its provider
# from $DSH_HOME/settings.yaml, NOT from DSH_BASE_URL env. entrypoint.sh
# seeds it (with the env's DSH_BASE_URL substituted) on first start.
COPY docker/agents/dsh-settings-llamacpp.yaml /opt/dsh/settings-llamacpp.yaml

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
