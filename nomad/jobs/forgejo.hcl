# =============================================================================
# nomad/jobs/forgejo.hcl — Forgejo git server (Nomad service job)
#
# Part of the Nomad+Vault migration (S1.1, issue #840; S2.4, issue #882).
# First jobspec to land under nomad/jobs/ — proves the docker driver +
# host_volume plumbing from Step 0 (client.hcl) by running a real factory
# service. S2.4 layered Vault integration on top: admin/internal secrets
# now render via workload identity + template stanza instead of inline env.
#
# Host_volume contract:
#   This job mounts the `forgejo-data` host_volume declared in
#   nomad/client.hcl. That volume is backed by /srv/disinto/forgejo-data on
#   the factory box, created by lib/init/nomad/cluster-up.sh before any job
#   references it. Keep the `source = "forgejo-data"` below in sync with the
#   host_volume stanza in client.hcl — drift = scheduling failures.
#
# Vault integration (S2.4):
#   - vault { role = "service-forgejo" } at the group scope — the task's
#     workload-identity JWT is exchanged for a Vault token carrying the
#     policy named on that role. Role + policy are defined in
#     vault/roles.yaml + vault/policies/service-forgejo.hcl.
#   - template { destination = "secrets/forgejo.env" env = true } pulls
#     FORGEJO__security__{SECRET_KEY,INTERNAL_TOKEN} out of Vault KV v2
#     at kv/disinto/shared/forgejo and merges them into the task env.
#     Seeded on fresh boxes by tools/vault-seed-forgejo.sh.
#   - Non-secret env (DB type, ROOT_URL, ports, registration lockdown,
#     webhook allow-list) stays inline below — not sensitive, not worth
#     round-tripping through Vault.
#
# Not the runtime yet: docker-compose.yml is still the factory's live stack
# until cutover. This file exists so CI can validate it and S1.3 can wire
# `disinto init --backend=nomad --with forgejo` to `nomad job run` it.
# =============================================================================

