# =============================================================================
# nomad/client.hcl — Docker driver + host_volume declarations
#
# Part of the Nomad+Vault migration (S0.2, issue #822). Deployed to
# /etc/nomad.d/client.hcl on the factory dev box alongside server.hcl.
#
# This file owns: Docker driver plugin config + host_volume pre-wiring.
# server.hcl owns: agent role, bind, ports, data_dir.
#
# NOTE: Nomad merges every *.hcl under -config=/etc/nomad.d, so declaring
# a second `client { ... }` block here augments (not replaces) the one in
# server.hcl. On a single-node setup this file could be inlined into
# server.hcl — the split is for readability, not semantics.
#
# host_volume declarations let Nomad jobspecs mount factory state by name
# (volume = "forgejo-data", etc.) without coupling host paths into jobspec
# HCL. Host paths under /srv/disinto/* are created out-of-band by the
# orchestrator (S0.4) before any job references them.
# =============================================================================

client {
  # forgejo git server data (repos, avatars, attachments).
  host_volume "forgejo-data" {
    path      = "/srv/disinto/forgejo-data"
    read_only = false
  }

  # woodpecker CI data (pipeline artifacts, sqlite db).
  host_volume "woodpecker-data" {
    path      = "/srv/disinto/woodpecker-data"
    read_only = false
  }

  # agent runtime data (claude config, logs, phase files).
  host_volume "agent-data" {
    path      = "/srv/disinto/agent-data"
    read_only = false
  }

  # per-project git clones and worktrees.
  host_volume "project-repos" {
    path      = "/srv/disinto/project-repos"
    read_only = false
  }

  # caddy config + ACME state.
  host_volume "caddy-data" {
    path      = "/srv/disinto/caddy-data"
    read_only = false
  }

  # disinto chat transcripts + attachments.
  host_volume "chat-history" {
    path      = "/srv/disinto/chat-history"
    read_only = false
  }

  # ops repo clone (vault actions, sprint artifacts, knowledge).
  host_volume "ops-repo" {
    path      = "/srv/disinto/ops-repo"
    read_only = false
  }
}

# Docker task driver. `volumes.enabled = true` is required so jobspecs
# can mount host_volume declarations defined above. `allow_privileged`
# is true — woodpecker-agent requires `privileged = true` to access
# docker.sock and spawn CI pipeline containers.
plugin "docker" {
  config {
    allow_privileged = true

    volumes {
      enabled = true
    }

    # Leave images behind when jobs stop, so short job churn doesn't thrash
    # the image cache. Factory disk is not constrained; `docker system prune`
    # is the escape hatch.
    gc {
      image       = false
      container   = true
      dangling_containers {
        enabled = true
      }
    }
  }
}
