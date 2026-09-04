#!/usr/bin/env bash
# =============================================================================
# hire-agent — disinto_hire_an_agent() function
#
# Handles user creation, .profile repo setup, formula copying, branch protection,
# and state marker creation for hiring a new agent.
#
# Globals expected:
#   FORGE_URL    - Forge instance URL
#   FORGE_TOKEN  - Admin token for Forge operations
#   FACTORY_ROOT - Root of the disinto factory
#   PROJECT_NAME - Project name for email/domain generation
#
# Usage:
#   source "${FACTORY_ROOT}/lib/hire-agent.sh"
#   disinto_hire_an_agent <agent-name> <role> [--formula <path>] [--local-model <url>]
#     [--model <name>] [--poll-interval <seconds>] [--admin-token <pat>]
#     [--harness <claude|dsh>] [--context-window <tokens>]
#
# Authentication precedence:
#   1. --admin-token <pat>  (explicit flag)
#   2. FORGE_ADMIN_PAT env var
#   3. FORGE_ADMIN_PASS from env or .env (basic-auth flow)
# =============================================================================
set -euo pipefail

# disinto_hire_an_agent_nomad — Nomad-backend deploy for a hired
# local-model agent (called from disinto_hire_an_agent when the box runs
# the Nomad backend instead of docker-compose).
#
# Compose boxes regenerate docker-compose.yml and rely on `disinto up`;
# Nomad boxes do not consume the compose file. Instead this helper:
#   1. Seeds the bot's Vault KV path (kv/data/disinto/bots/<name>) with the
#      fresh Forge token + user password, merging into any existing data.
#   2. Ensures the ACL policy `bot-<name>` (same 3-path shape as
#      vault/policies/bot-*.hcl) and the JWT-auth role `bot-<name>`
#      (same payload shape as tools/vault-apply-roles.sh) exist.
#   3. Renders a single-role jobspec modeled on nomad/jobs/agents.hcl
#      (job/group/task `bot-<name>`, vault role `bot-<name>`, the four host
#      volume mounts, FORGE_URL from Nomad service discovery, and a
#      Vault-templated secrets/bots.env for its own KV path) and deploys it
#      via `nomad job validate` + `nomad job run -detach`.
#
# Vault is required, not optional. The rendered jobspec declares
# vault { role = "bot-<name>" }, so a task deployed without that role cannot
# exchange its workload identity for a token and crash-loops instead of
# starting with placeholders. If the role cannot be confirmed the command
# reports why and exits non-zero rather than deploying (#1073).
#
# Arguments:
#   $1 agent_name  - validated agent name (also the Nomad job ID)
#   $2 role        - agent role
#   $3 local_model - model endpoint URL
#   $4 model       - model name
#   $5 interval    - poll interval (seconds)
#   $6 project_name - project TOML basename
#   $7 agent_token - Forge PAT for the agent user (may be empty)
#   $8 user_pass   - generated password for the agent user
#   $9 harness     - agent harness: "claude" (default) or "dsh" (#1107)
#   $10 context_window - dsh context window in tokens (default 163840;
#       dsh harness only)
disinto_hire_an_agent_nomad() {
  local agent_name="$1"
  local role="$2"
  local local_model="$3"
  local model="$4"
  local interval="$5"
  local project_name="$6"
  local agent_token="$7"
  local user_pass="$8"
  local harness="${9:-claude}"
  local context_window="${10:-163840}"

  local vault_name="bot-${agent_name}"
  local kv_mount="${VAULT_KV_MOUNT:-kv}"
  local kv_api="${kv_mount}/data/disinto/bots/${agent_name}"

  echo "  Backend: Nomad — deploying job '${vault_name}'"

  # ── Vault: KV seed + policy + JWT role (degrades to warnings when
  #    Vault is unreachable) ────────────────────────────────────────────────
  local vault_ok="no"
  # The rendered jobspec declares vault { role = "bot-<name>" }. If that role
  # does not exist the task cannot exchange its workload identity for a token
  # and crash-loops, so the deploy is refused rather than attempted (#1073).
  local role_ok="no"
  local hvault_script="${FACTORY_ROOT}/lib/hvault.sh"
  if [ -f "$hvault_script" ]; then
    # shellcheck source=/dev/null
    . "$hvault_script"
    _hvault_default_env
    if hvault_token_lookup >/dev/null 2>&1; then
      vault_ok="yes"
    fi
  fi

  if [ "$vault_ok" = "yes" ]; then
    # Seed KV: merge token+pass into any existing data at the path. KV v2
    # replaces .data atomically on write, so read-modify-write (same
    # pattern as _hvault_seed_key in lib/hvault.sh).
    if [ -n "$agent_token" ] && [ -n "$user_pass" ]; then
      local raw existing_data payload
      raw="$(hvault_get_or_empty "$kv_api")" || raw=""
      existing_data="{}"
      if [ -n "$raw" ]; then
        existing_data="$(printf '%s' "$raw" | jq '.data.data // {}')" || existing_data="{}"
      fi
      payload="$(printf '%s' "$existing_data" | jq \
        --arg t "$agent_token" --arg p "$user_pass" \
        '{data: (. + {token: $t, pass: $p})}')"
      if _hvault_request POST "$kv_api" "$payload" >/dev/null; then
        echo "  Vault KV seeded: ${kv_api} (token + pass)"
      else
        echo "  Warning: failed to seed Vault KV at ${kv_api}" >&2
      fi
    else
      echo "  Warning: no agent token/password available — skipping Vault KV write" >&2
    fi

    # Ensure the ACL policy (same 3-path shape as vault/policies/bot-*.hcl).
    local policy_file
    policy_file="$(mktemp)"
    cat > "$policy_file" <<POLICY
path "kv/data/disinto/bots/${agent_name}" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/bots/${agent_name}" {
  capabilities = ["list", "read"]
}