job "forgejo" {
  type        = "service"
  datacenters = ["dc1"]

  group "forgejo" {
    count = 1

    # ── Vault workload identity (S2.4, issue #882) ─────────────────────────
    # `role = "service-forgejo"` is defined in vault/roles.yaml and
    # applied by tools/vault-apply-roles.sh (S2.3). The role's bound
    # claim pins nomad_job_id = "forgejo" — renaming this jobspec's
    # `job "forgejo"` without updating vault/roles.yaml will make token
    # exchange fail at placement with a "claim mismatch" error.
    vault {
      role = "service-forgejo"
    }

    # Static :3000 matches docker-compose's published port so the rest of
    # the factory (agents, woodpecker, caddy) keeps reaching forgejo at the
    # same host:port during and after cutover. `to = 3000` maps the host
    # port into the container's :3000 listener.
    network {
      port "http" {
        static = 3000
        to     = 3000
      }
    }

    # Host-volume mount: declared in nomad/client.hcl, path
    # /srv/disinto/forgejo-data on the factory box.
    volume "forgejo-data" {
      type      = "host"
      source    = "forgejo-data"
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
    # Health check gates the service as healthy only after the API is up;
    # initial_status is deliberately unset so Nomad waits for the first
    # probe to pass before marking the allocation healthy on boot.
    service {
      name     = "forgejo"
      port     = "http"
      provider = "nomad"

      check {
        type     = "http"
        path     = "/api/v1/version"
        interval = "10s"
        timeout  = "3s"
      }
    }

    task "forgejo" {
      driver = "docker"

      config {
        image = "codeberg.org/forgejo/forgejo:11.0"
        ports = ["http"]
      }

      volume_mount {
        volume      = "forgejo-data"
        destination = "/data"
        read_only   = false
      }

      # Non-secret env — DB type, public URL, ports, install lock,
      # registration lockdown, webhook allow-list. Nothing sensitive here,
      # so this stays inline. Secret-bearing env (SECRET_KEY, INTERNAL_TOKEN)
      # lives in the template stanza below and is merged into task env.
      env {
        FORGEJO__database__DB_TYPE             = "sqlite3"
        FORGEJO__server__ROOT_URL              = "http://forgejo:3000/"
        FORGEJO__server__HTTP_PORT             = "3000"
        FORGEJO__security__INSTALL_LOCK        = "true"
        FORGEJO__service__DISABLE_REGISTRATION = "true"
        FORGEJO__webhook__ALLOWED_HOST_LIST    = "private"
      }

      # ── Vault-templated secrets env (S2.4, issue #882) ──────────────────
      # Renders `<task-dir>/secrets/forgejo.env` (per-alloc secrets dir,
      # never on disk on the host root filesystem, never in `nomad job
      # inspect` output). `env = true` merges every KEY=VAL line into the
      # task environment. `change_mode = "restart"` re-runs the task
      # whenever a watched secret's value in Vault changes — so `vault kv
      # put …` alone is enough to roll new secrets; no manual
      # `nomad alloc restart` required (though that also works — it
      # forces a re-render).
      #
      # Vault path: `kv/data/disinto/shared/forgejo`. The literal `/data/`
      # segment is required by consul-template for KV v2 mounts — without
      # it the template would read from a KV v1 path that doesn't exist
      # (the policy in vault/policies/service-forgejo.hcl grants
      # `kv/data/disinto/shared/forgejo/*`, confirming v2).
      #
      # Empty-Vault fallback (`with ... else ...`): on a fresh LXC where
      # the KV path is absent, consul-template's `with` short-circuits to
      # the `else` branch. Emitting visible placeholders (instead of no
      # env vars) means the container still boots, but with obviously-bad
      # secrets that an operator will spot in `env | grep FORGEJO` —
      # better than forgejo silently regenerating SECRET_KEY on every
      # restart and invalidating every prior session. Seed the path with
      # tools/vault-seed-forgejo.sh to replace the placeholders.
      #
      # Placeholder values are kept short on purpose: the repo-wide
      # secret-scan (.woodpecker/secret-scan.yml → lib/secret-scan.sh)
      # flags `TOKEN=<16+ non-space chars>` as a plaintext secret, so a
      # descriptive long placeholder (e.g. "run-tools-vault-seed-...") on
      # the INTERNAL_TOKEN line would fail CI on every PR that touched
      # this file. "seed-me" is < 16 chars and still distinctive enough
      # to surface in a `grep FORGEJO__security__` audit. The template
      # comment below carries the operator-facing fix pointer.
      # `error_on_missing_key = false` stops consul-template from blocking
      # the alloc on template-pending when the Vault KV path exists but a
      # referenced key is absent (or the path itself is absent and the
      # else-branch placeholders are used). Without this, a fresh-LXC
      # `disinto init --with forgejo` against an empty Vault hangs on
      # template-pending until deploy.sh times out (issue #912, bug #4).
      template {
        destination          = "secrets/forgejo.env"
        env                  = true
        change_mode          = "restart"
        error_on_missing_key = false
        data                 = <<EOT
{{- with secret "kv/data/disinto/shared/forgejo" -}}
FORGEJO__security__SECRET_KEY={{ .Data.data.secret_key }}
FORGEJO__security__INTERNAL_TOKEN={{ .Data.data.internal_token }}
{{- else -}}
# WARNING: kv/disinto/shared/forgejo is empty — run tools/vault-seed-forgejo.sh
FORGEJO__security__SECRET_KEY=seed-me
FORGEJO__security__INTERNAL_TOKEN=seed-me
{{- end -}}
EOT
      }

      # Baseline — tune once we have real usage numbers under nomad. The
      # docker-compose stack runs forgejo uncapped; these limits exist so
      # an unhealthy forgejo can't starve the rest of the node.
      resources {
        cpu    = 300
        memory = 512
      }
    }
  }
}
