# docker/research/Dockerfile — disinto/research: thin science-runner image (#1305)
#
# Transport image for physics/experiment runs dispatched through vault-runner:
# bash, OpenSSH client, rsync, jq, ca-certificates — and nothing else. No Meep,
# no Claude, no Playwright; the science stack stays on the worker, not in this
# image (vault-runner honours the per-action image in #1307; the dispatch lands
# in formulas/run-experiment.sh, #1308).
#
# Tagged locally as disinto/research:local (same convention as
# disinto/agents:local); .woodpecker/publish-images.yml pushes
# ghcr.io/disinto/research:<tag> on release cuts.

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash openssh-client rsync jq ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Non-root user (same convention as docker/agents: UID 1000).
RUN useradd -m -u 1000 -s /bin/bash agent

COPY docker/research/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER agent

# The entrypoint execs the command handed to it; with no args it drops to a
# shell so `docker run -it disinto/research:local` works for debugging.
ENTRYPOINT ["/entrypoint.sh"]
