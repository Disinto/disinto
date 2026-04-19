# =============================================================================
# nomad/jobs/edge.hcl — Edge proxy (Caddy + dispatcher sidecar) (Nomad service job)
#
# Part of the Nomad+Vault migration (S5.1, issue #988). Caddy reverse proxy
# routes traffic to Forgejo, Woodpecker, staging, and chat services. The
# dispatcher sidecar polls disinto-ops for vault actions and dispatches them
# via Nomad batch jobs.
#
# Host networking (issue #1031):
#   Caddy uses network_mode = "host" so upstreams are reached at
#   127.0.0.1:<port> (forgejo :3000, woodpecker :8000, chat :8080).
#   Staging uses Nomad service discovery (S5-fix-7, issue #1018).
#
# Host_volume contract:
#   This job mounts caddy-data from nomad/client.hcl. Path
#   /srv/disinto/caddy-data is created by lib/init/nomad/cluster-up.sh before
#   any job references it. Keep the `source = "caddy-data"` below in sync
#   with the host_volume stanza in client.hcl.
#
# Build step (S5.1):
#   docker/edge/Dockerfile is custom (adds bash, jq, curl, git, docker-cli,
#   python3, openssh-client, autossh to caddy:latest). Build as
#   disinto/edge:local using the same pattern as disinto/agents:local.
#   Command: docker build -t disinto/edge:local -f docker/edge/Dockerfile docker/edge
#
# Not the runtime yet: docker-compose.yml is still the factory's live stack
# until cutover. This file exists so CI can validate it and S5.2 can wire
# `disinto init --backend=nomad --with edge` to `nomad job run` it.
# =============================================================================

job "edge" {
  type        = "service"
  datacenters = ["dc1"]

  group "edge" {
    count = 1

    # ── Vault workload identity for dispatcher (S5.1, issue #988) ──────────
    # Service role for dispatcher task to fetch vault actions from KV v2.
    # Role defined in vault/roles.yaml, policy in vault/policies/dispatcher.hcl.
    vault {
      role = "service-dispatcher"
    }

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

    # ops-repo: disinto-ops clone for vault actions polling.
    volume "ops-repo" {
      type      = "host"
      source    = "ops-repo"
      read_only = false
    }

    # ── Conservative restart policy ───────────────────────────────────────
    # Caddy should be stable; dispatcher may restart on errors.
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
      }

      # Mount caddy-data volume for ACME state and config directory.
      # Caddyfile is mounted at /etc/caddy/Caddyfile by entrypoint-edge.sh.
      volume_mount {
        volume      = "caddy-data"
        destination = "/data"
        read_only   = false
      }

      # ── Caddyfile via Nomad service discovery (S5-fix-7, issue #1018) ────
      # Renders staging upstream from Nomad service registration instead of
      # hardcoded staging:80. Caddy picks up /local/Caddyfile via entrypoint.
      # Forge URL via Nomad service discovery (issue #1034) — resolves forgejo
      # service address/port dynamically for bridge network compatibility.
      template {
        destination = "local/forge.env"
        env         = true
        change_mode = "restart"
        data        = <<EOT
{{ range service "forgejo" -}}
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

    # Reverse proxy to Forgejo
    handle /forge/* {
        reverse_proxy 127.0.0.1:3000
    }

    # Reverse proxy to Woodpecker CI
    handle /ci/* {
        reverse_proxy 127.0.0.1:8000
    }

    # Reverse proxy to staging — dynamic port via Nomad service discovery
    handle /staging/* {
{{ range nomadService "staging" }}        reverse_proxy {{ .Address }}:{{ .Port }}
{{ end }}    }

    # Chat service — reverse proxy to disinto-chat backend (#705)
    # OAuth routes bypass forward_auth — unauthenticated users need these (#709)
    handle /chat/login {
        reverse_proxy 127.0.0.1:8080
    }
    handle /chat/oauth/callback {
        reverse_proxy 127.0.0.1:8080
    }
    # Defense-in-depth: forward_auth stamps X-Forwarded-User from session (#709)
    handle /chat/* {
        forward_auth 127.0.0.1:8080 {
            uri /chat/auth/verify
            copy_headers X-Forwarded-User
            header_up X-Forward-Auth-Secret {$FORWARD_AUTH_SECRET}
        }
        reverse_proxy 127.0.0.1:8080
    }
}
EOT
      }

      # ── Non-secret env ───────────────────────────────────────────────────
      env {
        FORGE_REPO        = "disinto-admin/disinto"
        DISINTO_CONTAINER = "1"
        PROJECT_NAME      = "disinto"
      }

      # Caddy needs CPU + memory headroom for reverse proxy work.
      resources {
        cpu    = 200
        memory = 256
      }
    }

    # ── Dispatcher task (S5.1, issue #988) ────────────────────────────────
    task "dispatcher" {
      driver = "docker"

      config {
        # Use same disinto/agents:local image as other agents.
        image        = "disinto/agents:local"
        force_pull   = false
        network_mode = "host"

        # apparmor=unconfined matches docker-compose.
        security_opt = ["apparmor=unconfined"]

        # Mount docker.sock via bind-volume (not host volume) for legacy
        # docker backend compat. Nomad host volumes require named volumes
        # from client.hcl; socket files cannot be host volumes.
        volumes = ["/var/run/docker.sock:/var/run/docker.sock:ro"]
      }

      # Mount ops-repo for vault actions polling.
      volume_mount {
        volume      = "ops-repo"
        destination = "/home/agent/repos/disinto-ops"
        read_only   = false
      }

      # ── Vault-templated secrets (S5.1, issue #988) ──────────────────────
      # Renders FORGE_TOKEN from Vault KV v2 for ops repo access.
      template {
        destination          = "secrets/dispatcher.env"
        env                  = true
        change_mode          = "restart"
        error_on_missing_key = false
        data                 = <<EOT
{{- with secret "kv/data/disinto/bots/vault" -}}
FORGE_TOKEN={{ .Data.data.token }}
{{- else -}}
# WARNING: kv/disinto/bots/vault is empty — run tools/vault-seed-agents.sh
FORGE_TOKEN=seed-me
{{- end }}
EOT
      }

      # ── Non-secret env ───────────────────────────────────────────────────
      env {
        DISPATCHER_BACKEND   = "nomad"
        FORGE_REPO           = "disinto-admin/disinto"
        FORGE_OPS_REPO       = "disinto-admin/disinto-ops"
        PRIMARY_BRANCH       = "main"
        DISINTO_CONTAINER    = "1"
        OPS_REPO_ROOT        = "/home/agent/repos/disinto-ops"
        FORGE_ADMIN_USERS    = "vault-bot,admin"
      }

      # Dispatcher is lightweight — minimal CPU + memory.
      resources {
        cpu    = 100
        memory = 256
      }
    }
  }
}
