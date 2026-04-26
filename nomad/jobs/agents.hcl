# =============================================================================
# nomad/jobs/agents.hcl — All-role agent polling loop (Nomad service job)
#
# Part of the Nomad+Vault migration (S4.1, issue #955). Runs the main bot
# polling loop with 6 agent roles (review, dev, gardener, architect,
# planner, predictor) against the local llama server.
# Supervisor runs as a standalone opus job (nomad/jobs/agents-supervisor-opus.hcl).
#
# Host_volume contract:
#   This job mounts agent-data, project-repos, and ops-repo from
#   nomad/client.hcl. Paths under /srv/disinto/* are created by
#   lib/init/nomad/cluster-up.sh before any job references them.
#
# Vault integration (S4.1):
#   - vault { role = "service-agents" } at group scope — workload-identity
#     JWT exchanged for a Vault token carrying the composite service-agents
#     policy (vault/policies/service-agents.hcl), which grants read access
#     to the 6 bot KV namespaces (supervisor is separate) + vault bot + shared forge config.
#   - template stanza renders per-bot FORGE_*_TOKEN + FORGE_PASS from Vault
#     KV v2 at kv/disinto/bots/<role>.
#   - Seeded on fresh boxes by tools/vault-seed-agents.sh.
#
# Not the runtime yet: docker-compose.yml is still the factory's live stack
# until cutover. This file exists so CI can validate it and S4.2 can wire
# `disinto init --backend=nomad --with agents` to `nomad job run` it.
# =============================================================================

