# =============================================================================
# nomad/jobs/chat.hcl — Claude chat UI (Nomad service job)
#
# Part of the Nomad+Vault migration (S5.2, issue #989). Lightweight service
# job for the Claude chat UI with sandbox hardening (#706).
#
# Build:
#   Custom image built from docker/chat/Dockerfile as disinto/chat:local
#   (same :local pattern as disinto/agents:local).
#
# Sandbox hardening (#706):
#   - Read-only root filesystem (enforced via entrypoint)
#   - tmpfs /tmp:size=64m for runtime temp files
#   - cap_drop ALL (no Linux capabilities)
#   - pids_limit 128 (prevent fork bombs)
#   - mem_limit 512m (matches compose sandbox hardening)
#
# Vault integration:
#   - vault { role = "service-chat" } at group scope
#   - Template stanza renders CHAT_OAUTH_CLIENT_ID, CHAT_OAUTH_CLIENT_SECRET,
#     FORWARD_AUTH_SECRET from kv/disinto/shared/chat
#   - Seeded on fresh boxes by tools/vault-seed-chat.sh
#
# Host volume:
#   - chat-history → /var/lib/chat/history (persists conversation history)
#
# Not the runtime yet: docker-compose.yml is still the factory's live stack
# until cutover. This file exists so CI can validate it and S5.2 can wire
# `disinto init --backend=nomad --with chat` to `nomad job run` it.
# =============================================================================

job "chat" {
  type        = "service"
  datacenters = ["dc1"]

  group "chat" {
    count = 1

    # ── Vault workload identity (S5.2, issue #989) ───────────────────────────
    # Role `service-chat` defined in vault/roles.yaml, policy in
    # vault/policies/service-chat.hcl. Bound claim pins nomad_job_id = "chat".
    vault {
      role = "service-chat"
    }

    # ── Network ──────────────────────────────────────────────────────────────
    # External port 8080 for chat UI access (via edge proxy or direct).
    network {
      port "http" {
        static = 8080
        to     = 8080
      }
    }

    # ── Host volumes ─────────────────────────────────────────────────────────
    # chat-history volume: declared in nomad/client.hcl, path
    # /srv/disinto/chat-history on the factory box.
    volume "chat-history" {
      type      = "host"
      source    = "chat-history"
      read_only = false
    }

    # ── Restart policy ───────────────────────────────────────────────────────
    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "delay"
    }

    # ── Service registration ─────────────────────────────────────────────────
    service {
      name     = "chat"
      port     = "http"
      provider = "nomad"

      check {
        type     = "http"
        path     = "/health"
        interval = "10s"
        timeout  = "3s"
      }
    }

    task "chat" {
      driver = "docker"

      config {
        image      = "disinto/chat:local"
        force_pull = false
        # Sandbox hardening (#706): cap_drop ALL (no Linux capabilities)
        # tmpfs /tmp for runtime files (64MB)
        # pids_limit 128 (prevent fork bombs)
        # ReadonlyRootfs enforced via entrypoint script (fails if running as root)
        cap_drop   = ["ALL"]
        tmpfs      = ["/tmp:size=64m"]
        pids_limit = 128
        # Security options for sandbox hardening
        # apparmor=unconfined needed for Claude CLI ptrace access
        # no-new-privileges prevents privilege escalation
        security_opt = ["apparmor=unconfined", "no-new-privileges"]
      }

      # ── Volume mounts ──────────────────────────────────────────────────────
      # Mount chat-history for conversation persistence
      volume_mount {
        volume      = "chat-history"
        destination = "/var/lib/chat/history"
        read_only   = false
      }

      # ── Environment: secrets from Vault (S5.2) ──────────────────────────────
      # CHAT_OAUTH_CLIENT_ID, CHAT_OAUTH_CLIENT_SECRET, FORWARD_AUTH_SECRET
      # rendered from kv/disinto/shared/chat via template stanza.
      env {
        FORGE_URL                      = "http://forgejo:3000"
        CHAT_MAX_REQUESTS_PER_HOUR     = "60"
        CHAT_MAX_REQUESTS_PER_DAY      = "1000"
      }

      # ── Vault-templated secrets (S5.2, issue #989) ─────────────────────────
      # Renders chat-secrets.env from Vault KV v2 at kv/disinto/shared/chat.
      # Placeholder values kept < 16 chars to avoid secret-scan CI failures.
      template {
        destination          = "secrets/chat-secrets.env"
        env                  = true
        change_mode          = "restart"
        error_on_missing_key = false
        data                 = <<EOT
{{- with secret "kv/data/disinto/shared/chat" -}}
CHAT_OAUTH_CLIENT_ID={{ .Data.data.chat_oauth_client_id }}
CHAT_OAUTH_CLIENT_SECRET={{ .Data.data.chat_oauth_client_secret }}
FORWARD_AUTH_SECRET={{ .Data.data.forward_auth_secret }}
{{- else -}}
# WARNING: run tools/vault-seed-chat.sh
CHAT_OAUTH_CLIENT_ID=seed-me
CHAT_OAUTH_CLIENT_SECRET=seed-me
FORWARD_AUTH_SECRET=seed-me
{{- end -}}
EOT
      }

      # ── Sandbox hardening (S5.2, #706) ────────────────────────────────────
      # Memory = 512MB (matches docker-compose sandbox hardening)
      resources {
        cpu    = 200
        memory = 512
      }
    }
  }
}
