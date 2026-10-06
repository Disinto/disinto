# =============================================================================
# nomad/jobs/staging.hcl — Staging file server (Nomad service job)
#
# Part of the Nomad+Vault migration (S5.2, issue #989). Lightweight service job
# for the staging file server using Caddy as a static file server.
#
# Mount contract:
#   This job mounts the `docker/` directory as `/srv/site` (read-only).
#   The docker/ directory contains static content (images, HTML, etc.)
#   served to staging environment users.
#
# Network:
#   Dynamic host port — edge discovers via Nomad service registration.
#   No static port to avoid collisions with edge (which owns 80/443).
#
# This is the live staging job: the production factory runs the Nomad+Vault
# backend (docs/updating-factory.md), and `disinto init --backend=nomad
# --with staging` deploys this job via lib/init/nomad/deploy.sh. Change
# staging here, not in the generated docker-compose.yml.
# =============================================================================

job "staging" {
  type        = "service"
  datacenters = ["dc1"]

  group "staging" {
    count = 1

    # No Vault integration needed — no secrets required (static file server)

    # Internal service — dynamic host port. Edge discovers via Nomad service.
    network {
      port "http" {
        to = 80
      }
    }

    volume "site-content" {
      type      = "host"
      source    = "site-content"
      read_only = true
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "delay"
    }

    service {
      name     = "staging"
      port     = "http"
      provider = "nomad"

      check {
        type     = "http"
        path     = "/"
        interval = "10s"
        timeout  = "3s"
      }
    }

    task "staging" {
      driver = "docker"

      config {
        image   = "caddy:alpine"
        ports   = ["http"]
        command = "caddy"
        args    = ["file-server", "--root", "/srv/site"]
      }

      # Mount docker/ directory as /srv/site:ro (static content)
      volume_mount {
        volume      = "site-content"
        destination = "/srv/site"
        read_only   = true
      }

      resources {
        cpu    = 100
        memory = 256
      }
    }
  }
}
