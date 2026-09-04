job "bot-labbot" {
  type        = "service"
  datacenters = ["dc1"]

  group "bot-labbot" {
    count = 1

    vault {
      role = "bot-labbot"
    }

    volume "agent-data" {
      type      = "host"
      source    = "agent-data"
      read_only = false
    }

    volume "project-repos" {
      type      = "host"
      source    = "project-repos"
      read_only = false
    }

    volume "ops-repo" {
      type      = "host"
      source    = "ops-repo"
      read_only = true
    }

    volume "factory-projects" {
      type      = "host"
      source    = "factory-projects"
      read_only = true
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "delay"
    }

    service {
      name     = "bot-labbot"
      provider = "nomad"
    }

    task "bot-labbot" {
      driver = "docker"

      config {
        image      = "disinto/agents:local"
        force_pull = false
        security_opt = ["apparmor=unconfined"]
      }

      volume_mount {
        volume      = "agent-data"
        destination = "/home/agent/data"
        read_only   = false
      }

      volume_mount {
        volume      = "project-repos"
        destination = "/home/agent/repos"
        read_only   = false
      }

      volume_mount {
        volume      = "ops-repo"
        destination = "/home/agent/repos/_factory/disinto-ops"
        read_only   = true
      }

      volume_mount {
        volume      = "factory-projects"
        destination = "/srv/disinto/project-repos/_factory/projects"
        read_only   = true
      }

      env {
        FORGE_REPO         = "disinto-admin/disinto"
        FACTORY_REPO       = "disinto-admin/disinto"
        ANTHROPIC_BASE_URL = "http://10.0.0.1:8081"
        ANTHROPIC_API_KEY  = "sk-no-key-required"
        CLAUDE_MODEL       = "qwen"
        AGENT_ROLES        = "dev"
        POLL_INTERVAL      = "300"
        DISINTO_CONTAINER  = "1"
        PROJECT_NAME       = "lab"
        PROJECT_REPO_ROOT  = "/home/agent/repos/lab"
        CLAUDE_TIMEOUT     = "7200"
        CLAUDE_MAX_TURNS   = "60"
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1"
        CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS   = "1"
        CLAUDE_AUTOCOMPACT_PCT_OVERRIDE          = "60"
      }

      template {
        destination = "secrets/forge-url.env"
        env         = true
        change_mode = "restart"
        data        = <<EOT
{{ range nomadService "forgejo" -}}
FORGE_URL=http://{{ .Address }}:{{ .Port }}
{{- end }}
EOT
      }

      template {
        destination          = "secrets/bots.env"
        env                  = true
        # noop per #1091 stabilization: renewals must not restart the task.
        # Rotation = vault kv put + manual nomad job restart or alloc restart.
        change_mode          = "noop"
        error_on_missing_key = false
        data                 = <<EOT
{{- with secret "kv/data/disinto/bots/labbot" -}}
FORGE_TOKEN={{ .Data.data.token }}
FORGE_PASS={{ .Data.data.pass }}
{{- else -}}
# WARNING: seed kv/data/disinto/bots/labbot (re-run 'disinto hire-an-agent')
FORGE_TOKEN=seed-me
FORGE_PASS=seed-me
{{- end }}
EOT
      }

      resources {
        cpu    = 500
        memory = 1024
      }
    }
  }
}
