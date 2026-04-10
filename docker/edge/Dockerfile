FROM caddy:latest
RUN apk add --no-cache bash jq curl git docker-cli python3 openssh-client autossh
COPY entrypoint-edge.sh /usr/local/bin/entrypoint-edge.sh
ENTRYPOINT ["bash", "/usr/local/bin/entrypoint-edge.sh"]
