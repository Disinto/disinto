# =============================================================================
# nomad/jobs/agents-supervisor-opus.hcl — Supervisor agent (Nomad service job)
#
# Part of the opus agent split (issue #589, part of #275). Runs the supervisor
# agent exclusively using Claude Opus via OAuth (claude CLI), with read-write
# docker.sock access for container management (docker restart, etc.).
#
# This job replaces the supervisor loop that previously ran inside the edge
# caddy task (docker/edge/entrypoint.sh). The supervisor now runs as a
# standalone Nomad job with:
#   - Opus model (claude-opus-4-7) via OAuth, not llama API-key mode
#   - Read-write docker.sock for container management
#   - Ops-repo volume for incident journal writes
#   - Claude OAuth credentials via claude-creds host_volume
#
# Host_volume contract:
#   - agent-data-opus-supervisor: per-agent runtime data (logs, state)
#   - claude-creds: OAuth credentials for Anthropic CLI
#   Both declared in nomad/client.hcl.
#
# docker.sock mount:
#   Inline bind-mount (not a host_volume) — socket files cannot be host
#   volumes. Mirrors the edge.hcl dispatcher pattern but with rw instead
#   of ro (supervisor must restart containers).
#
# Not the runtime yet: docker-compose.yml is still the factory's live stack
# until cutover. This file exists so CI can validate it and S4.2 can wire
# `disinto init --backend=nomad --with agents-supervisor-opus` to
# `nomad job run` it.
# =============================================================================

job "agents-supervisor-opus" {
  type        = "service"
  datacenters = ["dc1"]

  group "supervisor" {
    count = 1

    # ── Vault workload identity (S4.1, issue #955) ─────────────────────────
    # Service role for supervisor bot identity. Role defined in
    # vault/roles.yaml, policy in vault/policies/service-agents.hcl.
    # Bound claim pins nomad_job_id = "agents-supervisor-opus".
    vault {
      role = "service-agents"
    }

    # No network ports — supervisor is outbound-only (polls forgejo, calls
    # Claude API, runs docker commands via socket).

    # ── Host-volume mounts ────────────────────────────────────────────────
    # agent-data-opus-supervisor: per-agent runtime data (logs, state files).
    volume "agent-data" {
      type     = "host"
      source   = "agent-data-opus-supervisor"
      read_only = false
    }

    # ops-repo: disinto-ops clone for incident journal writes.
    # Mounted at /home/agent/repos/disinto-ops where the entrypoint bootstrap
    # expects it (vs. _factory/disinto-ops in the all-roles job, to avoid
    # collision with the factory repo clone at _factory/).
    volume "ops-repo" {
      type      = "host"
      source    = "ops-repo"
      read_only = false
    }

    # claude-creds: OAuth credentials for Anthropic Claude CLI.
    # Mounted at /home/agent/.claude for the claude CLI to find
    # .credentials.json. uid=1000 (agent user).
    volume "claude-creds" {
      type     = "host"
      source   = "claude-creds"
      read_only = true
    }

    # Conservative restart — fail fast to the scheduler.
    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "delay"
    }

    # ── Service registration ───────────────────────────────────────────────
    # Supervisor is outbound-only — no HTTP/TCP endpoint to probe.
    service {
      name     = "agents-supervisor-opus"
      provider = "nomad"
    }

    task "supervisor" {
      driver = "docker"

      config {
        image      = "disinto/agents:local"
        force_pull = false

        # apparmor=unconfined matches docker-compose — Claude Code needs
        # ptrace for node.js inspector and /proc access.
        security_opt = ["apparmor=unconfined"]

        # Mount docker.sock via bind-volume (not host volume) for docker
        # backend compat. Nomad host volumes require named volumes from
        # client.hcl; socket files cannot be host volumes. rw because the
        # supervisor must be able to restart containers.
        volumes = ["/var/run/docker.sock:/var/run/docker.sock:rw"]
      }

      volume_mount {
        volume      = "agent-data"
        destination = "/home/agent/data"
        read_only   = false
      }

      volume_mount {
        volume      = "ops-repo"
        destination = "/home/agent/repos/disinto-ops"
        read_only   = false
      }

      volume_mount {
        volume      = "claude-creds"
        destination = "/home/agent/.claude"
        read_only   = true
        # uid 1000 matches the agent user expected by the claude CLI
        # for reading .credentials.json
      }

      # ── Non-secret env ─────────────────────────────────────────────────────
      env {
        AGENT_ROLES        = "supervisor"
        FORGE_REPO         = "disinto-admin/disinto"
        CLAUDE_MODEL       = "claude-opus-4-7"
        POLL_INTERVAL      = "300"
        DISINTO_CONTAINER  = "1"
        PROJECT_NAME       = "disinto"
        PROJECT_REPO_ROOT  = "/home/agent/repos/disinto"
        CLAUDE_TIMEOUT     = "7200"
        CLAUDE_MAX_TURNS   = "60"

        # Supervisor-specific polling interval (20 min = 1200s).
        # The entrypoint loop runs every POLL_INTERVAL (300s); the supervisor
        # checks run every SUPERVISOR_INTERVAL (1200s = 4 iterations).
        SUPERVISOR_INTERVAL = "1200"

        # CLAUDE_CONFIG_DIR points to the mounted claude-creds volume so the
        # claude CLI finds OAuth credentials. Do NOT set ANTHROPIC_BASE_URL
        # or ANTHROPIC_API_KEY — their presence forces API-key mode and
        # bypasses OAuth.
        CLAUDE_CONFIG_DIR = "/home/agent/.claude"
      }

      # ── Nomad-discovered FORGE_URL (issue #567) ───────────────────────────
      # Bridge netns cannot resolve `forgejo:3000`. Render from Nomad service
      # discovery — matches edge.hcl (post-#1157).
      template {
        destination = "secrets/forge-url.env"
        env         = true
        change_mode = "restart"
        data        = <<EOT
{{ range nomadService "forgejo" -}}
FORGE_URL=http://{{ .Address }}:{{ .Port }}
{{- end }}
EOT
      }

      # ── Vault-templated bot tokens (S4.1, issue #955) ─────────────────────
      # Renders FORGE_TOKEN + FORGE_PASS for the supervisor bot from Vault
      # KV v2. Mirrors the same block structure as nomad/jobs/agents.hcl.
      template {
        destination          = "secrets/bots.env"
        env                  = true
        change_mode          = "restart"
        error_on_missing_key = false
        data                 = <<EOT
{{- with secret "kv/data/disinto/bots/supervisor" -}}
FORGE_TOKEN={{ .Data.data.token }}
FORGE_PASS={{ .Data.data.pass }}
{{- else -}}
# WARNING: run tools/vault-seed-agents.sh
FORGE_TOKEN=seed-me
FORGE_PASS=seed-me
{{- end }}

{{ with secret "kv/data/disinto/bots/vault" -}}
FORGE_VAULT_TOKEN={{ .Data.data.token }}
{{- else -}}
FORGE_VAULT_TOKEN=seed-me
{{- end }}
EOT
      }

      # Supervisor needs CPU + memory headroom for inference sessions.
      resources {
        cpu    = 2000
        memory = 4096
      }
    }
  }
}
