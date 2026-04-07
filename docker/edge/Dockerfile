FROM caddy:latest
RUN apt-get update && apt-get install -y bash jq curl git docker.io && rm -rf /var/lib/apt/lists/*
COPY entrypoint-edge.sh /usr/local/bin/entrypoint-edge.sh
ENTRYPOINT ["bash", "/usr/local/bin/entrypoint-edge.sh"]
