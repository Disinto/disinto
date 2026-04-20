FROM caddy:latest
RUN apk add --no-cache bash jq curl git docker-cli python3 openssh-client autossh \
    nodejs npm
# Claude Code CLI — chat backend runtime (merged from docker/chat, #1083)
RUN npm install -g @anthropic-ai/claude-code@2.1.84
COPY docker/edge/entrypoint-edge.sh /usr/local/bin/entrypoint-edge.sh
# Chat server and UI (merged from docker/chat into edge, #1083)
COPY docker/chat/server.py /usr/local/bin/chat-server.py
COPY docker/chat/ui/ /var/chat/ui/

VOLUME /data

ENTRYPOINT ["bash", "/usr/local/bin/entrypoint-edge.sh"]
