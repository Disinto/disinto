# =============================================================================
# nomad/jobs/woodpecker-agent.hcl — Woodpecker CI agent (Nomad service job)
#
# Part of the Nomad+Vault migration (S3.2, issue #935).
# Drop-in for the current docker-compose setup with host networking +
# docker.sock mount, enabling the agent to spawn containers via the
# mounted socket.
#
# Host networking:
#   Uses network_mode = "host" to match the compose setup. The Woodpecker
#   server gRPC endpoint is addressed via Nomad service discovery using
#   the host's IP address (10.10.10.x:9000), since the server's port
#   binding in Nomad binds to the allocation's IP, not localhost.
#
# Vault integration:
#   - vault { role = "service-woodpecker-agent" } at the group scope — the
#     task's workload-identity JWT is exchanged for a Vault token carrying
#     the policy named on that role. Role + policy are defined in
#     vault/roles.yaml + vault/policies/service-woodpecker.hcl.
#   - template stanza pulls WOODPECKER_AGENT_SECRET from Vault KV v2
#     at kv/disinto/shared/woodpecker and writes it to secrets/agent.env.
#     Seeded on fresh boxes by tools/vault-seed-woodpecker.sh.
# =============================================================================

job "woodpecker-agent" {
  type        = "service"
  datacenters = ["dc1"]

  group "woodpecker-agent" {
    count = 1

    # ── Vault workload identity ─────────────────────────────────────────
    # `role = "service-woodpecker-agent"` is defined in vault/roles.yaml and
    # applied by tools/vault-apply-roles.sh. The role's bound
    # claim pins nomad_job_id = "woodpecker-agent" — renaming this
    # jobspec's `job "woodpecker-agent"` without updating vault/roles.yaml
    # will make token exchange fail at placement with a "claim mismatch"
    # error.
    vault {
      role = "service-woodpecker-agent"
    }

    # Health check port: static 3333 for Nomad service discovery. The agent
    # exposes :3333/healthz for Nomad to probe.
    network {
      port "healthz" {
        static = 3333
      }
    }

    # Native Nomad service discovery for the health check endpoint.
    service {
      name     = "woodpecker-agent"
      port     = "healthz"
      provider = "nomad"

      check {
        type     = "http"
        path     = "/healthz"
        interval = "15s"
        timeout  = "3s"
      }
    }

    # Conservative restart policy — fail fast to the scheduler instead of
    # spinning on a broken image/config. 3 attempts over 5m, then back off.
    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "delay"
    }

    task "woodpecker-agent" {
      driver = "docker"

      config {
        image     = "woodpeckerci/woodpecker-agent:v3"
        network_mode = "host"
        privileged = true
        volumes   = ["/var/run/docker.sock:/var/run/docker.sock"]
      }

      # Non-secret env — server address, gRPC security, concurrency limit,
      # and health check endpoint. Nothing sensitive here.
      #
      # WOODPECKER_SERVER uses Nomad's attribute template to get the host's
      # IP address (10.10.10.x). The server's gRPC port 9000 is bound via
      # Nomad's port stanza to the allocation's IP (not localhost), so the
      # agent must use the LXC's eth0 IP, not 127.0.0.1.
      env {
        WOODPECKER_SERVER         = "{{ env \"attr.unique.network.ip-address\" }}:9000"
        WOODPECKER_GRPC_SECURE    = "false"
        WOODPECKER_MAX_WORKFLOWS  = "1"
        WOODPECKER_HEALTHCHECK_ADDR = ":3333"
      }

      # ── Vault-templated agent secret ──────────────────────────────────
      # Renders <task-dir>/secrets/agent.env (per-alloc secrets dir,
      # never on disk on the host root filesystem, never in `nomad job
      # inspect` output). `env = true` merges WOODPECKER_AGENT_SECRET
      # from the file into the task environment.
      #
      # Vault path: `kv/data/disinto/shared/woodpecker`. The literal
      # `/data/` segment is required by consul-template for KV v2 mounts.
      #
      # Empty-Vault fallback (`with ... else ...`): on a fresh LXC where
      # the KV path is absent, consul-template's `with` short-circuits to
      # the `else` branch. Emitting a visible placeholder means the
      # container still boots, but with an obviously-bad secret that an
      # operator will spot — better than the agent failing silently with
      # auth errors. Seed the path with tools/vault-seed-woodpecker.sh
      # to replace the placeholder.
      #
      # Placeholder values are kept short on purpose: the repo-wide
      # secret-scan (.woodpecker/secret-scan.yml → lib/secret-scan.sh)
      # flags `TOKEN=<16+ non-space chars>` as a plaintext secret, so a
      # descriptive long placeholder would fail CI on every PR that touched
      # this file. "seed-me" is < 16 chars and still distinctive enough
      # to surface in a `grep WOODPECKER` audit.
      template {
        destination          = "secrets/agent.env"
        env                  = true
        change_mode          = "restart"
        error_on_missing_key = false
        data                 = <<EOT
{{- with secret "kv/data/disinto/shared/woodpecker" -}}
WOODPECKER_AGENT_SECRET={{ .Data.data.agent_secret }}
{{- else -}}
# WARNING: kv/disinto/shared/woodpecker is empty — run tools/vault-seed-woodpecker.sh
WOODPECKER_AGENT_SECRET=seed-me
{{- end -}}
EOT
      }

      # Baseline — tune once we have real usage numbers under nomad.
      # Conservative limits so an unhealthy agent can't starve the node.
      resources {
        cpu    = 200
        memory = 256
      }
    }
  }
}