path "kv/data/disinto/shared/forge" {
  capabilities = ["read"]
}
POLICY
    if hvault_policy_apply "$vault_name" "$policy_file" >/dev/null 2>&1; then
      echo "  Vault policy ensured: ${vault_name}"
    else
      echo "  Warning: failed to apply Vault policy ${vault_name}" >&2
    fi
    rm -f "$policy_file"

    # Ensure the JWT-auth role (same payload shape as
    # tools/vault-apply-roles.sh: bound to this job's nomad_job_id claim).
    local role_payload
    role_payload="$(jq -n --arg job "${vault_name}" --arg policy "$vault_name" '{
      role_type: "jwt",
      bound_audiences: ["vault.io"],
      user_claim: "nomad_job_id",
      bound_claims: { nomad_namespace: "default", nomad_job_id: $job },
      token_type: "service",
      token_policies: [$policy],
      token_ttl: "1h",
      token_max_ttl: "24h"
    }')"
    local role_current
    role_current="$(hvault_get_or_empty "auth/jwt-nomad/role/${vault_name}")" || role_current=""
    if [ -n "$role_current" ]; then
      echo "  Vault role exists: ${vault_name}"
      role_ok="yes"
    elif _hvault_request POST "auth/jwt-nomad/role/${vault_name}" "$role_payload" >/dev/null 2>&1; then
      echo "  Vault role created: ${vault_name}"
      role_ok="yes"
    else
      echo "  Warning: failed to create Vault role ${vault_name}" >&2
    fi
  else
    echo "  Warning: Vault unreachable — skipping KV seed + policy/role setup" >&2
  fi

  if [ "$role_ok" != "yes" ]; then
    echo "" >&2
    echo "  Error: Vault role '${vault_name}' is not in place — refusing to deploy." >&2
    echo "  The jobspec declares vault { role = \"${vault_name}\" }. Without that role" >&2
    echo "  the task cannot exchange its workload identity for a token, so it would" >&2
    echo "  crash-loop rather than start with placeholder secrets." >&2
    echo "  Bring Vault up, then re-run: disinto hire-an-agent ${agent_name} ${role}" >&2
    exit 1
  fi

  # ── Render + deploy the Nomad jobspec (modeled on nomad/jobs/agents.hcl) ──
  #
  # Derive the same values the compose backend derives (lib/generators.sh), so
  # a Nomad-backend agent is configured identically to a compose one and the
  # command works for a repository other than the disinto factory itself.
  local forge_repo factory_repo claude_timeout claude_max_turns compact_pct
  forge_repo="${FORGE_REPO:-disinto-admin/disinto}"
  factory_repo="${FACTORY_REPO:-$forge_repo}"
  claude_timeout="${CLAUDE_TIMEOUT:-7200}"
  claude_max_turns="${CLAUDE_MAX_TURNS:-60}"
  compact_pct="${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-60}"

  # The env block is the only part of the jobspec that depends on the
  # harness (#1107). Claude is the default and must render exactly the
  # historical block; dsh emits its own settings-form variables and no
  # CLAUDE_* tuning variables.
  local env_block_file
  env_block_file="$(mktemp)"
  if [ "$harness" = "dsh" ]; then
    cat > "$env_block_file" <<ENV
        FORGE_REPO          = "${forge_repo}"
        FACTORY_REPO        = "${factory_repo}"
        AGENT_HARNESS       = "dsh"
        DSH_HOME            = "/home/agent/data/dsh"
        DSH_PERMISSION_MODE = "danger-full-access"
        DSH_MODEL           = "${model}"
        DSH_BASE_URL        = "${local_model}"
        DSH_CONTEXT_WINDOW  = "${context_window}"
        # settings.yaml uses apiKeyEnv indirection; llama-server ignores
        # the key but dsh requires the env to be set (#1234).
        LLAMACPP_API_KEY    = "sk-no-key-required"
        AGENT_ROLES         = "${role}"
        POLL_INTERVAL       = "${interval}"
        DISINTO_CONTAINER   = "1"
        PROJECT_NAME        = "${project_name}"
        PROJECT_REPO_ROOT   = "/home/agent/repos/${project_name}"
ENV
  else
    cat > "$env_block_file" <<ENV
        FORGE_REPO         = "${forge_repo}"
        FACTORY_REPO       = "${factory_repo}"
        ANTHROPIC_BASE_URL = "${local_model}"
        ANTHROPIC_API_KEY  = "sk-no-key-required"
        CLAUDE_MODEL       = "${model}"
        AGENT_ROLES        = "${role}"
        POLL_INTERVAL      = "${interval}"
        DISINTO_CONTAINER  = "1"
        PROJECT_NAME       = "${project_name}"
        PROJECT_REPO_ROOT  = "/home/agent/repos/${project_name}"
        CLAUDE_TIMEOUT     = "${claude_timeout}"
        CLAUDE_MAX_TURNS   = "${claude_max_turns}"
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1"
        CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS   = "1"
        CLAUDE_AUTOCOMPACT_PCT_OVERRIDE          = "${compact_pct}"
