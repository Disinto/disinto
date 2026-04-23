# =============================================================================
# nomad/jobs/edge.hcl — Edge proxy (Caddy + dispatcher sidecar) (Nomad service job)
#
# Part of the Nomad+Vault migration (S5.1, issue #988). Caddy reverse proxy
# routes traffic to Forgejo, Woodpecker, staging, and chat services. The
# dispatcher sidecar polls disinto-ops for vault actions and dispatches them
# via Nomad batch jobs.
#
# All upstreams discovered via Nomad service discovery (issue #1156, S5-fix-7).
# Caddy uses network_mode = "host" but upstreams run in separate alloc netns,
# so loopback addresses are unreachable — nomadService templates resolve the
# dynamic address:port for each backend.
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

    # Vault workload identity is scoped per-task below: the caddy task uses
    # service-edge-chat (operator Forge PAT + Nomad ACL token, #650); the
    # dispatcher task uses service-dispatcher (ops-repo + runner secrets).

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

    # claude-creds: OAuth credentials for Anthropic Claude CLI used by the
    # chat subprocess (#648). Mounted at /home/agent/.claude inside the
    # caddy task so the chat-launched `claude -p` call picks up the Max
    # subscription instead of requiring ANTHROPIC_API_KEY. Shared with
    # agents-supervisor-opus.hcl — same host path, read-only.
    volume "claude-creds" {
      type      = "host"
      source    = "claude-creds"
      read_only = true
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

      # Vault role for the chat-Claude control surface secrets (#650).
      vault {
        role = "service-edge-chat"
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

        # Mount docker.sock rw for the chat-Claude factory control surface
        # (#650). The chat subprocess needs rw to run `docker restart`,
        # `docker stop`, etc. via the Bash allow-list in chat-settings.json.
        # The dispatcher task keeps its own ro mount below.
        volumes = ["/var/run/docker.sock:/var/run/docker.sock:rw"]
      }

      # Mount caddy-data volume for ACME state and config directory.
      # Caddyfile is mounted at /etc/caddy/Caddyfile by entrypoint-edge.sh.
      volume_mount {
        volume      = "caddy-data"
        destination = "/data"
        read_only   = false
      }

      # Mount claude-creds so the chat subprocess (python3 chat-server.py
      # spawning `claude -p` — see entrypoint-edge.sh) finds OAuth creds
      # at /home/agent/.claude/.credentials.json (#648). The chat process
      # runs as USER=agent (uid 1000) per entrypoint-edge.sh.
      volume_mount {
        volume      = "claude-creds"
        destination = "/home/agent/.claude"
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

    # Chat service — reverse proxy to disinto-chat backend (#705, #1156)
    # OAuth routes bypass forward_auth — unauthenticated users need these (#709)
    handle /chat/login {
{{ range nomadService "chat" }}        reverse_proxy {{ .Address }}:{{ .Port }}
{{ end }}    }
    handle /chat/oauth/callback {
{{ range nomadService "chat" }}        reverse_proxy {{ .Address }}:{{ .Port }}
{{ end }}    }
    # WebSocket endpoint for streaming (#1026)
    handle /chat/ws {
{{ range nomadService "chat" }}        reverse_proxy {{ .Address }}:{{ .Port }} {
            header_up Upgrade {http.request.header.Upgrade}
            header_up Connection {http.request.header.Connection}
        }
{{ end }}    }
    # Defense-in-depth: forward_auth stamps X-Forwarded-User from session (#709)
    handle /chat/* {
{{ range nomadService "chat" }}        forward_auth {{ .Address }}:{{ .Port }} {
            uri /chat/auth/verify
            copy_headers X-Forwarded-User
            header_up X-Forward-Auth-Secret {$FORWARD_AUTH_SECRET}
        }
        reverse_proxy {{ .Address }}:{{ .Port }}
{{ end }}    }
}
EOT
      }

      # ── Chat-Claude factory control surface secrets (#650) ──────────────
      # Forge admin PAT — read by the forge-api MCP server via the
      # FACTORY_FORGE_PAT env var (entrypoint-edge.sh loads it from the file
      # mount at container start). File mount preferred over direct env so
      # rotation = `vault kv put kv/disinto/chat forge_pat=<new>` + template
      # change_mode triggers a restart without shell-history leakage.
      template {
        destination          = "secrets/forge-pat"
        change_mode          = "restart"
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

      # Nomad ACL token — scoped namespace=default, perms submit-job /
      # read-job / list-jobs / read-logs (see docs/CHAT-CONTROL-SURFACE.md
      # for the policy to install via `nomad acl policy apply`). Rendered
      # as a file so NOMAD_TOKEN never appears in `docker inspect`.
      template {
        destination          = "secrets/nomad-token"
        change_mode          = "restart"
        error_on_missing_key = false
        perms                = "0400"
        data                 = <<EOT
{{- with secret "kv/data/disinto/chat" -}}
{{ .Data.data.nomad_token }}
{{- else -}}
seed-me
{{- end -}}
EOT
      }

      # ── Non-secret env ───────────────────────────────────────────────────
      env {
        FORGE_REPO        = "disinto-admin/disinto"
        DISINTO_CONTAINER = "1"
        PROJECT_NAME      = "disinto"

        # Chat subprocess: OAuth via mounted claude-creds volume, pinned
        # Opus 4.7 model (#648). Do NOT set ANTHROPIC_API_KEY or
        # ANTHROPIC_BASE_URL — their presence forces API-key mode and
        # bypasses the Max-subscription OAuth flow.
        CLAUDE_CONFIG_DIR = "/home/agent/.claude"
        CHAT_CLAUDE_MODEL = "claude-opus-4-7"

        # Chat-Claude factory control surface (#650). Workspace default is
        # /opt/disinto so Claude can read factory source; settings.json +
        # .mcp.json land there via entrypoint-edge.sh. Secret file paths
        # point at the Vault-rendered files above.
        CHAT_WORKSPACE_DIR     = "/opt/disinto"
        FACTORY_FORGE_PAT_FILE = "/secrets/forge-pat"
        NOMAD_TOKEN_FILE       = "/secrets/nomad-token"
        NOMAD_ADDR             = "http://localhost:4646"
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

      # Vault role for ops-repo + runner secret enumeration. Previously
      # inherited from a group-level stanza; moved to task scope when the
      # caddy task got its own role (#650).
      vault {
        role = "service-dispatcher"
      }

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

      # ── Forge URL via Nomad service discovery (issue #1034) ──────────
      # Resolves forgejo service address/port dynamically for bridge network
      # compatibility. Template-scoped to dispatcher task (Nomad doesn't
      # propagate templates across tasks).
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

      # ── Vault-templated secrets (S5.1, issue #988) ──────────────────────
      # Renders FORGE_TOKEN from Vault KV v2 for ops repo access.
      template {
        destination          = "secrets/dispatcher.env"
        env                  = true
        change_mode          = "restart"
        error_on_missing_key = false
        data                 = <<EOT
{{- with secret "kv/data/disinto/shared/ops-repo" -}}
FORGE_TOKEN={{ .Data.data.token }}
{{- else -}}
# WARNING: kv/disinto/shared/ops-repo is empty — run tools/vault-seed-ops-repo.sh
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
