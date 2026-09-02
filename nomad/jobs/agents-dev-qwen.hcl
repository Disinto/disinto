# =============================================================================
# nomad/jobs/agents-dev-qwen.hcl — one role, one agent, one llama slot.
#
# WHY THIS EXISTS
#
# agents.hcl runs six roles in one container, so review-poll and a dev
# session can call claude at the same time. Two claude processes are two
# llama slots, and the slot count then depends on what the loop happens to
# be doing. One role for each job makes the count a property of the
# deployment: three jobs are three slots, and llama-server holds four.
#
# This job reuses the dev-bot identity and its Vault path, because
# agents.hcl is stopped and nothing else holds them.
#
# THE CONTEXT BUDGET
#
# CLAUDE_AUTOCOMPACT_PCT_OVERRIDE is 50, giving a lane of 100,000 (#1069).
# The belief has now been measured: Claude Code thinks this model has a
# 200,000-token window, and the percentage is taken of that. The pool is
# 327,680 tokens of --kv-unified KV, which /slots reports in full to every
# slot rather than partitioning it, so two agents at 100k leaves roughly a
# third of the pool for the other consumers on this host.
#
# CLAUDE_CODE_AUTO_COMPACT_WINDOW cannot raise the believed window; gF()
# clamps with Math.min. See the note at the env block.
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
#   - vault { role = "agents-dev-qwen" } at group scope — workload-identity
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

job "agents-dev-qwen" {
  type        = "service"
  datacenters = ["dc1"]

  group "agents" {
    count = 1

    # ── Vault workload identity (S4.1, issue #955) ───────────────────────────
    # Per-role identity (its own role since the split, #1083). Role defined
    # in vault/roles.yaml — its bound claim pins nomad_job_id =
    # "agents-dev-qwen"; the policy is the composite service-agents policy
    # (vault/policies/service-agents.hcl) covering all 7 bot identities +
    # vault bot.
    vault {
      role        = "agents-dev-qwen"
      # A Vault token renewal must not restart the task (#1091). The default
      # change_mode is "restart", which SIGKILLed the container every 24h and
      # destroyed whatever dev session was mid-flight. Verified on
      # 2026-08-30T19:53:05Z: "Restart Signaled  Vault: new Vault token
      # acquired" followed by exit 137.
      change_mode = "noop"
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
      name     = "agents-dev-qwen"
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
        # CI log access (#1114). lib/ci-debug.sh reads pipeline status and
        # step logs over the Woodpecker REST API so the dev agent can see why
        # a PR's CI failed. The server is addressed by container IP because
        # port 8000 bare serves the SPA -- the API lives under the /ci subpath
        # that edge's Caddy strips. WOODPECKER_TOKEN comes from Vault below.
        WOODPECKER_SERVER  = "http://10.10.10.132:8000/ci"
        WOODPECKER_REPO_ID = "1"
        ANTHROPIC_BASE_URL = "http://10.10.10.1:8081"
        ANTHROPIC_API_KEY  = "sk-no-key-required"
        # The alias llama-server actually serves (--alias). The old value named
        # a model this box does not host; the server ignores the name, but
        # Claude Code sizes its context window from it.
        CLAUDE_MODEL       = "unsloth/Qwen3.8-27B"
        AGENT_ROLES        = "dev"
        POLL_INTERVAL      = "300"
        DISINTO_CONTAINER  = "1"
        PROJECT_NAME       = "project"
        PROJECT_REPO_ROOT  = "/home/agent/repos/project"
        CLAUDE_TIMEOUT     = "7200"
        # Raised 60 -> 100 on 2026-08-31. Telemetry (#1101) showed five of six
        # consecutive sessions ending at exactly turns=61, i.e. at the ceiling,
        # not at a natural stopping point. Durations were 34-104 min against a
        # 7200s timeout, so wall-clock had headroom the turn budget did not.
        # #1105 hit 61 twice even with a written spec for the work, so the
        # constraint was steps, not information. CLAUDE_TIMEOUT still caps the
        # session at 2h.
        CLAUDE_MAX_TURNS   = "100"
        # GARDENER_INTERVAL dropped (#872): gardener now runs per-iteration
        # via gardener/gardener-step.sh, paced by POLL_INTERVAL.

        # llama-specific Claude Code tuning
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1"
        CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS   = "1"
        # The percentage is a percentage of the window Claude Code believes
        # the model has. lP()/gF() in cli.js resolve that window from the
        # model name; llama-server serves a name Claude Code does not know.
        #
        # CLAUDE_CODE_AUTO_COMPACT_WINDOW does NOT raise that window. gF does
        # K = Math.min(K, z), so the variable can only clamp downwards. It was
        # set to 327680 here, above the believed window, and was therefore a
        # no-op. It is pinned to 200000 now to say so out loud.
        #
        # MEASURED on the #1073 session (2026-08-28): the result row reports
        # contextWindow = 200000, and with the override at 32 the ten
        # auto-compactions fired at pre_tokens 59,012-87,558, clustering on
        # 64,000 = 32 per cent of 200,000. pre_tokens overshoots the
        # threshold by the size of the last tool result, so treat the
        # configured lane as a floor and expect peaks above it.
        #
        # 50 per cent puts the lane at 100,000 (#1069). That session spent
        # about half its 61 turns re-reading files a 64k lane kept dropping.
        # The KV cache is --kv-unified, so /slots reports the full 327,680 to
        # every slot and the pool is shared rather than partitioned: two
        # agents at a 100k lane leaves roughly a third of the pool for the
        # other consumers on this host.
        CLAUDE_CODE_AUTO_COMPACT_WINDOW          = "200000"
        CLAUDE_AUTOCOMPACT_PCT_OVERRIDE          = "50"

        # Claude Code never sends reasoning_effort — the string does not
        # appear in cli.js — so the server's --chat-template-kwargs decides
        # the reasoning level and the client cannot lower it. What the
        # client CAN do is stop asking for thinking at all (cli.js: b6 =
        # type!=="disabled" && !CLAUDE_CODE_DISABLE_THINKING).
        CLAUDE_CODE_DISABLE_THINKING             = "1"
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