ENV
  fi

  local jobspec_file
  jobspec_file="$(mktemp)"
  cat > "$jobspec_file" <<JOB
job "bot-${agent_name}" {
  type        = "service"
  datacenters = ["dc1"]

  group "bot-${agent_name}" {
    count = 1

    vault {
      role = "${vault_name}"
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
      name     = "bot-${agent_name}"
      provider = "nomad"
    }

    task "bot-${agent_name}" {
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
$(cat "$env_block_file")
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
{{- with secret "kv/data/disinto/bots/${agent_name}" -}}
FORGE_TOKEN={{ .Data.data.token }}
FORGE_PASS={{ .Data.data.pass }}
{{- else -}}
# WARNING: seed ${kv_api} (re-run 'disinto hire-an-agent')
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
JOB

  local validate_out
  if ! validate_out="$(nomad job validate "$jobspec_file" 2>&1)"; then
    echo "  Error: nomad job validate failed for ${vault_name}:" >&2
    printf '%s\n' "$validate_out" | sed 's/^/    /' >&2
    rm -f "$jobspec_file" "$env_block_file"
    exit 1
  fi

  echo "  Deploying Nomad job: ${vault_name}"
  if ! nomad job run -detach "$jobspec_file"; then
    echo "  Error: nomad job run failed for ${vault_name}" >&2
    rm -f "$jobspec_file" "$env_block_file"
    exit 1
  fi
  rm -f "$jobspec_file" "$env_block_file"

  echo ""
  echo "  Nomad job:  ${vault_name} (submitted)"
  echo "  Model endpoint: ${local_model}"
  echo "  Model: ${model}"
  echo ""
  echo "  The job is registered. \`nomad job run -detach\` returns before the"
  echo "  allocation is healthy, so confirm it started:"
  echo "    nomad job status ${vault_name}"
}

disinto_hire_an_agent() {
  local agent_name="${1:-}"
  local role="${2:-}"
  local formula_path=""
  local local_model=""
  local model_name=""
  local poll_interval=""
  local admin_pat=""
  local harness="claude"
  local context_window="163840"

  if [ -z "$agent_name" ] || [ -z "$role" ]; then
    echo "Error: agent-name and role required" >&2
    echo "Usage: disinto hire-an-agent <agent-name> <role> [--formula <path>] [--local-model <url>] [--model <name>] [--poll-interval <seconds>] [--admin-token <pat>] [--harness <claude|dsh>] [--context-window <tokens>]" >&2
    exit 1
  fi

  # Validate agent name before any side effects (Forgejo user creation, TOML
  # write, token issuance). The name flows through several systems that have
  # stricter rules than the raw TOML spec:
  #   - load-project.sh emits shell vars keyed by the name (dashes are mapped
  #     to underscores via tr 'a-z-' 'A-Z_')
  #   - generators.sh emits a docker-compose service name `agents-<name>` and
  #     uppercases it for env var keys (#852 tracks the `^^` bug; we keep the
  #     grammar tight here so that fix can happen without re-validation)
  #   - Forgejo usernames are lowercase alnum + dash
  # Constraint: start with a lowercase letter, contain only [a-z0-9-], end
  # with a lowercase letter or digit (no trailing dash), no consecutive
  # dashes. Rejecting at hire-time prevents unparseable TOML sections like
  # [agents.dev-qwen2] from landing on disk and crashing load-project.sh on
  # the next `disinto up` (#862).
  if ! [[ "$agent_name" =~ ^[a-z]([a-z0-9]|-[a-z0-9])*$ ]]; then
    echo "Error: invalid agent name '${agent_name}'" >&2
    echo "  Agent names must match: ^[a-z]([a-z0-9]|-[a-z0-9])*$" >&2
    echo "  (lowercase letters/digits/single dashes, starts with letter, ends with alphanumeric)" >&2
    echo "  Examples: dev, dev-qwen2, review-qwen, planner" >&2
    exit 1
  fi

  shift 2

  # Parse flags
  while [ $# -gt 0 ]; do
    case "$1" in
      --formula)
        formula_path="$2"
        shift 2
        ;;
      --local-model)
        local_model="$2"
        shift 2
        ;;
      --model)
        model_name="$2"
        shift 2
        ;;
      --poll-interval)
        poll_interval="$2"
        shift 2
        ;;
      --admin-token)
        admin_pat="$2"
        shift 2
        ;;
      --harness)
        harness="$2"
        shift 2
        ;;
      --context-window)
        context_window="$2"
        shift 2
        ;;
      *)
        echo "Unknown option: $1" >&2
        exit 1
        ;;
    esac
  done

  # Validate --harness and --context-window before any side effects (#1107).
  case "$harness" in
    claude|dsh) ;;
    *)
      echo "Error: invalid --harness value '$harness'" >&2
      echo "  The harness must be 'claude' (default) or 'dsh'." >&2
      exit 1
      ;;
  esac
  if ! [[ "$context_window" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: --context-window must be a positive integer of tokens (got '$context_window')" >&2
    exit 1
  fi
  if [ -z "$formula_path" ]; then
    formula_path="${FACTORY_ROOT}/formulas/${role}.toml"
    if [ ! -f "$formula_path" ]; then
      formula_path="${FACTORY_ROOT}/formulas/run-${role}.toml"
    fi
  fi

  # Validate formula exists
  if [ ! -f "$formula_path" ]; then
    echo "Error: formula not found at ${formula_path}" >&2
    exit 1
  fi

  echo "── Hiring agent: ${agent_name} (${role}) ───────────────────────"
  echo "Formula:   ${formula_path}"
  if [ -n "$local_model" ]; then
    echo "Local model: ${local_model}"
    echo "Model name:  ${model_name:-local-model}"
    echo "Poll interval: ${poll_interval:-60}s"
    echo "Harness:     ${harness}"
    if [ "$harness" = "dsh" ]; then
      echo "Context window: ${context_window} tokens"
    fi
  fi

  # Ensure FORGE_TOKEN is set
  if [ -z "${FORGE_TOKEN:-}" ]; then
    echo "Error: FORGE_TOKEN not set" >&2
    exit 1
  fi

  # Get Forge URL
  local forge_url="${FORGE_URL:-http://localhost:3000}"
  echo "Forge:     ${forge_url}"

  # Step 1: Create user via API (skip if exists)
  echo ""
  echo "Step 1: Creating user '${agent_name}' (if not exists)..."

  local user_pass=""
  local admin_pass=""
  local admin_user="disinto-admin"
  local admin_token=""
  local use_pat=0

  # ── Resolve admin credentials (precedence: flag > env var > password) ──

  # 1. Explicit --admin-token flag
  if [ -n "$admin_pat" ]; then
    admin_token="$admin_pat"
    use_pat=1
    echo "Auth: PAT from --admin-token flag"
  # 2. FORGE_ADMIN_PAT env var
  elif [ -n "${FORGE_ADMIN_PAT:-}" ]; then
    admin_token="${FORGE_ADMIN_PAT}"
    use_pat=1
    echo "Auth: PAT from FORGE_ADMIN_PAT env var"
  else
    # 3. Existing basic-auth flow (FORGE_ADMIN_PASS from env or .env)
    local env_file="${FACTORY_ROOT}/.env"
    if [ -f "$env_file" ] && grep -q '^FORGE_ADMIN_PASS=' "$env_file" 2>/dev/null; then
      admin_pass=$(grep '^FORGE_ADMIN_PASS=' "$env_file" | head -1 | cut -d= -f2-)
    fi
    admin_pass="${admin_pass:-admin}"
    local admin_token_name
    admin_token_name="temp-token-$(date +%s)"
    admin_token=$(curl -sf -X POST \
      -u "${admin_user}:${admin_pass}" \
      -H "Content-Type: application/json" \
      "${forge_url}/api/v1/users/${admin_user}/tokens" \
      -d "{\"name\":\"${admin_token_name}\",\"scopes\":[\"all\"]}" 2>/dev/null \
      | jq -r '.sha1 // empty') || admin_token=""
    if [ -z "$admin_token" ]; then
      # Token might already exist — try listing
      admin_token=$(curl -sf \
        -u "${admin_user}:${admin_pass}" \
        "${forge_url}/api/v1/users/${admin_user}/tokens" 2>/dev/null \
        | jq -r '.[0].sha1 // empty') || admin_token=""
    fi
  fi

  if [ -z "$admin_token" ]; then
    echo "Error: failed to obtain admin API token" >&2
    echo "  Cannot proceed without admin privileges" >&2
    exit 1
  fi

  # ── Validate PAT scope (skip for basic-auth flow) ──
  if [ "$use_pat" -eq 1 ]; then
    local scope_code
    scope_code=$(curl -sf --max-time 10 -o /dev/null -w '%{http_code}' \
      -H "Authorization: token ${admin_token}" \
      "${forge_url}/api/v1/admin/users?limit=1" 2>/dev/null) || scope_code="000"
    if [ "$scope_code" != "200" ]; then
      echo "Error: --admin-token lacks admin scope (HTTP ${scope_code})" >&2
      echo "  Ensure the PAT has admin/all scopes and try again." >&2
      exit 1
    fi
    echo "Auth: admin scope verified"
  fi

  # ── Helper: build admin auth args (PAT or basic) ──
  _admin_auth_args() {
    if [ "$use_pat" -eq 1 ]; then
      echo "-H \"Authorization: token ${admin_token}\""
    else
      echo "-u \"${admin_user}:${admin_pass}\""
    fi
  }

  if curl -sf --max-time 5 "${forge_url}/api/v1/users/${agent_name}" >/dev/null 2>&1; then
    echo "  User '${agent_name}' already exists"
    # Reset user password so we can get a token (#184)
    user_pass="agent-$(head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 20)"
    # Use Forgejo CLI to reset password (API PATCH ignores must_change_password in Forgejo 11.x)
    if _forgejo_exec forgejo admin user change-password \
      --username "${agent_name}" \
      --password "${user_pass}" \
      --must-change-password=false >/dev/null 2>&1; then
      echo "  Reset password for existing user '${agent_name}'"
    else
      echo "  Warning: could not reset password for existing user" >&2
    fi
  else
    # Create user via admin API
    user_pass="agent-$(head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 20)"
    local auth_args
    auth_args=$(_admin_auth_args)
    # shellcheck disable=SC2086 # auth_args intentionally unquoted for arg splitting
    if curl -sf -X POST \
      ${auth_args} \
      -H "Content-Type: application/json" \
      "${forge_url}/api/v1/admin/users" \
      -d "{\"username\":\"${agent_name}\",\"password\":\"${user_pass}\",\"email\":\"${agent_name}@${PROJECT_NAME:-disinto}.local\",\"full_name\":\"${agent_name}\",\"active\":true,\"admin\":false,\"must_change_password\":false}" >/dev/null 2>&1; then
      echo "  Created user '${agent_name}'"
    else
      echo "  Warning: failed to create user via admin API" >&2
      # Try alternative: user might already exist
      if curl -sf --max-time 5 "${forge_url}/api/v1/users/${agent_name}" >/dev/null 2>&1; then
        echo "  User '${agent_name}' exists (confirmed)"
      else
        echo "  Error: failed to create user '${agent_name}'" >&2
        exit 1
      fi
    fi
  fi

  # Step 1.5: Generate Forge token for the new/existing user
  echo ""
  echo "Step 1.5: Generating Forge token for '${agent_name}'..."

  # Key per-agent credentials by *agent name*, not role (#834 Gap 1).
  # Two agents with the same role (e.g. two `dev` agents) must not collide on
  # FORGE_<ROLE>_TOKEN — the compose generator looks up FORGE_TOKEN_<USER_UPPER>
  # where USER_UPPER = tr 'a-z-' 'A-Z_' of the agent's forge_user.
  local agent_upper
  agent_upper=$(echo "$agent_name" | tr 'a-z-' 'A-Z_')
  local token_var="FORGE_TOKEN_${agent_upper}"
  local pass_var="FORGE_PASS_${agent_upper}"

  # Generate token using the user's password (basic auth)
  local agent_token=""
  agent_token=$(curl -sf -X POST \
    -u "${agent_name}:${user_pass}" \
    -H "Content-Type: application/json" \
    "${forge_url}/api/v1/users/${agent_name}/tokens" \
    -d "{\"name\":\"disinto-${agent_name}-token\",\"scopes\":[\"all\"]}" 2>/dev/null \
    | jq -r '.sha1 // empty') || agent_token=""

  if [ -z "$agent_token" ]; then
    # Token name collision — create with timestamp suffix
    agent_token=$(curl -sf -X POST \
      -u "${agent_name}:${user_pass}" \
      -H "Content-Type: application/json" \
      "${forge_url}/api/v1/users/${agent_name}/tokens" \
      -d "{\"name\":\"disinto-${agent_name}-$(date +%s)\",\"scopes\":[\"all\"]}" 2>/dev/null \
      | jq -r '.sha1 // empty') || agent_token=""
  fi

  if [ -z "$agent_token" ]; then
    echo "  Warning: failed to create API token for '${agent_name}'" >&2
  else
    # Store token in .env under the per-agent variable name
    if grep -q "^${token_var}=" "$env_file" 2>/dev/null; then
      # Use sed with alternative delimiter and proper escaping for special chars in token
      local escaped_token
      escaped_token=$(printf '%s\n' "$agent_token" | sed 's/[&/\]/\\&/g')
      sed -i "s|^${token_var}=.*|${token_var}=${escaped_token}|" "$env_file"
      echo "  ${agent_name} token updated (${token_var})"
    else
      printf '%s=%s\n' "$token_var" "$agent_token" >> "$env_file"
      echo "  ${agent_name} token saved (${token_var})"
    fi
    export "${token_var}=${agent_token}"
  fi

  # Persist FORGE_PASS_<AGENT_UPPER> to .env (#834 Gap 2).
  # The container's git credential helper (docker/agents/entrypoint.sh) needs
  # both FORGE_TOKEN_* and FORGE_PASS_* to pass HTTPS auth for git push
  # (Forgejo 11.x rejects API tokens for git push, #361).
  if [ -n "${user_pass:-}" ]; then
    local escaped_pass
    escaped_pass=$(printf '%s\n' "$user_pass" | sed 's/[&/\]/\\&/g')
    if grep -q "^${pass_var}=" "$env_file" 2>/dev/null; then
      sed -i "s|^${pass_var}=.*|${pass_var}=${escaped_pass}|" "$env_file"
      echo "  ${agent_name} password updated (${pass_var})"
    else
      printf '%s=%s\n' "$pass_var" "$user_pass" >> "$env_file"
      echo "  ${agent_name} password saved (${pass_var})"
    fi
    export "${pass_var}=${user_pass}"
  fi

  # Step 1.7: Write backend credentials to .env (#847).
  # Local-model agents need ANTHROPIC_BASE_URL; Anthropic-backend agents need ANTHROPIC_API_KEY.
  # These must be persisted so the container can start with valid credentials.
  echo ""
  echo "Step 1.7: Writing backend credentials to .env..."

  if [ -n "$local_model" ]; then
    # Local model agent: write ANTHROPIC_BASE_URL
    local backend_var="ANTHROPIC_BASE_URL"
    local backend_val="$local_model"
    local escaped_val
    escaped_val=$(printf '%s\n' "$backend_val" | sed 's/[&/\]/\\&/g')
    if grep -q "^${backend_var}=" "$env_file" 2>/dev/null; then
      sed -i "s|^${backend_var}=.*|${backend_var}=${escaped_val}|" "$env_file"
      echo "  ${backend_var} updated"
    else
      printf '%s=%s\n' "$backend_var" "$backend_val" >> "$env_file"
      echo "  ${backend_var} saved"
    fi
    export "${backend_var}=${backend_val}"
  else
    # Anthropic backend: check if ANTHROPIC_API_KEY is set, write it if present
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
      local backend_var="ANTHROPIC_API_KEY"
      local backend_val="$ANTHROPIC_API_KEY"
      local escaped_key
      escaped_key=$(printf '%s\n' "$backend_val" | sed 's/[&/\]/\\&/g')
      if grep -q "^${backend_var}=" "$env_file" 2>/dev/null; then
        sed -i "s|^${backend_var}=.*|${backend_var}=${escaped_key}|" "$env_file"
        echo "  ${backend_var} updated"
      else
        printf '%s=%s\n' "$backend_var" "$backend_val" >> "$env_file"
        echo "  ${backend_var} saved"
      fi
      export "${backend_var}=${backend_val}"
    else
      echo "  Note: ANTHROPIC_API_KEY not set — required for Anthropic backend agents"
    fi
  fi

  # Step 1.6: Add the new agent as a write collaborator on the project repo (#856).
  # Without this, PATCH /issues/{n} {assignees:[agent]} returns 403 Forbidden and
  # the dev-agent polls forever logging "claim lost to <none> — skipping" (see
  # issue_claim()'s post-PATCH verify).  Mirrors the collaborator setup applied
  # to the canonical bot users in lib/forge-setup.sh.  Idempotent: Forgejo's PUT
  # returns 204 whether the user is being added for the first time or already a
  # collaborator at the same permission.
  if [ -n "${FORGE_REPO:-}" ]; then
    echo ""
    echo "Step 1.6: Adding '${agent_name}' as write collaborator on '${FORGE_REPO}'..."
    local collab_code
    collab_code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
      -H "Authorization: token ${admin_token}" \
      -H "Content-Type: application/json" \
      "${forge_url}/api/v1/repos/${FORGE_REPO}/collaborators/${agent_name}" \
      -d '{"permission":"write"}')
    case "$collab_code" in
      204|201|200)
        echo "  ${agent_name} is a write collaborator on ${FORGE_REPO} (HTTP ${collab_code})"
        ;;
      *)
        echo "  Warning: failed to add '${agent_name}' as collaborator on '${FORGE_REPO}' (HTTP ${collab_code})" >&2
        echo "  The agent will not be able to claim issues until this is fixed." >&2
        ;;
    esac
  else
    echo ""
    echo "Step 1.6: FORGE_REPO not set — skipping collaborator step" >&2
    echo "  Warning: the agent will not be able to claim issues on the project repo" >&2
  fi

  # Step 2: Create .profile repo on Forgejo
  echo ""
  echo "Step 2: Creating '${agent_name}/.profile' repo (if not exists)..."

  if curl -sf --max-time 5 "${forge_url}/api/v1/repos/${agent_name}/.profile" >/dev/null 2>&1; then
    echo "  Repo '${agent_name}/.profile' already exists"
  else
    # Create the repo using the admin API to ensure it's created in the agent's namespace.
    # Using POST /api/v1/user/repos with a user token would create the repo under the
    # authenticated user, which could be wrong if the token belongs to a different user.
    # The admin API POST /api/v1/admin/users/{username}/repos explicitly creates in the
    # specified user's namespace.
    local create_output
    local repo_auth_args
    repo_auth_args=$(_admin_auth_args)
    # shellcheck disable=SC2086 # auth_args intentionally unquoted for arg splitting
    create_output=$(curl -sf -X POST \
      ${repo_auth_args} \
      -H "Content-Type: application/json" \
      "${forge_url}/api/v1/admin/users/${agent_name}/repos" \
      -d "{\"name\":\".profile\",\"description\":\"${agent_name}'s .profile repo\",\"private\":true,\"auto_init\":false}" 2>&1) || true

    if echo "$create_output" | grep -q '"id":\|[0-9]'; then
      echo "  Created repo '${agent_name}/.profile' (via admin API)"
    else
      echo "  Error: failed to create repo '${agent_name}/.profile'" >&2
      echo "  Response: ${create_output}" >&2
      exit 1
    fi
  fi

  # Step 3: Clone repo and create initial commit
  echo ""
  echo "Step 3: Cloning repo and creating initial commit..."

  local clone_dir="/tmp/.profile-clone-${agent_name}"
  rm -rf "$clone_dir"
  mkdir -p "$clone_dir"

  # Build authenticated clone URL using basic auth (user_pass is always set in Step 1)
  if [ -z "${user_pass:-}" ]; then
    echo "  Error: no user password available for cloning" >&2
    exit 1
  fi

  local auth_url
  auth_url=$(printf '%s' "$forge_url" | sed "s|://|://${agent_name}:${user_pass}@|")
  auth_url="${auth_url}/${agent_name}/.profile.git"

  # Display unauthenticated URL (auth token only in actual git clone command)
  echo "  Cloning: ${forge_url}/${agent_name}/.profile.git"

  # Try authenticated clone first (required for private repos)
  if ! git clone --quiet "$auth_url" "$clone_dir" 2>/dev/null; then
    echo "  Error: failed to clone repo with authentication" >&2
    echo "  Note: Ensure the user has a valid API token with repository access" >&2
    rm -rf "$clone_dir"
    exit 1
  fi

  # Configure git
  git -C "$clone_dir" config user.name "disinto-admin"
  git -C "$clone_dir" config user.email "disinto-admin@localhost"

  # Create directory structure
  echo "  Creating directory structure..."
  mkdir -p "${clone_dir}/journal"
  mkdir -p "${clone_dir}/knowledge"
  touch "${clone_dir}/journal/.gitkeep"
  touch "${clone_dir}/knowledge/.gitkeep"

  # Copy formula
  echo "  Copying formula..."
  cp "$formula_path" "${clone_dir}/formula.toml"

  # Create README
  if [ ! -f "${clone_dir}/README.md" ]; then
    cat > "${clone_dir}/README.md" <<EOF
