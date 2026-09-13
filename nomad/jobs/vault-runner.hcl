# =============================================================================
# nomad/jobs/vault-runner.hcl — Parameterized batch job for vault action dispatch
#
# Part of the Nomad+Vault migration (S5.3, issue #990). Replaces the
# `docker run --rm vault-runner-${action_id}` pattern in dispatcher.sh with
# a Nomad-native parameterized batch job. Dispatched by the edge dispatcher
# (S5.4) via `nomad job dispatch`.
#
# Parameterized meta:
#   action_id     — vault action identifier (used by entrypoint-runner.sh)
#   secrets_csv   — comma-separated secret names (e.g. "GITHUB_TOKEN,DEPLOY_KEY")
#   image         — container image for the run; the dispatcher applies the
#                   disinto/agents:local default when the action TOML omits
#                   the optional image field (#1307)
#   artifacts_csv — comma-separated artifact globs from the action TOML
#                   (may be empty); exposed in the task as ARTIFACTS_GLOB
#                   against the writeable /artifacts volume (#1307)
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
    meta_required = ["action_id", "secrets_csv", "image", "artifacts_csv"]
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

    # Writeable artifacts volume (#1307): research runs drop outputs under
    # /artifacts. Host path via the vault-artifacts host_volume
    # (nomad/client.hcl). Collection into the ops repo is
    # run-experiment.sh's job (#1308), not the dispatcher's.
    volume "artifacts" {
      type   = "host"
      source = "vault-artifacts"
    }

    # No restart for batch — fail fast, let the dispatcher handle retries.
    restart {
      attempts = 0
      mode     = "fail"
    }

    task "runner" {
      driver = "docker"

      config {
        # Image comes from the dispatch meta — the dispatcher passes the
        # action TOML's optional image field, or its disinto/agents:local
        # default when the action omits it (#1307).
        image      = "${NOMAD_META_image}"
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

      # Writeable artifacts drop for research runs (#1307). No read_only —
      # the task must be able to write here.
      volume_mount {
        volume      = "artifacts"
        destination = "/artifacts"
      }

      # ── Non-secret env ───────────────────────────────────────────────────────
      env {
        DISINTO_CONTAINER = "1"
        FACTORY_ROOT      = "/home/agent/disinto"
        OPS_REPO_ROOT     = "/home/agent/ops"
        # Artifacts location (#1307): the writeable /artifacts volume, plus
        # the action's artifact glob(s) passed through as-is (empty when the
        # action declares none).
        ARTIFACTS_DIR  = "/artifacts"
        ARTIFACTS_GLOB = "${NOMAD_META_artifacts_csv}"
      }

      # ── Vault-templated runner secrets (approach A) ────────────────────────
      # Token secrets (6) render into env via secrets/runner.env. File secrets
      # (SSH_KEY, SSH_KNOWN_HOSTS) render as 0400 files under secrets/ssh/ —
      # PEM keys must not become environment variables. Missing paths render
      # empty (error_on_missing_key = false) so an action that didn't declare
      # them still starts; entrypoint-runner.sh no-ops on an empty key file.
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

{{ with secret "kv/data/disinto/runner/CODEBERG_TOKEN" -}}
CODEBERG_TOKEN={{ .Data.data.value }}
{{- else -}}
CODEBERG_TOKEN=
{{- end }}

{{ with secret "kv/data/disinto/runner/CLAWHUB_TOKEN" -}}
CLAWHUB_TOKEN={{ .Data.data.value }}
{{- else -}}
CLAWHUB_TOKEN=
{{- end }}

{{ with secret "kv/data/disinto/runner/DEPLOY_KEY" -}}
DEPLOY_KEY={{ .Data.data.value }}
{{- else -}}
DEPLOY_KEY=
{{- end }}

{{ with secret "kv/data/disinto/runner/NPM_TOKEN" -}}
NPM_TOKEN={{ .Data.data.value }}
{{- else -}}
NPM_TOKEN=
{{- end }}

{{ with secret "kv/data/disinto/runner/DOCKER_HUB_TOKEN" -}}
DOCKER_HUB_TOKEN={{ .Data.data.value }}
{{- else -}}
DOCKER_HUB_TOKEN=
{{- end }}
EOT
      }

      # SSH private key — file, not env. Empty when the action didn't declare
      # SSH_KEY / the policy doesn't grant it. entrypoint installs into ~/.ssh.
      template {
        destination          = "secrets/ssh/id_ed25519"
        perms                = "0400"
        error_on_missing_key = false
        data                 = <<EOT
{{- with secret "kv/data/disinto/runner/SSH_KEY" -}}
{{ .Data.data.value }}
{{- end }}
EOT
      }

      template {
        destination          = "secrets/ssh/known_hosts"
        perms                = "0444"
        error_on_missing_key = false
        data                 = <<EOT
{{- with secret "kv/data/disinto/runner/SSH_KNOWN_HOSTS" -}}
{{ .Data.data.value }}
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
