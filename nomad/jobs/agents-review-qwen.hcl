# =============================================================================
# nomad/jobs/agents-review-qwen.hcl — review-role agent job (local Qwen model)
#
# Per-role variant of nomad/jobs/agents.hcl for the review-qwen bot: same
# image, volumes, and Vault-templated bot tokens, with AGENT_ROLES pinned to
# "review". Runs against the local llama-server (ANTHROPIC_BASE_URL) instead
# of the Anthropic API.
#
# Autocompact lane (#1069):
#   CLAUDE_AUTOCOMPACT_PCT_OVERRIDE is a percentage of the context window
#   Claude Code *believes* the model has — resolved from the model name
#   (200k for unsloth/Qwen3.8-27B), NOT the llama-server's real n_ctx.
#   CLAUDE_CODE_AUTO_COMPACT_WINDOW can only clamp that belief *downward*
#   (cli.js gF(): K = Math.min(K, z)), so any value above the believed
#   window is a no-op. It is pinned to 200000 to say so.
#
#   The threshold is pct of the *usable* window: believed window minus a
#   20k output reservation (cli.js gF(): min(window, AUTO_COMPACT_WINDOW)
#   - min(max_output, 20000)). So 50% of (200k - 20k) = a 90k threshold —
#   auto-compact fires when a session's context exceeds ~90k tokens.
#   The server runs --kv-unified with --ctx-size 327680, so the budget is
#   the sum of all concurrent sessions against one shared pool, not a
#   per-slot cap — two agents at 90k lanes leave ~145k of pool for other
#   consumers on this host.
#
#   CLAUDE_MAX_TURNS stays 60 deliberately: more turns at a thrashing lane
#   buys more thrash. Widening the lane is the lever.
#
# Host_volume contract: same as nomad/jobs/agents.hcl — agent-data,
# project-repos, ops-repo, and factory-projects are declared in
# nomad/client.hcl and created by lib/init/nomad/cluster-up.sh.
# =============================================================================

