# =============================================================================
# nomad/jobs/edge-threads-gc.hcl — threads-state GC (periodic batch job)
#
# Runs daily at 03:00 UTC. Deletes completed/failed/error threads older than
# THREADS_TTL (default 7 days). The bin/threads.sh script handles the actual
# deletion logic (status check + age check).
# =============================================================================

job "edge-threads-gc" {
  type        = "batch"
  datacenters = ["dc1"]

  periodic {
    cron     = "0 3 * * *"
    time_zone = "UTC"
  }

  group "gc" {
    count = 1

    restart {
      attempts = 1
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    volume "threads-state" {
      type      = "host"
      source    = "threads-state"
      read_only = false
    }

    task "gc" {
      driver = "raw_exec"

      config {
        command = "/opt/disinto/bin/threads.sh"
        args    = ["gc"]
      }

      env {
        THREADS_ROOT  = "/var/lib/disinto/threads"
        THREADS_TTL   = "7"
        DISINTO_DATA  = "/opt/disinto"
      }

      volume_mount {
        volume      = "threads-state"
        destination = "/var/lib/disinto/threads"
        read_only   = false
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }
  }
}
