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
#   disinto_hire_an_agent <agent-name> <role> [--formula <path>] [--local-model <url>] [--poll-interval <seconds>]
# =============================================================================
set -euo pipefail

disinto_hire_an_agent() {
  local agent_name="${1:-}"
  local role="${2:-}"
  local formula_path=""
  local local_model=""
  local poll_interval=""

  if [ -z "$agent_name" ] || [ -z "$role" ]; then
    echo "Error: agent-name and role required" >&2
    echo "Usage: disinto hire-an-agent <agent-name> <role> [--formula <path>] [--local-model <url>] [--poll-interval <seconds>]" >&2
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
      --poll-interval)
        poll_interval="$2"
        shift 2
        ;;
      *)
        echo "Unknown option: $1" >&2
        exit 1
        ;;
    esac
  done

  # Default formula path — try both naming conventions
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
    echo "Poll interval: ${poll_interval:-300}s"
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

  # Read admin password from .env for standalone runs (#184)
  local env_file="${FACTORY_ROOT}/.env"
  if [ -f "$env_file" ] && grep -q '^FORGE_ADMIN_PASS=' "$env_file" 2>/dev/null; then
    admin_pass=$(grep '^FORGE_ADMIN_PASS=' "$env_file" | head -1 | cut -d= -f2-)
  fi

  # Get admin token early (needed for both user creation and password reset)
  local admin_user="disinto-admin"
  admin_pass="${admin_pass:-admin}"
  local admin_token=""
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
  if [ -z "$admin_token" ]; then
    echo "Error: failed to obtain admin API token" >&2
    echo "  Cannot proceed without admin privileges" >&2
    exit 1
  fi

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
    # Create user using basic auth (admin token fallback would poison subsequent calls)
    # Create the user
    user_pass="agent-$(head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 20)"
    if curl -sf -X POST \
      -u "${admin_user}:${admin_pass}" \
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

  # Convert role to uppercase token variable name (e.g., architect -> FORGE_ARCHITECT_TOKEN)
  local role_upper
  role_upper=$(echo "$role" | tr '[:lower:]' '[:upper:]')
  local token_var="FORGE_${role_upper}_TOKEN"

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
    # Store token in .env under the role-specific variable name
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
    create_output=$(curl -sf -X POST \
      -u "${admin_user}:${admin_pass}" \
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

    local override_file="${FACTORY_ROOT}/docker-compose.override.yml"
    local override_dir
    override_dir=$(dirname "$override_file")
    mkdir -p "$override_dir"

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

    # Generate service name from agent name (lowercase)
    local service_name="agents-${agent_name}"
    service_name=$(echo "$service_name" | tr '[:upper:]' '[:lower:]')

    # Set default poll interval
    local interval="${poll_interval:-300}"

    # Generate the override compose file
    # Bash expands ${service_name}, ${local_model}, ${interval}, ${PROJECT_NAME} at generation time
    # \$HOME, \$FORGE_TOKEN become ${HOME}, ${FORGE_TOKEN} in the file for docker-compose runtime expansion
    cat > "$override_file" <<OVERRIDEOF
# docker-compose.override.yml — auto-generated by disinto hire-an-agent
# Local model agent configuration for ${agent_name}

services:
  ${service_name}:
    image: disinto-agents:latest
    profiles: ["local-model"]
    restart: unless-stopped
    security_opt:
      - apparmor=unconfined
    volumes:
      - agent-data-llama:/home/agent/data
      - project-repos-llama:/home/agent/repos
      - \$HOME/.claude:/home/agent/.claude
      - \$HOME/.claude.json:/home/agent/.claude.json:ro
      - CLAUDE_BIN_PLACEHOLDER:/usr/local/bin/claude:ro
      - \$HOME/.ssh:/home/agent/.ssh:ro
      - \$HOME/.config/sops/age:/home/agent/.config/sops/age:ro
    environment:
      FORGE_URL: http://forgejo:3000
      FORGE_TOKEN: ${FORGE_TOKEN_DEVQWEN:-}
      FORGE_SUPERVISOR_TOKEN: ${FORGE_SUPERVISOR_TOKEN:-}
      FORGE_PREDICTOR_TOKEN: ${FORGE_PREDICTOR_TOKEN:-}
      FORGE_ARCHITECT_TOKEN: ${FORGE_ARCHITECT_TOKEN:-}
      FORGE_VAULT_TOKEN: ${FORGE_VAULT_TOKEN:-}
      FORGE_PLANNER_TOKEN: ${FORGE_PLANNER_TOKEN:-}
      FORGE_BOT_USERNAMES: ${FORGE_BOT_USERNAMES:-}
      WOODPECKER_TOKEN: ${WOODPECKER_TOKEN:-}
      CLAUDE_TIMEOUT: ${CLAUDE_TIMEOUT:-7200}
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: ${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-1}
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY:-}
      ANTHROPIC_BASE_URL: ${local_model}
      FORGE_ADMIN_PASS: ${FORGE_ADMIN_PASS:-}
      DISINTO_CONTAINER: "1"
      PROJECT_REPO_ROOT: /home/agent/repos/${PROJECT_NAME:-project}
      WOODPECKER_DATA_DIR: /woodpecker-data
      AGENT_ROLES: dev
      CLAUDE_CONFIG_DIR: /home/agent/.claude
      POLL_INTERVAL: ${interval}
    depends_on:
      - forgejo
      - woodpecker

volumes:
  agent-data-llama:
  project-repos-llama:
OVERRIDEOF

    # Patch the Claude CLI binary path
    local claude_bin
    claude_bin="$(command -v claude 2>/dev/null || true)"
    if [ -n "$claude_bin" ]; then
      claude_bin="$(readlink -f "$claude_bin")"
      sed -i "s|CLAUDE_BIN_PLACEHOLDER|${claude_bin}|" "$override_file"
    else
      echo "  Warning: claude CLI not found — update override file manually"
      sed -i "s|CLAUDE_BIN_PLACEHOLDER|/usr/local/bin/claude|" "$override_file"
    fi

    echo "  Created: ${override_file}"
    echo "  Service name: ${service_name}"
    echo "  Poll interval: ${interval}s"
    echo "  Model endpoint: ${local_model}"
    echo ""
    echo "  To start the agent, run:"
    echo "    docker compose --profile local-model up -d ${service_name}"
  fi

  echo ""
  echo "Done! Agent '${agent_name}' hired for role '${role}'."
  echo "  User:    ${forge_url}/${agent_name}"
  echo "  Repo:    ${forge_url}/${agent_name}/.profile"
  echo "  Formula: ${role}.toml"
}
