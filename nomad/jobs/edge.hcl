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

    # claude-shared: OAuth credentials for Anthropic Claude CLI used by
    # the chat subprocess (#648). Same volume used by every opus agent
    # (agents-{dev,review,architect,supervisor}-opus) — keeps the chat
    # subprocess on the refreshed OAuth session rather than the stale
    # claude-creds host path. Mounted read-write: agents write session
    # state under config/sessions/ as turns complete.
    volume "claude-shared" {
      type      = "host"
      source    = "claude-shared"
      read_only = false
    }

    # snapshot-state: factory-state JSON written by snapshot-daemon.
    # RW for the daemon task; consumers mount RO.
    volume "snapshot-state" {
      type      = "host"
      source    = "snapshot-state"
      read_only = false
    }

    # threads-state: delegate thread state (meta.json + stream.jsonl).
    # RW for the GC batch job and any consumer that needs to inspect threads.
    volume "threads-state" {
      type      = "host"
      source    = "threads-state"
      read_only = false
    }

    # inbox-state: per-item sentinel directories (.acked, .shown, .snoozed).
    # RW for snapshot-daemon (writes sentinels); RO for caddy/consumers.
    volume "inbox-state" {
      type      = "host"
      source    = "inbox-state"
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

      # Mount claude-shared so the chat subprocess (python3 chat-server.py
      # spawning `claude -p`) finds OAuth creds at
      # /var/lib/disinto/claude-shared/config/.credentials.json (#648,
      # #705). This is the same directory convention every opus agent
      # uses via lib/env.sh defaults. CLAUDE_CONFIG_DIR below points the
      # Python subprocess at the config/ subdir.
      volume_mount {
        volume      = "claude-shared"
        destination = "/var/lib/disinto/claude-shared"
        read_only   = false
      }

      # Mount snapshot-state so chat-Claude skills can read state.json
      # (issue #760). The snapshot daemon writes atomically; consumers
      # only read.
      volume_mount {
        volume      = "snapshot-state"
        destination = "/var/lib/disinto/snapshot"
        read_only   = true
      }

      # Mount threads-state so the chat UI can list/show thread state
      # (issue #764). Read-only for the caddy task — only the GC job
      # needs write access.
      volume_mount {
        volume      = "threads-state"
        destination = "/var/lib/disinto/threads"
        read_only   = true
      }

      # Mount inbox-state so the caddy task can read sentinel state
      # (.acked, .shown, .snoozed) for inbox filtering.
      volume_mount {
        volume      = "inbox-state"
        destination = "/var/lib/disinto/inbox"
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

    # Chat service — subprocess on 127.0.0.1:{{ or (env "CHAT_PORT") "8080" }} (#1083)
    # Chat was folded into edge as a subprocess (#1083); no Nomad service named
    # "chat" exists. Use the host-local loopback address instead of
    # nomadService discovery.
    # Bare /chat → /chat/ (Caddy has no implicit directory redirect)
    handle /chat {
        redir * /chat/ 302
    }
    handle /chat/login {
        reverse_proxy 127.0.0.1:{{ or (env "CHAT_PORT") "8080" }}
    }
    handle /chat/oauth/callback {
        reverse_proxy 127.0.0.1:{{ or (env "CHAT_PORT") "8080" }}
    }
    # WebSocket endpoint for streaming (#1026)
    handle /chat/ws {
        reverse_proxy 127.0.0.1:{{ or (env "CHAT_PORT") "8080" }} {
            header_up Upgrade {http.request.header.Upgrade}
            header_up Connection {http.request.header.Connection}
        }
    }
    # Defense-in-depth: forward_auth stamps X-Forwarded-User from session (#709)
    handle /chat/* {
        forward_auth 127.0.0.1:{{ or (env "CHAT_PORT") "8080" }} {
            uri /chat/auth/verify
            copy_headers X-Forwarded-User
            header_up X-Forward-Auth-Secret {$FORWARD_AUTH_SECRET}
        }
        reverse_proxy 127.0.0.1:{{ or (env "CHAT_PORT") "8080" }}
    }

    # Voice bridge WebSocket endpoint — Gemini Live ↔ `think` tool ↔
    # `claude -r` (#662). Direct loopback to the voice-bridge.py
    # subprocess (NOT nomadService discovery — the bridge is a
    # sidecar process inside this task, same pattern as /chat/ws).
    # Shared forward_auth with /chat/* above: a valid OAuth session
    # cookie is required to upgrade, and X-Forwarded-User is stamped
    # so the bridge can log and audit per-user voice sessions.
    handle /voice/ws {
        forward_auth 127.0.0.1:{{ or (env "CHAT_PORT") "8080" }} {
            uri /chat/auth/verify
            copy_headers X-Forwarded-User
            header_up X-Forward-Auth-Secret {$FORWARD_AUTH_SECRET}
        }
        reverse_proxy 127.0.0.1:{{ or (env "VOICE_PORT") "8090" }} {
            header_up Upgrade {http.request.header.Upgrade}
            header_up Connection {http.request.header.Connection}
        }
    }

    # Voice UI static assets (#663). Served by Caddy out of the image at
    # /var/voice/ui (Dockerfile COPY). Same OAuth gate as /chat/* — the
    # forward_auth block stamps X-Forwarded-User and bounces unauthenticated
    # requests to 401 (Caddy then surfaces a generic error; the page-level
    # JS at /voice/ catches the WebSocket 4401 and redirects to /chat/login).
    # /voice/static/* is matched before /voice/* by Caddy's longest-path
    # precedence, so the index handler below never sees these requests.
    handle /voice/static/* {
        forward_auth 127.0.0.1:{{ or (env "CHAT_PORT") "8080" }} {
            uri /chat/auth/verify
            copy_headers X-Forwarded-User
            header_up X-Forward-Auth-Secret {$FORWARD_AUTH_SECRET}
        }
        uri strip_prefix /voice
        root * /var/voice/ui
        file_server
    }

    # Voice UI index — matches /voice and /voice/ (Caddy's path matcher
    # treats a trailing-slash matcher as a prefix). Falls through to
    # index.html via try_files so deep links like /voice/?conv=abc work.
    # Same forward_auth gate as the static and ws handlers above.
    handle /voice {
        redir * /voice/ 302
    }
    handle /voice/ {
        forward_auth 127.0.0.1:{{ or (env "CHAT_PORT") "8080" }} {
            uri /chat/auth/verify
            copy_headers X-Forwarded-User
            header_up X-Forward-Auth-Secret {$FORWARD_AUTH_SECRET}
        }
        # Don't let mobile browsers cache index.html — it references
        # voice-client.js with a versioned query string, and a stale
        # index.html would point at an old version (#860 fix delivery).
        header Cache-Control "no-cache, no-store, must-revalidate"
        header Pragma "no-cache"
        header Expires "0"
        root * /var/voice/ui
        try_files {path} /index.html
        file_server
    }

    # Engagement measurement — receives client-side beacons, proxies to
    # local engagement-server.py (issue #975). POST appends to log; GET
    # returns aggregated JSON snapshot for factory snapshot queries.
    handle /api/engagement {
        reverse_proxy 127.0.0.1:8095
    }
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

      # ── Voice bridge Gemini API key (#664 / parent #651) ─────────────────
      # Rendered to a FILE at /secrets/gemini-api-key rather than an env
      # stanza. Rationale: env vars set on the Nomad task are inherited by
      # every subprocess in the task — chat-server.py, the chat-launched
      # `claude -p` process, AND the voice bridge. The voice bridge is the
      # only subprocess that should hold the Gemini key. The voice launcher
      # (lands with #662) reads this file and sets GEMINI_API_KEY only in
      # its own child env, preventing leakage into the chat subprocess or
      # any `claude -p` session it spawns. Seed via
      # `disinto vault reseed-voice` (see tools/vault-seed-voice.sh).
      template {
        destination          = "secrets/gemini-api-key"
        change_mode          = "restart"
        error_on_missing_key = false
        perms                = "0400"
        data                 = <<EOT
{{- with secret "kv/data/disinto/voice" -}}
{{ .Data.data.gemini_api_key }}
{{- else -}}
seed-me
{{- end -}}
EOT
      }

      # Chat OAuth (Forgejo) client id/secret + forward_auth shared secret.
      # Injected as env vars (env = true) because server.py reads from env.
      template {
        destination          = "secrets/chat-oauth.env"
        env                  = true
        change_mode          = "restart"
        error_on_missing_key = false
        perms                = "0400"
        data                 = <<EOT
{{- with secret "kv/data/disinto/chat" -}}
CHAT_OAUTH_CLIENT_ID={{ .Data.data.oauth_client_id }}
CHAT_OAUTH_CLIENT_SECRET={{ .Data.data.oauth_client_secret }}
FORWARD_AUTH_SECRET={{ .Data.data.forward_auth_secret }}
{{- end }}
EOT
      }

      # ── Non-secret env ───────────────────────────────────────────────────
      env {
        FORGE_REPO        = "disinto-admin/disinto"
        DISINTO_CONTAINER = "1"
        PROJECT_NAME      = "disinto"

        # Chat subprocess: OAuth via mounted claude-shared volume, pinned
        # Opus 4.7 model (#648, #705). Do NOT set ANTHROPIC_API_KEY or
        # ANTHROPIC_BASE_URL — their presence forces API-key mode and
        # bypasses the Max-subscription OAuth flow.
        CLAUDE_CONFIG_DIR = "/var/lib/disinto/claude-shared/config"
        CHAT_CLAUDE_MODEL = "claude-opus-4-7"

        # Chat-Claude factory control surface (#650). Workspace default is
        # /opt/disinto so Claude can read factory source; settings.json +
        # .mcp.json land there via entrypoint-edge.sh. Secret file paths
        # point at the Vault-rendered files above.
        CHAT_WORKSPACE_DIR     = "/opt/disinto"
        FACTORY_FORGE_PAT_FILE = "/secrets/forge-pat"
        NOMAD_TOKEN_FILE       = "/secrets/nomad-token"
        NOMAD_ADDR             = "http://localhost:4646"

        # Voice bridge (#662 / parent #651). The path — not the secret — is
        # exposed as env. The voice launcher reads the file and scopes
        # GEMINI_API_KEY to its own subprocess env only, so the chat
        # subprocess never sees the Gemini key.
        GEMINI_API_KEY_FILE    = "/secrets/gemini-api-key"
        # Voice bridge listens on loopback; Caddy's /voice/ws handle
        # reverse-proxies here. 8090 picked to avoid collision with
        # CHAT_PORT=8080.
        VOICE_PORT             = "8090"
        VOICE_HOST             = "127.0.0.1"

        # OAuth callback FQDN — server.py builds redirect_uri from this.
        EDGE_TUNNEL_FQDN       = "self.disinto.ai"
        EDGE_ROUTING_MODE      = "subpath"

        # FORGE_URL stays internal (used for git clone + server-to-server
        # API calls). The OAuth authorize redirect needs a browser-reachable
        # URL — server.py reads FORGE_PUBLIC_URL when present.
        FORGE_PUBLIC_URL       = "https://self.disinto.ai/forge"
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

      # Reuse service-edge-chat policy — grants read access to
      # kv/data/disinto/chat (forge_pat + nomad_token) and
      # kv/data/disinto/voice (gemini_api_key).
      vault {
        role = "service-edge-chat"
      }

      config {
        command = "/opt/disinto/bin/snapshot-daemon.sh"
      }

      # raw_exec runs on the host, not in a container — host_volume mounts
      # don't apply. Daemon writes directly to the host path. Edge container
      # consumers (caddy task) mount the same host path at
      # /var/lib/disinto/snapshot via the existing snapshot-state volume_mount.
      env {
        SNAPSHOT_PATH = "/srv/disinto/snapshot-state/state.json"
        # Snapshot daemon writes sentinels to the host path directly
        # (raw_exec runs on the host). caddy task reads via volume_mount
        # at /var/lib/disinto/inbox (RO), which maps to this same host path.
        INBOX_ROOT    = "/srv/disinto/inbox-state"
      }

      # ── Collector secrets (env = true) ────────────────────────────────
      # NOMAD_TOKEN and FACTORY_FORGE_PAT come from the same Vault KV
      # paths the caddy task already uses — no new paths needed.
      # raw_exec respects template { env = true } the same as docker.
      template {
        destination          = "secrets/snapshot.env"
        env                  = true
        change_mode          = "restart"
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

      # Minimal resources — pure bash loop, negligible footprint.
      resources {
        cpu    = 50
        memory = 32
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

        # Skip the Claude CLI auth gate in the agent entrypoint (#733).
        # Dispatcher only polls the ops repo (docker/edge/dispatcher.sh) and
        # never invokes claude — the auth check would otherwise crash this
        # task with exit 3 under set -euo pipefail.
        AGENT_REQUIRES_CLAUDE = "0"
      }

      # Dispatcher is lightweight — minimal CPU + memory.
      resources {
        cpu    = 100
        memory = 256
      }
    }
  }
}
