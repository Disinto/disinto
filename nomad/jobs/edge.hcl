# =============================================================================
# nomad/jobs/edge.hcl — Edge proxy (Caddy) (Nomad service job)
#
# Part of the Nomad+Vault migration (S5.1, issue #988). Caddy reverse proxy
# routes traffic to Forgejo, Woodpecker, and staging. Chat and voice are
# not routed (#1768); the caddy task no longer renders their secrets or
# env (#1770). The vault-action dispatcher runs as a background
# process inside the caddy container (entrypoint-edge.sh ->
# docker/edge/dispatcher.sh), polling
# disinto-ops for vault actions and dispatching them via Nomad batch jobs.
#
# All upstreams discovered via Nomad service discovery (issue #1156, S5-fix-7).
# Caddy uses network_mode = "host" but upstreams run in separate alloc netns,
# so loopback addresses are unreachable — nomadService templates resolve the
# dynamic address:port for each backend.
#
# Host_volume contract:
#   This job mounts caddy-data, tape, and claude-shared from nomad/client.hcl.
#   Paths /srv/disinto/caddy-data and /srv/disinto/tape are created by
#   lib/init/nomad/cluster-up.sh before any job references them. Keep the
#   `source = "caddy-data"` and `source = "tape"` below in sync with the
#   host_volume stanzas in client.hcl.
#
# Build step (S5.1):
#   docker/edge/Dockerfile is custom (adds bash, jq, curl, git, docker-cli,
#   python3, openssh-client, autossh to caddy:latest). Build as
#   disinto/edge:local using the same pattern as disinto/agents:local.
#   Command: docker build -t disinto/edge:local -f docker/edge/Dockerfile docker/edge
#
# This jobspec is the live edge proxy on the Nomad+Vault backend: it is
# deployed via `disinto init --backend=nomad --with edge`
# (`nomad job run`), not a staging artifact.
# =============================================================================

