#!/usr/bin/env bash
# =============================================================================
# forge-setup.sh — setup_forge() and helpers for Forgejo provisioning
#
# Handles admin user creation, bot user creation, token generation,
# password resets, repo creation, and collaborator setup.
#
# Globals expected (asserted by _load_init_context):
#   FORGE_URL    - Forge instance URL (e.g. http://localhost:3000)
#   FACTORY_ROOT - Root of the disinto factory
#   PRIMARY_BRANCH - Primary branch name (e.g. main)
#
# Usage:
#   source "${FACTORY_ROOT}/lib/forge-setup.sh"
#   setup_forge <forge_url> <repo_slug>
# =============================================================================
set -euo pipefail

# Assert required globals are set before using this module.
_load_init_context() {
  local missing=()
  [ -z "${FORGE_URL:-}" ]    && missing+=("FORGE_URL")
  [ -z "${FACTORY_ROOT:-}" ] && missing+=("FACTORY_ROOT")
  [ -z "${PRIMARY_BRANCH:-}" ] && missing+=("PRIMARY_BRANCH")
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "Error: forge-setup.sh requires these globals to be set: ${missing[*]}" >&2
    exit 1
  fi
}

# Execute a command in the Forgejo container (for admin operations)
_forgejo_exec() {
  local use_bare="${DISINTO_BARE:-false}"
  if [ "$use_bare" = true ]; then
    docker exec -u git disinto-forgejo "$@"
  else
    docker compose -f "${FACTORY_ROOT}/docker-compose.yml" exec -T -u git forgejo "$@"
  fi
}

