# =============================================================================
# nomad/jobs/agents-planner-grok.hcl — the planner on Grok 4.7 (xAI).
#
# Step 5 of the "the-planner-pitches" sprint (#1979): the planner pitches one
# sprint toward the vision, or writes nothing. It never files issues and
# never merges.
#
# Set up like agents-architect-grok — same image and loop (dsh harness,
# AGENT_ROLES = "planner"); what differs:
#
#   - Model: dsh's settings.yaml in this job's own DSH_HOME routes to the
#     `xai` provider (OpenAI Responses at api.x.ai/v1, model grok-4.7). The
#     sign-in is an xAI OAuth grant (SuperGrok subscription) in
#     $DSH_HOME/.credentials.yaml, refreshed by dsh itself. It is this
#     agent's own grant: no other process refreshes it.
#   - Identity: forge user planner-bot (Vault kv/disinto/bots/planner).
#   - Data: /srv/disinto/agent-data-grok/planner is bind-mounted at
#     /home/agent/data (docker volumes are enabled on this client; no
#     host_volume, so adding the job needed no Nomad client restart).
#   - Vault role bot-planner, policy bot-planner: it reads only its own
#     bot path plus the shared forge config (kv/data/disinto/shared/forge) —
#     no other bot KV paths, no shared CI config.
#   - No tape volume.
#
# DSH_MODEL / CLAUDE_MODEL only label the tape (backend, run agent); the
# model dsh calls is the one settings.yaml names.
# =============================================================================

job "agents-planner-grok" {
  type        = "service"
  datacenters = ["dc1"]

  group "agents" {
    count = 1

    # ── Vault workload identity (S4.1, issue #955) ───────────────────────────
    # Own role, bot-planner (vault/roles.yaml), bound to nomad_job_id =
    # "agents-planner-grok"; policy bot-planner
    # (vault/policies/bot-planner.hcl): the planner's own bot path plus
    # the shared forge config — the narrowest read set of the agent jobs.
    vault {
      role        = "bot-planner"
      # A Vault token renewal must not restart the task (#1091). The default
      # change_mode is "restart", which SIGKILLed agent containers every 24h
      # and destroyed whatever session was mid-flight. Verified on the agent
      # jobs 2026-08-30T19:53:05Z: "Restart Signaled  Vault: new Vault token
      # acquired" followed by exit 137.
      change_mode = "noop"
    }

    # No network port — agents are outbound-only (poll forgejo, call llama).
    # No service discovery block — nothing health-checks agents over HTTP.

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
      name     = "agents-planner-grok"
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

        # This agent's own data dir (DSH_HOME, logs, sessions): see header.
        volumes = ["/srv/disinto/agent-data-grok/planner:/home/agent/data"]
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
        # The alias llama-server actually serves (--alias). The old value named
        # a model this box does not host; the server ignores the name, but
        # Claude Code sizes its context window from it.
        CLAUDE_MODEL       = "grok-4.7"
        AGENT_ROLES        = "planner"

        # dsh harness. The model comes from this job's DSH_HOME settings.yaml
        # (route xai, grok-4.7; see the header). DSH_BASE_URL only seeds a
        # missing settings.yaml with the llama.cpp route, kept as a fallback.
        # Known dsh gap: wall-clock timeouts write no metrics record (#1186).
        AGENT_HARNESS       = "dsh"
        DSH_HOME            = "/home/agent/data/dsh"
        DSH_PERMISSION_MODE = "danger-full-access"
        # The think-budget proxy on the host, not llama-server (:8081): it caps
        # thinking per request and holds disinto to 2 of llama-server's 4 slots.
        DSH_BASE_URL        = "http://10.10.10.1:8088/v1"
        DSH_MODEL           = "grok-4.7"
        DSH_CONTEXT_WINDOW  = "200000"
        # settings.yaml uses apiKeyEnv indirection; llama-server ignores
        # the key but dsh requires the env to be set.
        LLAMACPP_API_KEY    = "sk-no-key-required"
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
        # Per-organ cadence scheduler (#1388): the loop paces organs on their
        # own intervals (GARDENER_INTERVAL / ARCHITECT_INTERVAL /
        # PLANNER_INTERVAL / SUPERVISOR_INTERVAL).

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
      # Renders the planner's own FORGE_TOKEN / FORGE_PASS /
      # FORGE_PLANNER_TOKEN from Vault KV v2. A single `with secret` block
      # reads the planner's KV path (kv/data/disinto/bots/planner); the
      # `else` branch emits short placeholders on fresh installs where the
      # path is absent. Seed with tools/vault-seed-agents.sh.
      #
      # Placeholder values kept < 16 chars to avoid secret-scan CI failures.
      # error_on_missing_key = false prevents template-pending hangs.
      template {
        destination          = "secrets/bots.env"
        env                  = true
        # noop: static Vault secrets - renewal must not restart the task
        # (#1091 stabilization). Rotation = vault kv put + manual restart.
        change_mode          = "noop"
        error_on_missing_key = false
        data                 = <<EOT
{{- with secret "kv/data/disinto/bots/planner" -}}
FORGE_TOKEN={{ .Data.data.token }}
FORGE_PASS={{ .Data.data.pass }}
FORGE_PLANNER_TOKEN={{ .Data.data.token }}
{{- else -}}
# WARNING: run tools/vault-seed-agents.sh
FORGE_TOKEN=seed-me
FORGE_PASS=seed-me
FORGE_PLANNER_TOKEN=seed-me
{{- end }}
EOT
      }

      # The model runs at xAI; this container holds dsh and the planner
      # session. Sized for one Grok session: 1 GiB keeps 1 GiB of the node
      # free for vault-runner dispatches.
      resources {
        cpu    = 500
        memory = 1024
      }
    }
  }
}
