# =============================================================================
# nomad/jobs/healer.hcl — host-side allocation healer (Nomad service job)
#
# Runs bin/healer.sh on the host (#1951). A Nomad agent restart can drop
# service registrations; the edge then crash-loops and nothing inside a
# container can call the API (127.0.0.1:4646 only). This job is not a task
# in nomad/jobs/edge.hcl: it must keep running when the edge is the thing
# that is broken. Same raw_exec placement as the snapshot task, but its own
# job. Nomad ACLs are disabled, so no token is needed.
#
# Deployed by hand (`nomad job run`), not by lib/init/nomad/deploy.sh.
# Telegram notify secret (TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID) is rendered
# from kv/disinto/notify/telegram via role service-healer (#1954).
# error_on_missing_key = false lets the healer run, unable to notify, before
# the secret is seeded; notify_owner then logs "notify: not configured".
#
# raw_exec writes straight to the host paths in env (no host_volume mount).
# healer.sh creates HEALER_STATE_DIR itself. The script loops; this service
# job keeps that loop up.
# =============================================================================

job "healer" {
  type = "service"
  datacenters = ["dc1"]

  group "healer" {
    count = 1

    # A host-side loop. Retry a crash; do not give up after one failure.
    restart {
      attempts = 10
      interval = "30m"
      delay = "15s"
      mode = "delay"
    }

    task "healer" {
      driver = "raw_exec"

      config {
        command = "/opt/disinto/bin/healer.sh"
      }

      env {
        NOMAD_ADDR = "http://localhost:4646"
        HEALER_STATE_DIR = "/srv/disinto/healer"
        TAPE_DIR = "/srv/disinto/tape"
        FACTORY_ROOT = "/opt/disinto"
      }

      # Telegram secret for notify_owner (#1949, #1955). Missing keys render
      # empty so the healer still runs before the secret is seeded (#1954).
      vault {
        role        = "service-healer"
        change_mode = "restart"
      }
      template {
        destination          = "secrets/notify.env"
        env                  = true
        change_mode          = "restart"
        error_on_missing_key = false
        data                 = <<EOT
{{- with secret "kv/data/disinto/notify/telegram" -}}
TELEGRAM_BOT_TOKEN={{ .Data.data.bot_token }}
TELEGRAM_CHAT_ID={{ .Data.data.chat_id }}
{{- end }}
EOT
      }

      resources {
        cpu = 50
        memory = 128
      }
    }
  }
}