job "edge" {
  type        = "service"
  datacenters = ["dc1"]

  group "edge" {
    count = 1

    # Vault workload identity is scoped per-task below: both tasks use
    # service-edge-chat. The forge PAT is read from kv/disinto/chat (#650).

    # ── Network ports (S5.1, issue #988) ──────────────────────────────────
    # Caddy listens on :80 and :443. Expose both on the host.
    network {
      port "http" {
        static = 80
        to     = 80
      }

      port "https" {
        static = 443
        to     = 443
      }
    }

    # ── Host-volume mounts (S5.1, issue #988) ─────────────────────────────
    # caddy-data: ACME certificates, Caddy config state.
    volume "caddy-data" {
      type      = "host"
      source    = "caddy-data"
      read_only = false
    }

    # claude-shared: OAuth session the dispatcher probes before bind-mounting
    # it into vault runners and reproduce/triage sidecars (dispatcher.sh,
    # #1758 / #1776). The caddy mount is read-only: docker.sock resolves -v
    # on the host. Not a chat mount (#1770).
    volume "claude-shared" {
      type      = "host"
      source    = "claude-shared"
      read_only = false
    }

    # tape records (lib/tape.sh): mounted RW at /srv/disinto/tape, the
    # lib/tape.sh default TAPE_DIR, so no env override is needed (#1405).
    volume "tape" {
      type      = "host"
      source    = "tape"
      read_only = false
    }


    # ── Conservative restart policy ───────────────────────────────────────
    # Caddy should be stable.
    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "delay"
    }

    # ── Service registration ───────────────────────────────────────────────
    # Caddy is an HTTP reverse proxy — health check on port 80.
    service {
      name     = "edge"
      port     = "http"
      provider = "nomad"

      check {
        type     = "http"
        path     = "/"
        interval = "10s"
        timeout  = "3s"
      }
    }

    # ── Caddy task (S5.1, issue #988) ─────────────────────────────────────
    task "caddy" {
      driver = "docker"

      # Vault role for the forge PAT. Read from kv/disinto/chat; that path
      # is not chat-only (#650). The dispatcher pushes vault results with
      # the rendered file.
      vault {
        role = "service-edge-chat"
        # Stable under Vault token renewal (#1091 pattern).
        # Rotation = vault kv put + manual nomad alloc restart.
        change_mode = "noop"
      }

      config {
        # Use pre-built disinto/edge:local image (custom Dockerfile adds
        # bash, jq, curl, git, docker-cli, python3, openssh-client, autossh).
        image        = "disinto/edge:local"
        force_pull   = false
        network_mode = "host"
        ports        = ["http", "https"]

        # apparmor=unconfined matches docker-compose — needed for autossh
        # in the entrypoint script.
        security_opt = ["apparmor=unconfined"]

        # Mount docker.sock rw so the vault-action dispatcher can launch
        # reproduce/triage sidecars (docker/edge/dispatcher.sh).
        volumes = ["/var/run/docker.sock:/var/run/docker.sock:rw"]
      }

      # Mount caddy-data volume for ACME state and config directory.
      # Caddyfile is mounted at /etc/caddy/Caddyfile by entrypoint-edge.sh.
      volume_mount {
        volume      = "caddy-data"
        destination = "/data"
        read_only   = false
      }

      # tape (#1405): mounted at the lib/tape.sh default path so TAPE_DIR
      # needs no env override.
      volume_mount {
        volume      = "tape"
        destination = "/srv/disinto/tape"
        read_only   = false
      }

      # Dispatcher probe: the OAuth dir must exist inside this container
      # or runner/sidecar launches skip the session mount (#1758 / #1776).
      volume_mount {
        volume      = "claude-shared"
        destination = "/var/lib/disinto/claude-shared"
        read_only   = true
      }

      # ── Caddyfile via Nomad service discovery (S5-fix-7, issue #1018/1156) ──
      # All upstreams rendered from Nomad service registration. Caddy picks up
      # /local/Caddyfile via entrypoint.
      template {
        destination = "local/forge.env"
        env         = true
        change_mode = "restart"
        data        = <<EOT
{{ range nomadService "forgejo" -}}
FORGE_URL=http://{{ .Address }}:{{ .Port }}
{{- end }}
EOT
      }

      template {
        destination = "local/Caddyfile"
        change_mode = "restart"
        data        = <<EOT
# Caddyfile — edge proxy configuration (Nomad-rendered)
# Staging upstream discovered via Nomad service registration.

:80 {
    # Redirect root to Forgejo
    handle / {
        redir /forge/ 302
    }

    # Reverse proxy to Forgejo — dynamic via Nomad service discovery (#1156)
    handle /forge/* {
        uri strip_prefix /forge
{{ range nomadService "forgejo" }}        reverse_proxy {{ .Address }}:{{ .Port }}
{{ end }}    }

    # Reverse proxy to Woodpecker CI — dynamic via Nomad service discovery (#1156)
    handle /ci/* {
{{ range nomadService "woodpecker" }}        reverse_proxy {{ .Address }}:{{ .Port }}
{{ end }}    }

    # Reverse proxy to staging — dynamic port via Nomad service discovery
    handle /staging/* {
        uri strip_prefix /staging
{{ range nomadService "staging" }}        reverse_proxy {{ .Address }}:{{ .Port }}
{{ end }}    }

    # Engagement measurement — receives client-side beacons, proxies to
    # local engagement-server.py (issue #975). POST appends to log; GET
    # returns aggregated JSON snapshot for factory snapshot queries.
    handle /api/engagement {
        reverse_proxy 127.0.0.1:8095
    }
}
EOT
      }

      # Forge admin PAT — the dispatcher reads this file
      # (FACTORY_FORGE_PAT_FILE) to push vault results
      # (docker/edge/dispatcher.sh). File mount preferred over direct env so
      # rotation = `vault kv put kv/disinto/chat forge_pat=<new>` + manual
      # `nomad alloc restart <edge-alloc>` (template is noop under #1091
      # stabilization, so no auto-restart) without shell-history leakage.
      template {
        destination          = "secrets/forge-pat"
        # noop: static Vault secrets - renewal must not restart (#1091).
        change_mode          = "noop"
        error_on_missing_key = false
        perms                = "0400"
        data                 = <<EOT
{{- with secret "kv/data/disinto/chat" -}}
{{ .Data.data.forge_pat }}
{{- else -}}
seed-me
{{- end -}}
EOT
      }

      # ── Non-secret env ───────────────────────────────────────────────────
      # Forge PAT file is what the dispatcher uses to push vault results
      # (docker/edge/dispatcher.sh). NOMAD_ADDR is the local agent API.
      env {
        FORGE_REPO             = "disinto-admin/disinto"
        DISINTO_CONTAINER      = "1"
        PROJECT_NAME           = "disinto"
        FACTORY_FORGE_PAT_FILE = "/secrets/forge-pat"
        NOMAD_ADDR             = "http://localhost:4646"
      }

      # Caddy needs CPU + memory headroom for reverse proxy work.
      resources {
        cpu    = 200
        memory = 256
      }
    }

    # ── Snapshot daemon (issue #755) ──────────────────────────────────────
    # Polls every ~5s and writes factory-state JSON to disk. Consumers
    # (factory-state skill, snapshot-consumer) cat the file for instant
    # sub-200ms answers — no fork/load overhead vs. claude -p.
    task "snapshot" {
      driver = "raw_exec"

      # Same role as the caddy task — read access to kv/data/disinto/chat
      # (forge_pat + nomad_token), which secrets/snapshot.env renders.
      vault {
        role = "service-edge-chat"
        # Stable under Vault token renewal (#1091 pattern).
        # Rotation = vault kv put + manual nomad alloc restart.
        change_mode = "noop"
      }

      config {
        command = "/opt/disinto/bin/snapshot-daemon.sh"
      }

      # raw_exec runs on the host, not in a container — host_volume mounts
      # don't apply. The daemon writes factory-state JSON and inbox
      # sentinels directly to the host paths below.
      env {
        SNAPSHOT_PATH = "/srv/disinto/snapshot-state/state.json"
        INBOX_ROOT    = "/srv/disinto/inbox-state"
      }

      # ── Collector secrets (env = true) ────────────────────────────────
      # NOMAD_TOKEN and FACTORY_FORGE_PAT come from the same Vault KV
      # paths the caddy task already uses — no new paths needed.
      # raw_exec respects template { env = true } the same as docker.
      template {
        destination          = "secrets/snapshot.env"
        env                  = true
        # noop: static Vault secrets - renewal must not restart (#1091).
        change_mode          = "noop"
        error_on_missing_key = false
        data                 = <<EOT
{{- with secret "kv/data/disinto/chat" -}}
FACTORY_FORGE_PAT={{ .Data.data.forge_pat }}
NOMAD_TOKEN={{ .Data.data.nomad_token }}
{{- end }}
NOMAD_ADDR=http://localhost:4646
FORGE_URL=https://self.disinto.ai/forge
FACTORY_ROOT=/opt/disinto
EOT
      }

      # RSS is tiny, but cgroup v2 charges kernel slab to this task.
      # 96 MiB filled up and every collector curl was memcg-OOM-killed.
      resources {
        cpu    = 50
        memory = 256
      }
    }

  }
}
