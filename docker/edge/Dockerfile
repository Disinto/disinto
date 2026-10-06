# Multi-stage build: Nomad 1.8+ is glibc-fortified and requires __vdprintf_chk,
# which Alpine's musl (and gcompat / sgerrand's alpine-pkg-glibc) do not provide
# (#699). Switch the runtime base to frolvlad/alpine-glibc, which ships a full
# glibc with FORTIFY support, and copy Caddy from the official image so the
# Caddy build stays identical to what `caddy:latest` ships.
FROM caddy:latest AS caddy-src

FROM frolvlad/alpine-glibc
COPY --from=caddy-src /usr/bin/caddy         /usr/bin/caddy
COPY --from=caddy-src /etc/caddy/Caddyfile   /etc/caddy/Caddyfile
COPY --from=caddy-src /usr/share/caddy/      /usr/share/caddy/
RUN apk add --no-cache bash jq curl git docker-cli python3 py3-pip openssh-client autossh \
    unzip shadow

# Non-root agent user (uid 1000) — /home/agent is the HOME for
# entrypoint-edge.sh, the dispatcher, and Caddy.
RUN groupadd -g 1000 agent && useradd -m -u 1000 -g 1000 -s /bin/bash agent
# Nomad CLI — factory control surface (#650). Pinned nomad binary for
# `nomad job ...` / `nomad alloc ...` calls via the dispatcher's Bash
# allow-list. Version should track the nomad server version deployed
# by lib/init/nomad/install.sh.
ARG NOMAD_VERSION=1.8.4
RUN set -eux; \
    arch="$(apk --print-arch)"; \
    case "$arch" in \
      x86_64)  nomad_arch=amd64 ;; \
      aarch64) nomad_arch=arm64 ;; \
      *) echo "unsupported arch for nomad: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_linux_${nomad_arch}.zip" -o /tmp/nomad.zip; \
    unzip -o /tmp/nomad.zip -d /usr/local/bin; \
    rm -f /tmp/nomad.zip; \
    chmod 0755 /usr/local/bin/nomad; \
    /usr/local/bin/nomad --version
COPY docker/edge/entrypoint-edge.sh /usr/local/bin/entrypoint-edge.sh
# Bake forge_whoami() into the edge image so entrypoint-edge.sh can call it
# before /opt/disinto is cloned (#694).
COPY lib/forge-helpers.sh /usr/local/lib/forge-helpers.sh
# Engagement beacon server (issue #975)
COPY docker/edge/engagement-server.py /usr/local/bin/engagement-server.py

VOLUME /data

ENTRYPOINT ["bash", "/usr/local/bin/entrypoint-edge.sh"]
