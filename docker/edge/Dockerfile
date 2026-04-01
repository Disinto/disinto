FROM caddy:alpine
RUN apk add --no-cache bash jq curl git docker-cli
COPY entrypoint-edge.sh /usr/local/bin/entrypoint-edge.sh
ENTRYPOINT ["bash", "/usr/local/bin/entrypoint-edge.sh"]
