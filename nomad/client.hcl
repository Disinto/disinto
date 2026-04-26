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

  # operator-managed per-env factory project TOMLs (#794).
  # Decoupled from the baked image: agents mount this read-only at
  # /srv/disinto/project-repos/_factory/projects/ (the path the entrypoint
  # already reads from) so per-env config can change without rebuilding.
  # `disinto init --backend=nomad` writes the default disinto.toml here.
  host_volume "factory-projects" {
    path      = "/srv/disinto/projects"
    read_only = false
  }

  # caddy config + ACME state.
  host_volume "caddy-data" {
    path      = "/srv/disinto/caddy-data"
    read_only = false
  }

  # staging static content (docker/ directory with images, HTML, etc.)
  host_volume "site-content" {
    path      = "/srv/disinto/docker"
    read_only = true
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

  # supervisor agent runtime data (logs, state files for Opus supervisor).
  host_volume "agent-data-opus-supervisor" {
    path      = "/srv/disinto/agent-data-opus-supervisor"
    read_only = false
  }

  # Claude OAuth credentials for the Opus supervisor agent.
  # Mounted at /home/agent/.claude inside the container.
  host_volume "claude-creds" {
    path      = "/srv/disinto/claude-creds"
    read_only = true
  }

  # factory-state snapshot output (written by snapshot-daemon, read RO by
  # consumers such as the factory-state skill). Host path is
  # /srv/disinto/snapshot-state — must match the SNAPSHOT_PATH env in
  # nomad/jobs/edge.hcl's snapshot task (raw_exec writes to host directly,
  # bypassing the volume_mount). Container consumers see this path
  # remapped to /var/lib/disinto/snapshot via volume_mount destination.
  host_volume "snapshot-state" {
    path      = "/srv/disinto/snapshot-state"
    read_only = false
  }

  # delegate thread state (meta.json + stream.jsonl per task-id). Host
  # path is /srv/disinto/threads-state; container consumers see this
  # remapped to /var/lib/disinto/threads via volume_mount destination.
  host_volume "threads-state" {
    path      = "/srv/disinto/threads-state"
    read_only = false
  }
}

# raw_exec driver for the snapshot-daemon (issue #755).
plugin "raw_exec" {
  config {
    enabled = true
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