# ${agent_name}'s .profile

Agent profile repository for ${agent_name}.

## Structure

\`\`\`
${agent_name}/.profile/
├── formula.toml    # Agent's role formula
├── journal/        # Issue-by-issue log files (journal branch)
│   └── .gitkeep
├── knowledge/      # Shared knowledge and best practices
│   └── .gitkeep
└── README.md
\`\`\`

## Branches

- \`main\` — Admin-only merge for formula changes (requires 1 approval)
- \`journal\` — Agent branch for direct journal entries
  - Agent can push directly to this branch
  - Formula changes must go through PR to \`main\`

## Branch protection

- \`main\`: Protected — requires 1 admin approval for merges
- \`journal\`: Unprotected — agent can push directly
EOF
  fi

  # Commit and push
  echo "  Committing and pushing..."
  git -C "$clone_dir" add -A
  if ! git -C "$clone_dir" diff --cached --quiet 2>/dev/null; then
    git -C "$clone_dir" commit -m "chore: initial .profile setup" -q
    git -C "$clone_dir" push origin main >/dev/null 2>&1 || \
      git -C "$clone_dir" push origin master >/dev/null 2>&1 || true
    echo "  Committed: initial .profile setup"
  else
    echo "  No changes to commit"
  fi

  rm -rf "$clone_dir"

  # Step 4: Set up branch protection
  echo ""
  echo "Step 4: Setting up branch protection..."

  # Source branch-protection.sh helper
  local bp_script="${FACTORY_ROOT}/lib/branch-protection.sh"
  if [ -f "$bp_script" ]; then
    # Source required environment
    if [ -f "${FACTORY_ROOT}/lib/env.sh" ]; then
      source "${FACTORY_ROOT}/lib/env.sh"
    fi

    # Set up branch protection for .profile repo
    if source "$bp_script" 2>/dev/null && setup_profile_branch_protection "${agent_name}/.profile" "main"; then
      echo "  Branch protection configured for main branch"
      echo "  - Requires 1 approval before merge"
      echo "  - Admin-only merge enforcement"
      echo "  - Journal branch created for direct agent pushes"
    else
      echo "  Warning: could not configure branch protection (Forgejo API may not be available)"
      echo "  Note: Branch protection can be set up manually later"
    fi
  else
    echo "  Warning: branch-protection.sh not found at ${bp_script}"
  fi

  # Step 5: Create state marker
  echo ""
  echo "Step 5: Creating state marker..."

  local state_dir="${FACTORY_ROOT}/state"
  mkdir -p "$state_dir"
  local state_file="${state_dir}/.${role}-active"

  if [ ! -f "$state_file" ]; then
    touch "$state_file"
    echo "  Created: ${state_file}"
  else
    echo "  State marker already exists: ${state_file}"
  fi

  # Step 6: Set up local model agent (if --local-model specified)
  if [ -n "$local_model" ]; then
    echo ""
    echo "Step 6: Configuring local model agent..."

    # Validate model endpoint is reachable
    echo "  Validating model endpoint: ${local_model}"
    if ! curl -sf --max-time 10 "${local_model}/health" >/dev/null 2>&1; then
      # Try /v1/chat/completions as fallback endpoint check
      if ! curl -sf --max-time 10 "${local_model}/v1/chat/completions" >/dev/null 2>&1; then
        echo "  Warning: model endpoint may not be reachable at ${local_model}"
        echo "  Continuing with configuration..."
      fi
    else
      echo "  Model endpoint is reachable"
    fi

    # Pick the projects directory per backend.
    # Compose boxes read the project TOMLs from ${FACTORY_ROOT}/projects/ (baked
    # at image build time). Nomad boxes mount the live per-env TOMLs from
    # /srv/disinto/projects/ (overridable via FACTORY_PROJECTS_DIR) into every
    # agent job (#794) — writing the section into the baked directory there
    # has no effect. A box counts as Nomad when the `nomad` CLI is present
    # AND the live projects directory exists (cluster-up.sh creates it).
    local backend projects_dir
    if command -v nomad >/dev/null 2>&1 \
       && [ -d "${FACTORY_PROJECTS_DIR:-/srv/disinto/projects}" ]; then
      backend="nomad"
      projects_dir="${FACTORY_PROJECTS_DIR:-/srv/disinto/projects}"
    else
      backend="compose"
      projects_dir="${FACTORY_ROOT}/projects"
    fi

    local project_name="${PROJECT_NAME:-}"
    local toml_file=""
    if [ -n "$project_name" ]; then
      toml_file="${projects_dir}/${project_name}.toml"
    fi
    # Fallback: find the first .toml in the projects dir
    if [ -z "$toml_file" ] || [ ! -f "$toml_file" ]; then
      for f in "${projects_dir}"/*.toml; do
        if [ -f "$f" ]; then
          toml_file="$f"
          break
        fi
      done
    fi

    if [ -z "$toml_file" ] || [ ! -f "$toml_file" ]; then
      echo "  Error: no project TOML found in ${projects_dir}/" >&2
      if [ "$backend" = "nomad" ]; then
        echo "  The live projects dir is empty — seed a project TOML first," >&2
        echo "  e.g.: sudo cp ${FACTORY_ROOT}/projects/*.toml ${projects_dir}/" >&2
      else
        echo "  Run 'disinto init' first to create a project config" >&2
      fi
      exit 1
    fi

    echo "  Project TOML: ${toml_file}"
    if [ -z "$project_name" ]; then
      project_name="$(basename "${toml_file%.toml}")"
    fi

    # Derive a safe section name from the agent name (lowercase, alphanumeric+hyphens)
    local section_name
    section_name=$(echo "$agent_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')

    # Default model name if not provided
    local model="${model_name:-local-model}"

    # Write [agents.<name>] section to the project TOML
    local interval="${poll_interval:-60}"
    echo "  Writing [agents.${section_name}] to ${toml_file}..."
    python3 -c '
import sys
import tomlkit
import re
import pathlib

toml_path = sys.argv[1]
section_name = sys.argv[2]
base_url = sys.argv[3]
model = sys.argv[4]
agent_name = sys.argv[5]
role = sys.argv[6]
poll_interval = sys.argv[7]
harness = sys.argv[8]
context_window = sys.argv[9]

p = pathlib.Path(toml_path)
text = p.read_text()

# Step 1: Remove any commented-out [agents.X] blocks (they cause parse issues)
# Match # [agents.section_name] followed by lines that are not section headers
# Use negative lookahead to stop before a real section header (# [ or [)
commented_pattern = rf"(?:^|\n)# \[agents\.{re.escape(section_name)}\](?:\n(?!# \[|\[)[^\n]*)*"
text = re.sub(commented_pattern, "", text, flags=re.DOTALL)

# Step 2: Parse TOML with tomlkit (preserves comments and formatting)
try:
    doc = tomlkit.parse(text)
except Exception as e:
    print(f"Error: Invalid TOML in {toml_path}: {e}", file=sys.stderr)
    sys.exit(1)

# Step 3: Ensure agents table exists
if "agents" not in doc:
    doc.add("agents", tomlkit.table())

# Step 4: Update the specific agent section. The harness and context_window
# keys are only written for non-default (dsh) harnesses, so a default hire
# leaves the TOML byte-identical to the pre-#1107 shape.
agent_section = {
    "base_url": base_url,
    "model": model,
    "api_key": "sk-no-key-required",
    "roles": [role],
    "forge_user": agent_name,
    "compact_pct": 60,
    "poll_interval": int(poll_interval),
}
if harness != "claude":
    agent_section["harness"] = harness
    agent_section["context_window"] = int(context_window)
doc["agents"][section_name] = agent_section

# Step 5: Serialize back to TOML (preserves comments)
output = tomlkit.dumps(doc)

# Step 6: Write back
p.write_text(output)
' "$toml_file" "$section_name" "$local_model" "$model" "$agent_name" "$role" "$interval" "$harness" "$context_window"

    echo "  Agent config written to TOML"

    # Compose boxes: regenerate docker-compose.yml to include the new agent
    # container. Nomad boxes: deploy a per-agent Nomad job instead (the
    # compose file is not consumed by the Nomad backend).
    if [ "$backend" = "compose" ]; then
      local compose_file="${FACTORY_ROOT}/docker-compose.yml"
      if [ -f "$compose_file" ]; then
        echo "  Regenerating docker-compose.yml..."
        rm -f "$compose_file"
        # generate_compose is defined in the calling script (bin/disinto) via generators.sh
        # Use _generate_compose_impl directly since generators.sh is already sourced
        local forge_port="3000"
        if [ -n "${FORGE_URL:-}" ]; then
          forge_port=$(printf '%s' "$FORGE_URL" | sed -E 's|.*:([0-9]+)/?$|\1|')
          forge_port="${forge_port:-3000}"
        fi
        _generate_compose_impl "$forge_port"
        echo "  Compose regenerated with agents-${section_name} service"
      fi

      local service_name="agents-${section_name}"
      echo ""
      echo "  Service name: ${service_name}"
      echo "  Model endpoint: ${local_model}"
      echo "  Model: ${model}"
      echo ""
      echo "  To start the agent, run:"
      echo "    disinto up"
    else
      disinto_hire_an_agent_nomad \
        "$agent_name" "$role" "$local_model" "$model" \
        "$interval" "$project_name" "$agent_token" "$user_pass" \
        "$harness" "$context_window"
    fi
  fi

  echo ""
  echo "Done! Agent '${agent_name}' hired for role '${role}'."
  echo "  User:    ${forge_url}/${agent_name}"
  echo "  Repo:    ${forge_url}/${agent_name}/.profile"
  echo "  Formula: ${role}.toml"
}