job "agents-review-qwen" {
  type        = "service"
  datacenters = ["dc1"]

  group "agents" {
    count = 1

    # ── Vault workload identity ─────────────────────────────────────────────
    # Composite role covering all bot identities (vault/policies/
    # service-agents.hcl) — same role as nomad/jobs/agents.hcl. The template
    # below renders the full bot token set; this job authenticates as the
    # review bot (kv/disinto/bots/review).
    vault {
      role        = "service-agents"
      change_mode = "noop"
    }

    # No network port — the agent is outbound-only (polls forgejo, calls
    # llama). No service check — task lifecycle is the health signal, same
    # as nomad/jobs/agents.hcl.

    # agent-data: intentionally the same host_volume source as the base
    # `agents` job (nomad/client.hcl) — per-role log subdirs
    # (logs/dev/, logs/review/) keep output separate, only
    # agent-entrypoint.log interleaves. If the base job still runs on this
    # node during the cutover overlap it would double-write the role log
    # dirs and race the mv-based rotation in dev/dev-agent.sh; give these
    # jobs dedicated sources if that overlap proves longer than expected.
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

    # Operator-managed per-env factory project TOMLs (#794), mounted RO into
    # the path bootstrap_factory_repo already reads from.
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

    service {
      name     = "agents-review-qwen"
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
        destination = "/home/agent/repos/disinto-ops"
        read_only   = true
      }

      # factory-projects: surfaces /srv/disinto/projects/ (host) inside the
      # container at the contracted path /srv/disinto/project-repos/_factory/
      # projects — the path bootstrap_factory_repo /
      # seed_projects_from_host_volume read from (#794, nomad/client.hcl).
      volume_mount {
        volume      = "factory-projects"
        destination = "/srv/disinto/project-repos/_factory/projects"
        read_only   = true
      }

      # ── Non-secret env ─────────────────────────────────────────────────────
      # FORGE_URL is rendered from Nomad service discovery in the template
      # block below — the bridge-network netns cannot resolve the `forgejo`
      # hostname (no Consul DNS). Same pattern as nomad/jobs/agents.hcl.
      env {
        FORGE_REPO         = "disinto-admin/disinto"
        FACTORY_REPO       = "disinto-admin/disinto"
        # CI log access (#1114). lib/ci-debug.sh reads pipeline status and
        # step logs over the Woodpecker REST API so the dev agent can see why
        # a PR's CI failed. The server is addressed by container IP because
        # port 8000 bare serves the SPA -- the API lives under the /ci subpath
        # that edge's Caddy strips. WOODPECKER_TOKEN comes from Vault below.
        WOODPECKER_SERVER  = "http://10.10.10.132:8000/ci"
        WOODPECKER_REPO_ID = "1"
        # Set explicitly (not left to the entrypoint's first-TOML parse):
        # under set -u, ensure_project_clone aborts on an unbound
        # PROJECT_NAME, and the baked image carries no projects/*.toml.
        PROJECT_NAME       = "disinto"
        PROJECT_REPO_ROOT  = "/home/agent/repos/disinto"
        PROJECT_TOML       = "/srv/disinto/project-repos/_factory/projects/disinto.toml"
        ANTHROPIC_BASE_URL = "http://10.10.10.1:8081"
        ANTHROPIC_API_KEY  = "sk-no-key-required"
        CLAUDE_MODEL       = "unsloth/Qwen3.8-27B"
        AGENT_ROLES        = "review"
        POLL_INTERVAL      = "300"
        DISINTO_CONTAINER  = "1"
        CLAUDE_TIMEOUT     = "7200"
        CLAUDE_MAX_TURNS   = "60"

        # llama-specific Claude Code tuning
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1"
        CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS   = "1"
        CLAUDE_CODE_DISABLE_THINKING             = "1"

        # Autocompact lane (#1069) — see the file header for the rationale:
        # 50% of the usable window (200k believed - 20k output reservation)
        # = 90k threshold; the window var is pinned to the believed window
        # because it can only clamp downward.
        CLAUDE_AUTOCOMPACT_PCT_OVERRIDE   = "50"
        CLAUDE_CODE_AUTO_COMPACT_WINDOW   = "200000"
      }

      # ── Nomad-discovered FORGE_URL ────────────────────────────────────────
      # Bridge netns cannot resolve `forgejo:3000`. Render from Nomad service
      # discovery — matches nomad/jobs/agents.hcl and keeps the job portable
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

      # ── Vault-templated bot tokens ────────────────────────────────────────
      # Renders the full bot token set from Vault KV v2, same as
      # nomad/jobs/agents.hcl. This job authenticates as the review bot:
      # FORGE_TOKEN/FORGE_PASS come from kv/disinto/bots/review.
      #
      # Placeholder values kept < 16 chars to avoid secret-scan CI failures.
      # error_on_missing_key = false prevents template-pending hangs.
      template {
        destination          = "secrets/bots.env"
        env                  = true
        change_mode          = "restart"
        error_on_missing_key = false
        data                 = <<EOT
{{- with secret "kv/data/disinto/bots/review" -}}
FORGE_TOKEN={{ .Data.data.token }}
FORGE_PASS={{ .Data.data.pass }}
{{- else -}}
# WARNING: run tools/vault-seed-agents.sh
FORGE_TOKEN=seed-me
FORGE_PASS=seed-me
{{- end }}

{{ with secret "kv/data/disinto/bots/dev" -}}
FORGE_DEV_TOKEN={{ .Data.data.token }}
{{- else -}}
FORGE_DEV_TOKEN=seed-me
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

{{ with secret "kv/data/disinto/bots/filer" -}}
FORGE_FILER_TOKEN={{ .Data.data.token }}
{{- else -}}
FORGE_FILER_TOKEN=seed-me
{{- end }}

{{ with secret "kv/data/disinto/shared/ci" -}}
WOODPECKER_TOKEN={{ .Data.data.woodpecker_token }}
{{- else -}}
WOODPECKER_TOKEN=seed-me
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
