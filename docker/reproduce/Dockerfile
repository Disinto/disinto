# docker/reproduce/Dockerfile — reproduce/triage/verify sidecar image.
# The agent runs dsh against the local model with the Playwright MCP server
# (docker/reproduce/sidecar-agent.sh). Rebuilt on the box by
# .woodpecker/build-reproduce.yml.
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
      bash git jq python3 docker-ce-cli docker-compose-plugin chromium \
    && rm -rf /var/lib/apt/lists/*
# Node 24, same pin as docker/agents/Dockerfile (dsh needs Node >= 20.12).
RUN curl -fsSL https://nodejs.org/dist/v24.14.0/node-v24.14.0-linux-x64.tar.gz -o /tmp/node.tgz \
    && tar -xzf /tmp/node.tgz -C /usr/local --strip-components=1 \
    && rm /tmp/node.tgz && node --version
RUN npm install -g @deepseek-ai/dsh@0.1.1-rc.2 @playwright/mcp@0.0.80
# dsh seed files, the same ones docker/agents/Dockerfile bakes (lib/dsh-seed.sh).
RUN mkdir -p /opt/dsh/profiles \
    && printf '{\n  "name": "headless",\n  "permissionMode": "danger-full-access",\n  "contextWindow": 100000\n}\n' \
    > /opt/dsh/profiles/headless.json
COPY docker/agents/dsh-settings-llamacpp.yaml /opt/dsh/settings-llamacpp.yaml
RUN useradd -m -u 1000 -s /bin/bash agent
COPY . /home/agent/disinto
COPY docker/reproduce/entrypoint-reproduce.sh /entrypoint-reproduce.sh
RUN chmod +x /entrypoint-reproduce.sh
VOLUME /home/agent/data
VOLUME /home/agent/repos

WORKDIR /home/agent
ENTRYPOINT ["/entrypoint-reproduce.sh"]
