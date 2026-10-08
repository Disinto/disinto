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
# No vault stanza yet; #1954 adds the Telegram secret.
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

      resources {
        cpu = 50
        memory = 128
      }
    }
  }
}