job "agents" {
  type        = "service"
  datacenters = ["dc1"]

  group "agents" {
    count = 1

    # ── Vault workload identity (S4.1, issue #955) ───────────────────────────
    # Composite role covering all 7 bot identities + vault bot. Role defined
    # in vault/roles.yaml, policy in vault/policies/service-agents.hcl.
    # Bound claim pins nomad_job_id = "agents".
    vault {
      role = "service-agents"
    }

    # No network port — agents are outbound-only (poll forgejo, call llama).
    # No service discovery block — nothing health-checks agents over HTTP.

    volume "agent-data" {
      type      = "host"
      source    = "agent-data"
      read_only = false
    }

    volume "project-repos" {
      type      = "host"
      source    = "project-repos"
      read_only = false
    }

    volume "ops-repo" {
      type      = "host"
      source    = "ops-repo"
      read_only = true
    }

    # Operator-managed per-env factory project TOMLs (#794). Mounted RO into
    # the path bootstrap_factory_repo already reads from, so per-env config
    # changes do not require an image rebuild. Backed by /srv/disinto/projects/
    # on the host (see nomad/client.hcl).
    volume "factory-projects" {
      type      = "host"
      source    = "factory-projects"
      read_only = true
    }

    # Conservative restart — fail fast to the scheduler.
    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "delay"
    }

    # ── Service registration ────────────────────────────────────────────────
    # Agents are outbound-only (poll forgejo, call llama) — no HTTP/TCP
    # endpoint to probe. The Nomad native provider only supports tcp/http
    # checks, not script checks. Registering without a check block means
    # Nomad tracks health via task lifecycle: task running = healthy,
    # task dead = service deregistered. This matches the docker-compose
    # pgrep healthcheck semantics (process alive = healthy).
    service {
      name     = "agents"
      provider = "nomad"
    }

    task "agents" {
      driver = "docker"

      config {
        image      = "disinto/agents:local"
        force_pull = false

        # apparmor=unconfined matches docker-compose — Claude Code needs
        # ptrace for node.js inspector and /proc access.
        security_opt = ["apparmor=unconfined"]
      }

      volume_mount {
        volume      = "agent-data"
        destination = "/home/agent/data"
        read_only   = false
      }

      volume_mount {
        volume      = "project-repos"
        destination = "/home/agent/repos"
        read_only   = false
      }

      volume_mount {
        volume      = "ops-repo"
        destination = "/home/agent/repos/_factory/disinto-ops"
        read_only   = true
      }

      # factory-projects: surfaces /srv/disinto/projects/ inside the container
      # at the path bootstrap_factory_repo / seed_projects_from_host_volume
      # already reads from (#794).
      volume_mount {
        volume      = "factory-projects"
        destination = "/srv/disinto/project-repos/_factory/projects"
        read_only   = true
      }

      # ── Non-secret env ─────────────────────────────────────────────────────
      # FORGE_URL is rendered from Nomad service discovery in the template
      # block below — the bridge-network netns cannot resolve the `forgejo`
      # hostname (no Consul DNS). Same pattern as edge.hcl post-#1157 (issue
      # #567).
      env {
        FORGE_REPO         = "disinto-admin/disinto"
        # Activate bootstrap_factory_repo so DISINTO_DIR switches to the
        # live clone and per-env TOMLs from factory-projects are picked up
        # rather than the stale baked image copy (#794).
        FACTORY_REPO       = "disinto-admin/disinto"
        ANTHROPIC_BASE_URL = "http://10.10.10.1:8081"
        ANTHROPIC_API_KEY  = "sk-no-key-required"
        CLAUDE_MODEL       = "unsloth/Qwen3.5-35B-A3B"
        AGENT_ROLES        = "review,dev,gardener,architect,planner,predictor"
        POLL_INTERVAL      = "300"
        DISINTO_CONTAINER  = "1"
        PROJECT_NAME       = "project"
        PROJECT_REPO_ROOT  = "/home/agent/repos/project"
        CLAUDE_TIMEOUT     = "7200"
        CLAUDE_MAX_TURNS   = "60"

        # llama-specific Claude Code tuning
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1"
        CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS   = "1"
        CLAUDE_AUTOCOMPACT_PCT_OVERRIDE          = "60"
      }

      # ── Nomad-discovered FORGE_URL (issue #567) ───────────────────────────
      # Bridge netns cannot resolve `forgejo:3000`. Render from Nomad service
      # discovery — matches edge.hcl (post-#1157) and keeps the job portable
      # across boxes with different bridge IPs.
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
      # Renders per-bot FORGE_*_TOKEN + FORGE_PASS from Vault KV v2.
      # Each `with secret ...` block reads one bot's KV path; the `else`
      # branch emits short placeholders on fresh installs where the path
      # is absent. Seed with tools/vault-seed-agents.sh.
      #
      # Placeholder values kept < 16 chars to avoid secret-scan CI failures.
      # error_on_missing_key = false prevents template-pending hangs.
      template {
        destination          = "secrets/bots.env"
        env                  = true
        change_mode          = "restart"
        error_on_missing_key = false
        data                 = <<EOT
{{- with secret "kv/data/disinto/bots/dev" -}}
FORGE_TOKEN={{ .Data.data.token }}
FORGE_PASS={{ .Data.data.pass }}
{{- else -}}
# WARNING: run tools/vault-seed-agents.sh
FORGE_TOKEN=seed-me
FORGE_PASS=seed-me
{{- end }}

{{ with secret "kv/data/disinto/bots/review" -}}
FORGE_REVIEW_TOKEN={{ .Data.data.token }}
{{- else -}}
FORGE_REVIEW_TOKEN=seed-me
{{- end }}

{{ with secret "kv/data/disinto/bots/gardener" -}}
FORGE_GARDENER_TOKEN={{ .Data.data.token }}
{{- else -}}
FORGE_GARDENER_TOKEN=seed-me
{{- end }}

{{ with secret "kv/data/disinto/bots/architect" -}}
FORGE_ARCHITECT_TOKEN={{ .Data.data.token }}
{{- else -}}
FORGE_ARCHITECT_TOKEN=seed-me
{{- end }}

{{ with secret "kv/data/disinto/bots/planner" -}}
FORGE_PLANNER_TOKEN={{ .Data.data.token }}
{{- else -}}
FORGE_PLANNER_TOKEN=seed-me
{{- end }}

{{ with secret "kv/data/disinto/bots/predictor" -}}
FORGE_PREDICTOR_TOKEN={{ .Data.data.token }}
{{- else -}}
FORGE_PREDICTOR_TOKEN=seed-me
{{- end }}

{{ with secret "kv/data/disinto/bots/supervisor" -}}
FORGE_SUPERVISOR_TOKEN={{ .Data.data.token }}
{{- else -}}
FORGE_SUPERVISOR_TOKEN=seed-me
{{- end }}

{{ with secret "kv/data/disinto/bots/vault" -}}
FORGE_VAULT_TOKEN={{ .Data.data.token }}
{{- else -}}
FORGE_VAULT_TOKEN=seed-me
{{- end }}
EOT
      }

      # Agents run Claude/llama sessions — need CPU + memory headroom.
      resources {
        cpu    = 500
        memory = 1024
      }
    }
  }
}
