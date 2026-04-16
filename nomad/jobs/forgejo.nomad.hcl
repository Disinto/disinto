# =============================================================================
# nomad/jobs/forgejo.nomad.hcl — Forgejo git server (Nomad service job)
#
# Part of the Nomad+Vault migration (S1.1, issue #840). First jobspec to
# land under nomad/jobs/ — proves the docker driver + host_volume plumbing
# from Step 0 (client.hcl) by running a real factory service.
#
# Host_volume contract:
#   This job mounts the `forgejo-data` host_volume declared in
#   nomad/client.hcl. That volume is backed by /srv/disinto/forgejo-data on
#   the factory box, created by lib/init/nomad/cluster-up.sh before any job
#   references it. Keep the `source = "forgejo-data"` below in sync with the
#   host_volume stanza in client.hcl — drift = scheduling failures.
#
# No Vault integration yet — Step 2 (#...) templates in OAuth secrets and
# replaces the inline FORGEJO__oauth2__* bits. The env vars below are the
# subset of docker-compose.yml's forgejo service that does NOT depend on
# secrets: DB type, public URL, install lock, registration lockdown, webhook
# allow-list. OAuth app registration lands later, per-service.
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

      # Mirrors the non-secret env set from docker-compose.yml's forgejo
      # service. OAuth/secret-bearing env vars land in Step 2 via Vault
      # templates — do NOT add them here.
      env {
        FORGEJO__database__DB_TYPE             = "sqlite3"
        FORGEJO__server__ROOT_URL              = "http://forgejo:3000/"
        FORGEJO__server__HTTP_PORT             = "3000"
        FORGEJO__security__INSTALL_LOCK        = "true"
        FORGEJO__service__DISABLE_REGISTRATION = "true"
        FORGEJO__webhook__ALLOWED_HOST_LIST    = "private"
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