# Provision or connect to a local Forgejo instance.
# Creates admin + bot users, generates API tokens, stores in .env.
# When $DISINTO_BARE is set, uses standalone docker run; otherwise uses compose.
setup_forge() {
  local forge_url="$1"
  local repo_slug="$2"
  local use_bare="${DISINTO_BARE:-false}"

  echo ""
  echo "── Forge setup ────────────────────────────────────────"

  # Check if Forgejo is already running
  if curl -sf --max-time 5 -H "Authorization: token ${FORGE_TOKEN:-}" "${forge_url}/api/v1/version" >/dev/null 2>&1; then
    echo "Forgejo:  ${forge_url} (already running)"
  else
    echo "Forgejo not reachable at ${forge_url}"
    echo "Starting Forgejo via Docker..."

    if ! command -v docker &>/dev/null; then
      echo "Error: docker not found — needed to provision Forgejo" >&2
      echo "  Install Docker or start Forgejo manually at ${forge_url}" >&2
      exit 1
    fi

    # Extract port from forge_url
    local forge_port
    forge_port=$(printf '%s' "$forge_url" | sed -E 's|.*:([0-9]+)/?$|\1|')
    forge_port="${forge_port:-3000}"

    if [ "$use_bare" = true ]; then
      # Bare-metal mode: standalone docker run
      mkdir -p "${FORGEJO_DATA_DIR}"

      if docker ps -a --format '{{.Names}}' | grep -q '^disinto-forgejo$'; then
        docker start disinto-forgejo >/dev/null 2>&1 || true
      else
        docker run -d \
          --name disinto-forgejo \
          --restart unless-stopped \
          -p "${forge_port}:3000" \
          -p 2222:22 \
          -v "${FORGEJO_DATA_DIR}:/data" \
          -e "FORGEJO__database__DB_TYPE=sqlite3" \
          -e "FORGEJO__server__ROOT_URL=${forge_url}/" \
          -e "FORGEJO__server__HTTP_PORT=3000" \
          -e "FORGEJO__service__DISABLE_REGISTRATION=true" \
          codeberg.org/forgejo/forgejo:11.0
      fi
    else
      # Compose mode: start Forgejo via docker compose
      docker compose -f "${FACTORY_ROOT}/docker-compose.yml" up -d forgejo
    fi

    # Wait for Forgejo to become healthy
    echo -n "Waiting for Forgejo to start"
    local retries=0
    while ! curl -sf --max-time 3 -H "Authorization: token ${FORGE_TOKEN:-}" "${forge_url}/api/v1/version" >/dev/null 2>&1; do
      retries=$((retries + 1))
      if [ "$retries" -gt 60 ]; then
        echo ""
        echo "Error: Forgejo did not become ready within 60s" >&2
        exit 1
      fi
      echo -n "."
      sleep 1
    done
    echo " ready"
  fi

  # Wait for Forgejo database to accept writes (API may be ready before DB is)
  echo -n "Waiting for Forgejo database"
  local db_ready=false
  for _i in $(seq 1 30); do
    if _forgejo_exec forgejo admin user list >/dev/null 2>&1; then
      db_ready=true
      break
    fi
    echo -n "."
    sleep 1
  done
  echo ""
  if [ "$db_ready" != true ]; then
    echo "Error: Forgejo database not ready after 30s" >&2
    exit 1
  fi

  # Create admin user if it doesn't exist
  local admin_user="disinto-admin"
  local admin_pass
  local env_file="${FACTORY_ROOT}/.env"

  # Re-read persisted admin password if available (#158)
  if grep -q '^FORGE_ADMIN_PASS=' "$env_file" 2>/dev/null; then
    admin_pass=$(grep '^FORGE_ADMIN_PASS=' "$env_file" | head -1 | cut -d= -f2-)
  fi
  # Generate a fresh password only when none was persisted
  if [ -z "${admin_pass:-}" ]; then
    admin_pass="admin-$(head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 20)"
  fi

  if ! curl -sf --max-time 5 -H "Authorization: token ${FORGE_TOKEN:-}" "${forge_url}/api/v1/users/${admin_user}" >/dev/null 2>&1; then
    echo "Creating admin user: ${admin_user}"
    local create_output
    if ! create_output=$(_forgejo_exec forgejo admin user create \
      --admin \
      --username "${admin_user}" \
      --password "${admin_pass}" \
      --email "admin@disinto.local" \
      --must-change-password=false 2>&1); then
      echo "Error: failed to create admin user '${admin_user}':" >&2
      echo "  ${create_output}" >&2
      exit 1
    fi
    # Forgejo 11.x ignores --must-change-password=false on create;
    # explicitly clear the flag so basic-auth token creation works.
    _forgejo_exec forgejo admin user change-password \
      --username "${admin_user}" \
      --password "${admin_pass}" \
      --must-change-password=false

    # Verify admin user was actually created
    if ! curl -sf --max-time 5 -H "Authorization: token ${FORGE_TOKEN:-}" "${forge_url}/api/v1/users/${admin_user}" >/dev/null 2>&1; then
      echo "Error: admin user '${admin_user}' not found after creation" >&2
      exit 1
    fi

    # Persist admin password to .env for idempotent re-runs (#158)
    if grep -q '^FORGE_ADMIN_PASS=' "$env_file" 2>/dev/null; then
      sed -i "s|^FORGE_ADMIN_PASS=.*|FORGE_ADMIN_PASS=${admin_pass}|" "$env_file"
    else
      printf 'FORGE_ADMIN_PASS=%s\n' "$admin_pass" >> "$env_file"
    fi
  else
    echo "Admin user: ${admin_user} (already exists)"
    # Only reset password if basic auth fails (#158, #267)
    # Forgejo 11.x may ignore --must-change-password=false, blocking token creation
    if ! curl -sf --max-time 5 -u "${admin_user}:${admin_pass}" \
        "${forge_url}/api/v1/user" >/dev/null 2>&1; then
      _forgejo_exec forgejo admin user change-password \
        --username "${admin_user}" \
        --password "${admin_pass}" \
        --must-change-password=false
    fi
  fi
  # Preserve password for Woodpecker OAuth2 token generation (#779)
  _FORGE_ADMIN_PASS="$admin_pass"

  # Create human user (disinto-admin) as site admin if it doesn't exist
  local human_user="disinto-admin"
  local human_pass
  human_pass="admin-$(head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 20)"

  if ! curl -sf --max-time 5 -H "Authorization: token ${FORGE_TOKEN:-}" "${forge_url}/api/v1/users/${human_user}" >/dev/null 2>&1; then
    echo "Creating human user: ${human_user}"
    local create_output
    if ! create_output=$(_forgejo_exec forgejo admin user create \
      --admin \
      --username "${human_user}" \
      --password "${human_pass}" \
      --email "admin@disinto.local" \
      --must-change-password=false 2>&1); then
      echo "Error: failed to create human user '${human_user}':" >&2
      echo "  ${create_output}" >&2
      exit 1
    fi
    # Forgejo 11.x ignores --must-change-password=false on create;
    # explicitly clear the flag so basic-auth token creation works.
    _forgejo_exec forgejo admin user change-password \
      --username "${human_user}" \
      --password "${human_pass}" \
      --must-change-password=false

    # Verify human user was actually created
    if ! curl -sf --max-time 5 -H "Authorization: token ${FORGE_TOKEN:-}" "${forge_url}/api/v1/users/${human_user}" >/dev/null 2>&1; then
      echo "Error: human user '${human_user}' not found after creation" >&2
      exit 1
    fi
    echo "  Human user '${human_user}' created as site admin"
  else
    echo "Human user: ${human_user} (already exists)"
  fi

  # Delete existing admin token if present (token sha1 is only returned at creation time)
  local existing_token_id
  existing_token_id=$(curl -sf \
    -u "${admin_user}:${admin_pass}" \
    "${forge_url}/api/v1/users/${admin_user}/tokens" 2>/dev/null \
    | jq -r '.[] | select(.name == "disinto-admin-token") | .id') || existing_token_id=""
  if [ -n "$existing_token_id" ]; then
    curl -sf -X DELETE \
      -u "${admin_user}:${admin_pass}" \
      "${forge_url}/api/v1/users/${admin_user}/tokens/${existing_token_id}" >/dev/null 2>&1 || true
  fi

  # Create admin token (fresh, so sha1 is returned)
  local admin_token
  admin_token=$(curl -sf -X POST \
    -u "${admin_user}:${admin_pass}" \
    -H "Content-Type: application/json" \
    "${forge_url}/api/v1/users/${admin_user}/tokens" \
    -d '{"name":"disinto-admin-token","scopes":["all"]}' 2>/dev/null \
    | jq -r '.sha1 // empty') || admin_token=""

  if [ -z "$admin_token" ]; then
    echo "Error: failed to obtain admin API token" >&2
    exit 1
  fi

  # Get or create human user token
  local human_token=""
  # Delete existing human token if present (token sha1 is only returned at creation time)
  local existing_human_token_id
  existing_human_token_id=$(curl -sf \
    -u "${human_user}:${human_pass}" \
    "${forge_url}/api/v1/users/${human_user}/tokens" 2>/dev/null \
    | jq -r '.[] | select(.name == "disinto-human-token") | .id') || existing_human_token_id=""
  if [ -n "$existing_human_token_id" ]; then
    curl -sf -X DELETE \
      -u "${human_user}:${human_pass}" \
      "${forge_url}/api/v1/users/${human_user}/tokens/${existing_human_token_id}" >/dev/null 2>&1 || true
  fi

  # Create human token (fresh, so sha1 is returned)
  human_token=$(curl -sf -X POST \
    -u "${human_user}:${human_pass}" \
    -H "Content-Type: application/json" \
    "${forge_url}/api/v1/users/${human_user}/tokens" \
    -d '{"name":"disinto-human-token","scopes":["all"]}' 2>/dev/null \
    | jq -r '.sha1 // empty') || human_token=""

  if [ -n "$human_token" ]; then
    # Store human token in .env
    if grep -q '^HUMAN_TOKEN=' "$env_file" 2>/dev/null; then
      sed -i "s|^HUMAN_TOKEN=.*|HUMAN_TOKEN=${human_token}|" "$env_file"
    else
      printf 'HUMAN_TOKEN=%s\n' "$human_token" >> "$env_file"
    fi
    export HUMAN_TOKEN="$human_token"
    echo "  Human token saved (HUMAN_TOKEN)"
  fi

  # Create bot users and tokens
  # Each agent gets its own Forgejo account for identity and audit trail (#747).
  # Map: bot-username -> env-var-name for the token
  local -A bot_token_vars=(
    [dev-bot]="FORGE_TOKEN"
    [review-bot]="FORGE_REVIEW_TOKEN"
    [planner-bot]="FORGE_PLANNER_TOKEN"
    [gardener-bot]="FORGE_GARDENER_TOKEN"
    [vault-bot]="FORGE_VAULT_TOKEN"
    [supervisor-bot]="FORGE_SUPERVISOR_TOKEN"
    [predictor-bot]="FORGE_PREDICTOR_TOKEN"
    [architect-bot]="FORGE_ARCHITECT_TOKEN"
  )
  # Map: bot-username -> env-var-name for the password
  # Forgejo 11.x API tokens don't work for git HTTP push (#361).
  # Store passwords so agents can use password auth for git operations.
  local -A bot_pass_vars=(
    [dev-bot]="FORGE_PASS"
    [review-bot]="FORGE_REVIEW_PASS"
    [planner-bot]="FORGE_PLANNER_PASS"
    [gardener-bot]="FORGE_GARDENER_PASS"
    [vault-bot]="FORGE_VAULT_PASS"
    [supervisor-bot]="FORGE_SUPERVISOR_PASS"
    [predictor-bot]="FORGE_PREDICTOR_PASS"
    [architect-bot]="FORGE_ARCHITECT_PASS"
  )
  # Llama bot users (local-model agents) — separate from main agents
  # Each llama agent gets its own Forgejo user, token, and password
  local -A llama_token_vars=(
    [dev-qwen]="FORGE_TOKEN_LLAMA"
    [dev-qwen-nightly]="FORGE_TOKEN_LLAMA_NIGHTLY"
  )
  local -A llama_pass_vars=(
    [dev-qwen]="FORGE_PASS_LLAMA"
    [dev-qwen-nightly]="FORGE_PASS_LLAMA_NIGHTLY"
  )

  local bot_user bot_pass token token_var pass_var

  for bot_user in dev-bot review-bot planner-bot gardener-bot vault-bot supervisor-bot predictor-bot architect-bot; do
    bot_pass="bot-$(head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 20)"
    token_var="${bot_token_vars[$bot_user]}"

    # Check if bot user exists
    local user_exists=false
    if curl -sf --max-time 5 \
      -H "Authorization: token ${admin_token}" \
      "${forge_url}/api/v1/users/${bot_user}" >/dev/null 2>&1; then
      user_exists=true
    fi

    if [ "$user_exists" = false ]; then
      echo "Creating bot user: ${bot_user}"
      local create_output
      if ! create_output=$(_forgejo_exec forgejo admin user create \
        --username "${bot_user}" \
        --password "${bot_pass}" \
        --email "${bot_user}@disinto.local" \
        --must-change-password=false 2>&1); then
        echo "Error: failed to create bot user '${bot_user}':" >&2
        echo "  ${create_output}" >&2
        exit 1
      fi
      # Forgejo 11.x ignores --must-change-password=false on create;
      # explicitly clear the flag so basic-auth token creation works.
      _forgejo_exec forgejo admin user change-password \
        --username "${bot_user}" \
        --password "${bot_pass}" \
        --must-change-password=false

      # Verify bot user was actually created
      if ! curl -sf --max-time 5 \
        -H "Authorization: token ${admin_token}" \
        "${forge_url}/api/v1/users/${bot_user}" >/dev/null 2>&1; then
        echo "Error: bot user '${bot_user}' not found after creation" >&2
        exit 1
      fi
      echo "  ${bot_user} user created"
    else
      echo "  ${bot_user} user exists (resetting password for token generation)"
      # User exists but may not have a known password.
      # Use admin API to reset the password so we can generate a new token.
      _forgejo_exec forgejo admin user change-password \
        --username "${bot_user}" \
        --password "${bot_pass}" \
        --must-change-password=false || {
        echo "Error: failed to reset password for existing bot user '${bot_user}'" >&2
        exit 1
      }
    fi

    # Generate token via API (basic auth as the bot user — Forgejo requires
    # basic auth on POST /users/{username}/tokens, token auth is rejected)
    # First, try to delete existing tokens to avoid name collision
    # Use bot user's own Basic Auth (we just set the password above)
    local existing_token_ids
    existing_token_ids=$(curl -sf \
      -u "${bot_user}:${bot_pass}" \
      "${forge_url}/api/v1/users/${bot_user}/tokens" 2>/dev/null \
      | jq -r '.[].id // empty' 2>/dev/null) || existing_token_ids=""

    # Delete any existing tokens for this user
    if [ -n "$existing_token_ids" ]; then
      while IFS= read -r tid; do
        [ -n "$tid" ] && curl -sf -X DELETE \
          -u "${bot_user}:${bot_pass}" \
          "${forge_url}/api/v1/users/${bot_user}/tokens/${tid}" >/dev/null 2>&1 || true
      done <<< "$existing_token_ids"
    fi

    token=$(curl -sf -X POST \
      -u "${bot_user}:${bot_pass}" \
      -H "Content-Type: application/json" \
      "${forge_url}/api/v1/users/${bot_user}/tokens" \
      -d "{\"name\":\"disinto-${bot_user}-token\",\"scopes\":[\"all\"]}" 2>/dev/null \
      | jq -r '.sha1 // empty') || token=""

    if [ -z "$token" ]; then
      echo "Error: failed to create API token for '${bot_user}'" >&2
      exit 1
    fi

    # Store token in .env under the per-agent variable name
    if grep -q "^${token_var}=" "$env_file" 2>/dev/null; then
      sed -i "s|^${token_var}=.*|${token_var}=${token}|" "$env_file"
    else
      printf '%s=%s\n' "$token_var" "$token" >> "$env_file"
    fi
    export "${token_var}=${token}"
    echo "  ${bot_user} token generated and saved (${token_var})"

    # Store password in .env for git HTTP push (#361)
    # Forgejo 11.x API tokens don't work for git push; password auth does.
    pass_var="${bot_pass_vars[$bot_user]}"
    if grep -q "^${pass_var}=" "$env_file" 2>/dev/null; then
      sed -i "s|^${pass_var}=.*|${pass_var}=${bot_pass}|" "$env_file"
    else
      printf '%s=%s\n' "$pass_var" "$bot_pass" >> "$env_file"
    fi
    export "${pass_var}=${bot_pass}"
    echo "  ${bot_user} password saved (${pass_var})"

    # Backwards-compat aliases for dev-bot and review-bot
    if [ "$bot_user" = "dev-bot" ]; then
      export CODEBERG_TOKEN="$token"
    elif [ "$bot_user" = "review-bot" ]; then
      export REVIEW_BOT_TOKEN="$token"
    fi
  done

  # Create llama bot users and tokens (local-model agents)
  # These are separate from the main agents and get their own credentials
  echo ""
  echo "── Setting up llama bot users ────────────────────────────"

  local llama_user llama_pass llama_token llama_token_var llama_pass_var
  for llama_user in "${!llama_token_vars[@]}"; do
    llama_token_var="${llama_token_vars[$llama_user]}"
    llama_pass_var="${llama_pass_vars[$llama_user]}"

    # Check if llama bot user exists
    local llama_user_exists=false
    if curl -sf --max-time 5 \
      -H "Authorization: token ${admin_token}" \
      "${forge_url}/api/v1/users/${llama_user}" >/dev/null 2>&1; then
      llama_user_exists=true
    fi

    if [ "$llama_user_exists" = false ]; then
      echo "Creating llama bot user: ${llama_user}"
      # Generate a unique password for this user
      llama_pass="llama-$(head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 20)"
      local create_output
      if ! create_output=$(_forgejo_exec forgejo admin user create \
        --username "${llama_user}" \
        --password "${llama_pass}" \
        --email "${llama_user}@disinto.local" \
        --must-change-password=false 2>&1); then
        echo "Error: failed to create llama bot user '${llama_user}':" >&2
        echo "  ${create_output}" >&2
        exit 1
      fi
      # Forgejo 11.x ignores --must-change-password=false on create;
      # explicitly clear the flag so basic-auth token creation works.
      _forgejo_exec forgejo admin user change-password \
        --username "${llama_user}" \
        --password "${llama_pass}" \
        --must-change-password=false

      # Verify llama bot user was actually created
      if ! curl -sf --max-time 5 \
        -H "Authorization: token ${admin_token}" \
        "${forge_url}/api/v1/users/${llama_user}" >/dev/null 2>&1; then
        echo "Error: llama bot user '${llama_user}' not found after creation" >&2
        exit 1
      fi
      echo "  ${llama_user} user created"
    else
      echo "  ${llama_user} user exists (resetting password for token generation)"
      # User exists but may not have a known password.
      # Use admin API to reset the password so we can generate a new token.
      llama_pass="llama-$(head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 20)"
      _forgejo_exec forgejo admin user change-password \
        --username "${llama_user}" \
        --password "${llama_pass}" \
        --must-change-password=false || {
        echo "Error: failed to reset password for existing llama bot user '${llama_user}'" >&2
        exit 1
      }
    fi

    # Generate token via API (basic auth as the llama user)
    # First, delete any existing tokens to avoid name collision
    local existing_llama_token_ids
    existing_llama_token_ids=$(curl -sf \
      -u "${llama_user}:${llama_pass}" \
      "${forge_url}/api/v1/users/${llama_user}/tokens" 2>/dev/null \
      | jq -r '.[].id // empty' 2>/dev/null) || existing_llama_token_ids=""

    # Delete any existing tokens for this user
    if [ -n "$existing_llama_token_ids" ]; then
      while IFS= read -r tid; do
        [ -n "$tid" ] && curl -sf -X DELETE \
          -u "${llama_user}:${llama_pass}" \
          "${forge_url}/api/v1/users/${llama_user}/tokens/${tid}" >/dev/null 2>&1 || true
      done <<< "$existing_llama_token_ids"
    fi

    llama_token=$(curl -sf -X POST \
      -u "${llama_user}:${llama_pass}" \
      -H "Content-Type: application/json" \
      "${forge_url}/api/v1/users/${llama_user}/tokens" \
      -d "{\"name\":\"disinto-${llama_user}-token\",\"scopes\":[\"all\"]}" 2>/dev/null \
      | jq -r '.sha1 // empty') || llama_token=""

    if [ -z "$llama_token" ]; then
      echo "Error: failed to create API token for '${llama_user}'" >&2
      exit 1
    fi

    # Store token in .env under the llama-specific variable name
    if grep -q "^${llama_token_var}=" "$env_file" 2>/dev/null; then
      sed -i "s|^${llama_token_var}=.*|${llama_token_var}=${llama_token}|" "$env_file"
    else
      printf '%s=%s\n' "$llama_token_var" "$llama_token" >> "$env_file"
    fi
    export "${llama_token_var}=${llama_token}"
    echo "  ${llama_user} token generated and saved (${llama_token_var})"

    # Store password in .env for git HTTP push (#361)
    # Forgejo 11.x API tokens don't work for git push; password auth does.
    if grep -q "^${llama_pass_var}=" "$env_file" 2>/dev/null; then
      sed -i "s|^${llama_pass_var}=.*|${llama_pass_var}=${llama_pass}|" "$env_file"
    else
      printf '%s=%s\n' "$llama_pass_var" "$llama_pass" >> "$env_file"
    fi
    export "${llama_pass_var}=${llama_pass}"
    echo "  ${llama_user} password saved (${llama_pass_var})"
  done

  # Create .profile repos for all bot users (if they don't already exist)
  # This runs the same logic as hire-an-agent Step 2-3 for idempotent setup
  echo ""
  echo "── Setting up .profile repos ────────────────────────────"

  local -a bot_users=(dev-bot review-bot planner-bot gardener-bot vault-bot supervisor-bot predictor-bot architect-bot)
  # Add llama bot users to .profile repo creation
  for llama_user in "${!llama_token_vars[@]}"; do
    bot_users+=("$llama_user")
  done
  local bot_user

  for bot_user in "${bot_users[@]}"; do
    # Check if .profile repo already exists
    if curl -sf --max-time 5 -H "Authorization: token ${admin_token}" "${forge_url}/api/v1/repos/${bot_user}/.profile" >/dev/null 2>&1; then
      echo "  ${bot_user}/.profile already exists"
      continue
    fi

    echo "Creating ${bot_user}/.profile repo..."

    # Create the repo using the admin API to ensure it's created in the bot user's namespace
    local create_output
    create_output=$(curl -sf -X POST \
      -u "${admin_user}:${admin_pass}" \
      -H "Content-Type: application/json" \
      "${forge_url}/api/v1/admin/users/${bot_user}/repos" \
      -d "{\"name\":\".profile\",\"description\":\"${bot_user}'s .profile repo\",\"private\":true,\"auto_init\":false}" 2>&1) || true

    if echo "$create_output" | grep -q '"id":\|[0-9]'; then
      echo "  Created ${bot_user}/.profile (via admin API)"
    else
      echo "  Warning: failed to create ${bot_user}/.profile: ${create_output}" >&2
    fi
  done

  # Store FORGE_URL in .env if not already present
  if ! grep -q '^FORGE_URL=' "$env_file" 2>/dev/null; then
    printf 'FORGE_URL=%s\n' "$forge_url" >> "$env_file"
  fi

  # Create the repo on Forgejo if it doesn't exist
  local org_name="${repo_slug%%/*}"
  local repo_name="${repo_slug##*/}"

  # Check if repo already exists
  if ! curl -sf --max-time 5 \
    -H "Authorization: token ${FORGE_TOKEN}" \
    "${forge_url}/api/v1/repos/${repo_slug}" >/dev/null 2>&1; then

    # Try creating org first (ignore if exists)
    curl -sf -X POST \
      -H "Authorization: token ${admin_token:-${FORGE_TOKEN}}" \
      -H "Content-Type: application/json" \
      "${forge_url}/api/v1/orgs" \
      -d "{\"username\":\"${org_name}\",\"visibility\":\"public\"}" >/dev/null 2>&1 || true

    # Create repo under org
    if ! curl -sf -X POST \
      -H "Authorization: token ${admin_token:-${FORGE_TOKEN}}" \
      -H "Content-Type: application/json" \
      "${forge_url}/api/v1/orgs/${org_name}/repos" \
      -d "{\"name\":\"${repo_name}\",\"auto_init\":false,\"default_branch\":\"main\"}" >/dev/null 2>&1; then
      # Fallback: create under the human user namespace using admin endpoint
      if [ -n "${admin_token:-}" ]; then
        if ! curl -sf -X POST \
          -H "Authorization: token ${admin_token}" \
          -H "Content-Type: application/json" \
          "${forge_url}/api/v1/admin/users/${org_name}/repos" \
          -d "{\"name\":\"${repo_name}\",\"auto_init\":false,\"default_branch\":\"main\"}" >/dev/null 2>&1; then
          echo "Error: failed to create repo '${repo_slug}' on Forgejo (admin endpoint)" >&2
          exit 1
        fi
      elif [ -n "${HUMAN_TOKEN:-}" ]; then
        if ! curl -sf -X POST \
          -H "Authorization: token ${HUMAN_TOKEN}" \
          -H "Content-Type: application/json" \
          "${forge_url}/api/v1/user/repos" \
          -d "{\"name\":\"${repo_name}\",\"auto_init\":false,\"default_branch\":\"main\"}" >/dev/null 2>&1; then
          echo "Error: failed to create repo '${repo_slug}' on Forgejo (user endpoint)" >&2
          exit 1
        fi
      else
        echo "Error: failed to create repo '${repo_slug}' — no admin or human token available" >&2
        exit 1
      fi
    fi

    # Add all bot users as collaborators with appropriate permissions
    # dev-bot: write (PR creation via lib/vault.sh)
    # review-bot: read (PR review)
    # planner-bot: write (prerequisites.md, memory)
    # gardener-bot: write (backlog grooming)
    # vault-bot: write (vault items)
    # supervisor-bot: read (health monitoring)
    # predictor-bot: read (pattern detection)
    # architect-bot: write (sprint PRs)
    local bot_perm
    declare -A bot_permissions=(
      [dev-bot]="write"
      [review-bot]="read"
      [planner-bot]="write"
      [gardener-bot]="write"
      [vault-bot]="write"
      [supervisor-bot]="read"
      [predictor-bot]="read"
      [architect-bot]="write"
    )
    for bot_user in "${!bot_permissions[@]}"; do
      bot_perm="${bot_permissions[$bot_user]}"
      curl -sf -X PUT \
        -H "Authorization: token ${admin_token:-${FORGE_TOKEN}}" \
        -H "Content-Type: application/json" \
        "${forge_url}/api/v1/repos/${repo_slug}/collaborators/${bot_user}" \
        -d "{\"permission\":\"${bot_perm}\"}" >/dev/null 2>&1 || true
    done

    # Add llama bot users as write collaborators for local-model agents
    for llama_user in "${!llama_token_vars[@]}"; do
      curl -sf -X PUT \
        -H "Authorization: token ${admin_token:-${FORGE_TOKEN}}" \
        -H "Content-Type: application/json" \
        "${forge_url}/api/v1/repos/${repo_slug}/collaborators/${llama_user}" \
        -d '{"permission":"write"}' >/dev/null 2>&1 || true
    done

    # Add disinto-admin as admin collaborator
    curl -sf -X PUT \
      -H "Authorization: token ${admin_token:-${FORGE_TOKEN}}" \
      -H "Content-Type: application/json" \
      "${forge_url}/api/v1/repos/${repo_slug}/collaborators/disinto-admin" \
      -d '{"permission":"admin"}' >/dev/null 2>&1 || true

    echo "Repo:    ${repo_slug} created on Forgejo"
  else
    echo "Repo:    ${repo_slug} (already exists on Forgejo)"
  fi

  echo "Forge:   ${forge_url} (ready)"
}
