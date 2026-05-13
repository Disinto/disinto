# =============================================================================
# nomad/jobs/vault-runner.hcl — Parameterized batch job for vault action dispatch
#
# Part of the Nomad+Vault migration (S5.3, issue #990). Replaces the
# `docker run --rm vault-runner-${action_id}` pattern in dispatcher.sh with
# a Nomad-native parameterized batch job. Dispatched by the edge dispatcher
# (S5.4) via `nomad job dispatch`.
#
# Parameterized meta:
#   action_id   — vault action identifier (used by entrypoint-runner.sh)
#   secrets_csv — comma-separated secret names (e.g. "GITHUB_TOKEN,DEPLOY_KEY")
#
# Vault integration (approach A — pre-defined templates):
#   All 6 known runner secrets are rendered via template stanzas with
#   error_on_missing_key = false. Secrets not granted by the dispatch's
#   Vault policies render as empty strings. The dispatcher (S5.4) sets
#   vault { policies = [...] } per-dispatch based on the action TOML's
#   secrets=[...] list, scoping access to only the declared secrets.
#
# Cleanup: Nomad garbage-collects completed batch dispatches automatically.
# =============================================================================

job "vault-runner" {
  type        = "batch"
  datacenters = ["dc1"]

  parameterized {
    meta_required = ["action_id", "secrets_csv"]
  }

  group "runner" {
    count = 1

    # ── Vault workload identity ──────────────────────────────────────────────
    # Per-dispatch policies are composed by the dispatcher (S5.4) based on the
    # action TOML's secrets=[...] list. Each policy grants read access to
    # exactly one kv/data/disinto/runner/<NAME> path. Roles defined in
    # vault/roles.yaml (runner-<NAME>), policies in vault/policies/.
    vault {}

    volume "ops-repo" {
      type      = "host"
      source    = "ops-repo"
      read_only = true
    }

    # No restart for batch — fail fast, let the dispatcher handle retries.
    restart {
      attempts = 0
      mode     = "fail"
    }

    task "runner" {
      driver = "docker"

      config {
        image      = "disinto/agents:local"
        force_pull = false
        entrypoint = ["bash"]
        args       = [
          "/home/agent/disinto/docker/runner/entrypoint-runner.sh",
          "${NOMAD_META_action_id}",
        ]
      }

      volume_mount {
        volume      = "ops-repo"
        destination = "/home/agent/ops"
        read_only   = true
      }

      # ── Non-secret env ───────────────────────────────────────────────────────
      env {
        DISINTO_CONTAINER = "1"
        FACTORY_ROOT      = "/home/agent/disinto"
        OPS_REPO_ROOT     = "/home/agent/ops"
      }

      # ── Vault-templated runner secrets (approach A) ────────────────────────
      # Pre-defined templates for all 6 known runner secrets. Each renders
      # from kv/data/disinto/runner/<NAME>. Secrets not granted by the
      # dispatch's Vault policies produce empty env vars (harmless).
      # error_on_missing_key = false prevents template-pending hangs when
      # a secret path is absent or the policy doesn't grant access.
      #
      # Placeholder values kept < 16 chars to avoid secret-scan CI failures.
      template {
        destination          = "secrets/runner.env"
        env                  = true
        error_on_missing_key = false
        data                 = <<EOT
{{- with secret "kv/data/disinto/runner/GITHUB_TOKEN" -}}
GITHUB_TOKEN={{ .Data.data.value }}
{{- else -}}
GITHUB_TOKEN=
{{- end }}
{{- with secret "kv/data/disinto/runner/CODEBERG_TOKEN" -}}
CODEBERG_TOKEN={{ .Data.data.value }}
{{- else -}}
CODEBERG_TOKEN=
{{- end }}
{{- with secret "kv/data/disinto/runner/CLAWHUB_TOKEN" -}}
CLAWHUB_TOKEN={{ .Data.data.value }}
{{- else -}}
CLAWHUB_TOKEN=
{{- end }}
{{- with secret "kv/data/disinto/runner/DEPLOY_KEY" -}}
DEPLOY_KEY={{ .Data.data.value }}
{{- else -}}
DEPLOY_KEY=
{{- end }}
{{- with secret "kv/data/disinto/runner/NPM_TOKEN" -}}
NPM_TOKEN={{ .Data.data.value }}
{{- else -}}
NPM_TOKEN=
{{- end }}
{{- with secret "kv/data/disinto/runner/DOCKER_HUB_TOKEN" -}}
DOCKER_HUB_TOKEN={{ .Data.data.value }}
{{- else -}}
DOCKER_HUB_TOKEN=
{{- end }}
EOT
      }

      # Formula execution headroom — matches agents.hcl baseline.
      resources {
        cpu    = 500
        memory = 1024
      }
    }
  }
}
