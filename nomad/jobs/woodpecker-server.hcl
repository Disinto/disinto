# =============================================================================
# nomad/jobs/woodpecker-server.hcl — Woodpecker CI server (Nomad service job)
#
# Part of the Nomad+Vault migration (S3.1, issue #934).
# Runs the Woodpecker CI web UI + gRPC endpoint as a Nomad service job,
# reading its Forgejo OAuth + agent secret from Vault via workload identity.
#
# Host_volume contract:
#   This job mounts the `woodpecker-data` host_volume declared in
#   nomad/client.hcl. That volume is backed by /srv/disinto/woodpecker-data
#   on the factory box, created by lib/init/nomad/cluster-up.sh before any
#   job references it. Keep the `source = "woodpecker-data"` below in sync
#   with the host_volume stanza in client.hcl — drift = scheduling failures.
#
# Vault integration (S2.4 pattern):
#   - vault { role = "service-woodpecker" } at the group scope — the task's
#     workload-identity JWT is exchanged for a Vault token carrying the
#     policy named on that role. Role + policy are defined in
#     vault/roles.yaml + vault/policies/service-woodpecker.hcl.
#   - template { destination = "secrets/wp.env" env = true } pulls
#     WOODPECKER_AGENT_SECRET, WOODPECKER_FORGEJO_CLIENT, and
#     WOODPECKER_FORGEJO_SECRET out of Vault KV v2 at
#     kv/disinto/shared/woodpecker and merges them into the task env.
#     Agent secret seeded by tools/vault-seed-woodpecker.sh; OAuth
#     client/secret seeded by S3.3 (wp-oauth-register.sh).
#   - Non-secret env (DB driver, Forgejo URL, host URL, open registration)
#     stays inline below — not sensitive, not worth round-tripping through
#     Vault.
#
# Not the runtime yet: docker-compose.yml is still the factory's live stack
# until cutover. This file exists so CI can validate it and S3.4 can wire
# `disinto init --backend=nomad --with woodpecker` to `nomad job run` it.
# =============================================================================

job "woodpecker-server" {
  type        = "service"
  datacenters = ["dc1"]

  group "woodpecker-server" {
    count = 1

    # ── Vault workload identity (S2.4 pattern) ──────────────────────────────
    # `role = "service-woodpecker"` is defined in vault/roles.yaml and
    # applied by tools/vault-apply-roles.sh (S2.3). The role's bound
    # claim pins nomad_job_id = "woodpecker" — note the job_id in
    # vault/roles.yaml is "woodpecker" (matching the roles.yaml entry),
    # but the actual Nomad job name here is "woodpecker-server". Update
    # vault/roles.yaml job_id to "woodpecker-server" if the bound claim
    # enforces an exact match at placement.
    vault {
      role = "service-woodpecker"
    }

    # HTTP UI (:8000) + gRPC agent endpoint (:9000). Static ports match
    # docker-compose's published ports so the rest of the factory keeps
    # reaching woodpecker at the same host:port during and after cutover.
    network {
      port "http" {
        static = 8000
        to     = 8000
      }
      port "grpc" {
        static = 9000
        to     = 9000
      }
    }

    # Host-volume mount: declared in nomad/client.hcl, path
    # /srv/disinto/woodpecker-data on the factory box.
    volume "woodpecker-data" {
      type      = "host"
      source    = "woodpecker-data"
      read_only = false
    }

    # Conservative restart policy — fail fast to the scheduler instead of
    # spinning on a broken image/config. 3 attempts over 5m, then back off.
    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "delay"
    }

    # Native Nomad service discovery (no Consul in this factory cluster).
    # Health check gates the service as healthy only after the HTTP API is
    # up; initial_status is deliberately unset so Nomad waits for the first
    # probe to pass before marking the allocation healthy on boot.
    service {
      name     = "woodpecker"
      port     = "http"
      provider = "nomad"

      check {
        type     = "http"
        path     = "/healthz"
        interval = "10s"
        timeout  = "3s"
      }
    }

    task "woodpecker-server" {
      driver = "docker"

      config {
        image = "woodpeckerci/woodpecker-server:v3"
        ports = ["http", "grpc"]
      }

      volume_mount {
        volume      = "woodpecker-data"
        destination = "/var/lib/woodpecker"
        read_only   = false
      }

      # Non-secret env — Forgejo integration flags, public URL, DB driver.
      # Nothing sensitive here, so this stays inline. Secret-bearing env
      # (agent secret, OAuth client/secret) lives in the template stanza
      # below and is merged into task env.
      env {
        WOODPECKER_FORGEJO              = "true"
        WOODPECKER_FORGEJO_URL          = "https://self.disinto.ai/forge"
        WOODPECKER_HOST                 = "https://self.disinto.ai/ci"
        WOODPECKER_OPEN                 = "true"
        WOODPECKER_DATABASE_DRIVER      = "sqlite3"
        WOODPECKER_DATABASE_DATASOURCE  = "/var/lib/woodpecker/woodpecker.sqlite"
      }

      # ── Vault-templated secrets env (S2.4 pattern) ─────────────────────────
      # Renders `<task-dir>/secrets/wp.env` (per-alloc secrets dir, never on
      # disk on the host root filesystem). `env = true` merges every KEY=VAL
      # line into the task environment. `change_mode = "restart"` re-runs the
      # task whenever a watched secret's value in Vault changes.
      #
      # Vault path: `kv/data/disinto/shared/woodpecker`. The literal `/data/`
      # segment is required by consul-template for KV v2 mounts.
      #
      # Empty-Vault fallback (`with ... else ...`): on a fresh LXC where
      # the KV path is absent, consul-template's `with` short-circuits to
      # the `else` branch. Emitting visible placeholders means the container
      # still boots, but with obviously-bad secrets. Seed the path with
      # tools/vault-seed-woodpecker.sh (agent_secret) and S3.3's
      # wp-oauth-register.sh (forgejo_client, forgejo_secret).
      #
      # Placeholder values are kept short on purpose: the repo-wide
      # secret-scan flags `TOKEN=<16+ non-space chars>` as a plaintext
      # secret; "seed-me" is < 16 chars and still distinctive.
      template {
        destination          = "secrets/wp.env"
        env                  = true
        change_mode          = "restart"
        error_on_missing_key = false
        data                 = <<EOT
{{- with secret "kv/data/disinto/shared/woodpecker" -}}
WOODPECKER_AGENT_SECRET={{ .Data.data.agent_secret }}
WOODPECKER_FORGEJO_CLIENT={{ .Data.data.forgejo_client }}
WOODPECKER_FORGEJO_SECRET={{ .Data.data.forgejo_secret }}
{{- else -}}
# WARNING: kv/disinto/shared/woodpecker is empty — run tools/vault-seed-woodpecker.sh + S3.3
WOODPECKER_AGENT_SECRET=seed-me
WOODPECKER_FORGEJO_CLIENT=seed-me
WOODPECKER_FORGEJO_SECRET=seed-me
{{- end -}}
EOT
      }

      resources {
        cpu    = 300
        memory = 512
      }
    }
  }
}
