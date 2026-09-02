# =============================================================================
# nomad/jobs/agent-logs-rotate.hcl — agent log rotation (periodic batch job)
#
# Runs daily at 03:30 UTC (staggered from edge-threads-gc's 03:00). Rotates
# every *.log under /srv/disinto/agent-data*/ (agent-data, agent-data-qwen,
# agent-data-gardener, agent-data-opus-*, …) when it exceeds 50MB, keeping
# 5 gzip-compressed generations (<name>.1.gz … <name>.5.gz). The
# bin/agent-log-rotate.sh script does the copytruncate rotation — safe for
# writers holding the file open with O_APPEND (the agent shell scripts'
# `>>` appends): the original is truncated in place, so the inode is
# preserved and no process restart is needed.
#
# raw_exec driver (no container, no volume mounts): the task runs directly
# on the host, so the script operates on the host paths directly — same
# pattern as the snapshot-daemon raw_exec task in nomad/jobs/edge.hcl.
# =============================================================================

job "agent-logs-rotate" {
  type        = "batch"
  datacenters = ["dc1"]

  periodic {
    cron      = "30 3 * * *"
    time_zone = "UTC"
  }

  group "rotate" {
    count = 1

    restart {
      attempts = 1
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "rotate" {
      driver = "raw_exec"

      config {
        command = "/opt/disinto/bin/agent-log-rotate.sh"
      }

      env {
        AGENT_DATA_GLOB      = "/srv/disinto/agent-data*"
        LOG_MAX_SIZE_MB      = "50"
        LOG_KEEP_GENERATIONS = "5"
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }
  }
}
