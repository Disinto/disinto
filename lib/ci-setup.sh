#!/usr/bin/env bash
# =============================================================================
# ci-setup.sh — CI setup functions for Woodpecker and scheduling configuration
#
# Internal functions (called via _load_ci_context + _*_impl):
#   _install_cron_impl()              - Install crontab entries (bare-metal only; compose uses polling loop)
#   _create_woodpecker_oauth_impl()   - Create OAuth2 app on Forgejo for Woodpecker
#   _generate_woodpecker_token_impl() - Auto-generate WOODPECKER_TOKEN via OAuth2 flow
#   _activate_woodpecker_repo_impl()  - Activate repo in Woodpecker
#
# Globals expected (asserted by _load_ci_context):
#   FORGE_URL    - Forge instance URL (e.g. http://localhost:3000)
#   FORGE_TOKEN  - Forge API token
#   FACTORY_ROOT - Root of the disinto factory
#
# Usage:
#   source "${FACTORY_ROOT}/lib/ci-setup.sh"
# =============================================================================
set -euo pipefail

# Assert required globals are set before using this module.
_load_ci_context() {
  local missing=()
  [ -z "${FORGE_URL:-}" ]    && missing+=("FORGE_URL")
  [ -z "${FORGE_TOKEN:-}" ]  && missing+=("FORGE_TOKEN")
  [ -z "${FACTORY_ROOT:-}" ] && missing+=("FACTORY_ROOT")
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "Error: ci-setup.sh requires these globals to be set: ${missing[*]}" >&2
    exit 1
  fi
}

# Generate and optionally install cron entries for bare-metal deployments.
# In compose mode, the agents container uses a polling loop (entrypoint.sh) instead.
# Usage: install_cron <name> <toml_path> <auto_yes> <bare>
_install_cron_impl() {
  local name="$1" toml="$2" auto_yes="$3" bare="${4:-false}"

  # In compose mode, skip host cron — the agents container uses a polling loop
  if [ "$bare" = false ]; then
    echo ""
    echo "Cron:    skipped (agents container handles scheduling in compose mode)"
    return
  fi

  # Bare mode: crontab is required on the host
  if ! command -v crontab &>/dev/null; then
    echo "Error: crontab not found (required for bare-metal mode)" >&2
    echo "  Install: apt install cron  /  brew install cron" >&2
    exit 1
  fi

  # Use absolute path for the TOML in cron entries
  local abs_toml
  abs_toml="$(cd "$(dirname "$toml")" && pwd)/$(basename "$toml")"

  local cron_block
  cron_block="# disinto: ${name}
2,7,12,17,22,27,32,37,42,47,52,57 * * * * ${FACTORY_ROOT}/review/review-poll.sh ${abs_toml} >/dev/null 2>&1
4,9,14,19,24,29,34,39,44,49,54,59 * * * * ${FACTORY_ROOT}/dev/dev-poll.sh ${abs_toml} >/dev/null 2>&1
0 0,6,12,18 * * * cd ${FACTORY_ROOT} && bash gardener/gardener-run.sh ${abs_toml} >/dev/null 2>&1"

  echo ""
  echo "Cron entries to install:"
  echo "$cron_block"
  echo ""

  # Check if cron entries already exist
  local current_crontab
  current_crontab=$(crontab -l 2>/dev/null || true)
  if echo "$current_crontab" | grep -q "# disinto: ${name}"; then
    echo "Cron:    skipped (entries for ${name} already installed)"
    return
  fi

  if [ "$auto_yes" = false ] && [ -t 0 ]; then
    read -rp "Install these cron entries? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
      echo "Skipped cron install. Add manually with: crontab -e"
      return
    fi
  fi

  # Append to existing crontab
  if { crontab -l 2>/dev/null || true; printf '%s\n' "$cron_block"; } | crontab -; then
    echo "Cron entries installed for ${name}"
  else
    echo "Error: failed to install cron entries" >&2
    return 1
  fi
}

# Set up Woodpecker CI to use Forgejo as its forge backend.
# Creates an OAuth2 app on Forgejo for Woodpecker, activates the repo.
# Usage: create_woodpecker_oauth <forge_url> <repo_slug>
_create_woodpecker_oauth_impl() {
  local forge_url="$1"
  local _repo_slug="$2" # unused but required for signature compatibility

  echo ""
  echo "── Woodpecker OAuth2 setup ────────────────────────────"

  # Create OAuth2 application on Forgejo for Woodpecker
  local oauth2_name="woodpecker-ci"
  local redirect_uri="http://localhost:8000/authorize"
  local existing_app client_id client_secret

  # Check if OAuth2 app already exists
  existing_app=$(curl -sf \
    -H "Authorization: token ${FORGE_TOKEN}" \
    "${forge_url}/api/v1/user/applications/oauth2" 2>/dev/null \
    | jq -r --arg name "$oauth2_name" '.[] | select(.name == $name) | .client_id // empty' 2>/dev/null) || true

  if [ -n "$existing_app" ]; then
    echo "OAuth2:  ${oauth2_name} (already exists, client_id=${existing_app})"
    client_id="$existing_app"
  else
    local oauth2_resp
    oauth2_resp=$(curl -sf -X POST \
      -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      "${forge_url}/api/v1/user/applications/oauth2" \
      -d "{\"name\":\"${oauth2_name}\",\"redirect_uris\":[\"${redirect_uri}\"],\"confidential_client\":true}" \
      2>/dev/null) || oauth2_resp=""

    if [ -z "$oauth2_resp" ]; then
      echo "Warning: failed to create OAuth2 app on Forgejo" >&2
      return
    fi

    client_id=$(printf '%s' "$oauth2_resp" | jq -r '.client_id // empty')
    client_secret=$(printf '%s' "$oauth2_resp" | jq -r '.client_secret // empty')

    if [ -z "$client_id" ]; then
      echo "Warning: OAuth2 app creation returned no client_id" >&2
      return
    fi

    echo "OAuth2:  ${oauth2_name} created (client_id=${client_id})"
  fi

  # Store Woodpecker forge config in .env
  # WP_FORGEJO_CLIENT/SECRET match the docker-compose.yml variable references
  # WOODPECKER_HOST must be host-accessible URL to match OAuth2 redirect_uri
  local env_file="${FACTORY_ROOT}/.env"
  local wp_vars=(
    "WOODPECKER_FORGEJO=true"
    "WOODPECKER_FORGEJO_URL=${forge_url}"
    "WOODPECKER_HOST=http://localhost:8000"
  )
  if [ -n "${client_id:-}" ]; then
    wp_vars+=("WP_FORGEJO_CLIENT=${client_id}")
  fi
  if [ -n "${client_secret:-}" ]; then
    wp_vars+=("WP_FORGEJO_SECRET=${client_secret}")
  fi

  for var_line in "${wp_vars[@]}"; do
    local var_name="${var_line%%=*}"
    if grep -q "^${var_name}=" "$env_file" 2>/dev/null; then
      sed -i "s|^${var_name}=.*|${var_line}|" "$env_file"
    else
      printf '%s\n' "$var_line" >> "$env_file"
    fi
  done
  echo "Config:  Woodpecker forge vars written to .env"
}

# Auto-generate WOODPECKER_TOKEN by driving the Forgejo OAuth2 login flow.
# Requires _FORGE_ADMIN_PASS (set by setup_forge when admin user was just created).
# Called after compose stack is up, before activate_woodpecker_repo.
# Usage: generate_woodpecker_token <forge_url>
_generate_woodpecker_token_impl() {
  local forge_url="$1"
  local wp_server="${WOODPECKER_SERVER:-http://localhost:8000}"
  local env_file="${FACTORY_ROOT}/.env"
  local admin_user="disinto-admin"
  local admin_pass="${_FORGE_ADMIN_PASS:-}"

  # Skip if already set
  if grep -q '^WOODPECKER_TOKEN=' "$env_file" 2>/dev/null; then
    echo "Config:  WOODPECKER_TOKEN already set in .env"
    return 0
  fi

  echo ""
  echo "── Woodpecker token generation ────────────────────────"

  if [ -z "$admin_pass" ]; then
    echo "Warning: Forgejo admin password not available — cannot generate WOODPECKER_TOKEN" >&2
    echo "  Log into Woodpecker at ${wp_server} and create a token manually" >&2
    return 1
  fi

  # Wait for Woodpecker to become ready
  echo -n "Waiting for Woodpecker"
  local retries=0
  while ! curl -sf --max-time 3 "${wp_server}/api/version" >/dev/null 2>&1; do
    retries=$((retries + 1))
    if [ "$retries" -gt 30 ]; then
      echo ""
      echo "Warning: Woodpecker not ready at ${wp_server} — skipping token generation" >&2
      return 1
    fi
    echo -n "."
    sleep 2
  done
  echo " ready"

  # Flow: Forgejo web login → OAuth2 authorize → Woodpecker callback → token
  local cookie_jar auth_body_file
  cookie_jar=$(mktemp /tmp/wp-auth-XXXXXX)
  auth_body_file=$(mktemp /tmp/wp-body-XXXXXX)

  # Step 1: Log into Forgejo web UI (session cookie needed for OAuth consent)
  local csrf
  csrf=$(curl -sf -c "$cookie_jar" "${forge_url}/user/login" 2>/dev/null \
    | grep -o 'name="_csrf"[^>]*' | head -1 \
    | grep -oE '(content|value)="[^"]*"' | head -1 \
    | cut -d'"' -f2) || csrf=""

  if [ -z "$csrf" ]; then
    echo "Warning: could not get Forgejo CSRF token — skipping token generation" >&2
    rm -f "$cookie_jar" "$auth_body_file"
    return 1
  fi

  curl -sf -b "$cookie_jar" -c "$cookie_jar" -X POST \
    -o /dev/null \
    "${forge_url}/user/login" \
    --data-urlencode "_csrf=${csrf}" \
    --data-urlencode "user_name=${admin_user}" \
    --data-urlencode "password=${admin_pass}" \
    2>/dev/null || true

  # Step 2: Start Woodpecker OAuth2 flow (captures authorize URL with state param)
  local wp_redir
  wp_redir=$(curl -sf -o /dev/null -w '%{redirect_url}' \
    "${wp_server}/authorize" 2>/dev/null) || wp_redir=""

  if [ -z "$wp_redir" ]; then
    echo "Warning: Woodpecker did not provide OAuth redirect — skipping token generation" >&2
    rm -f "$cookie_jar" "$auth_body_file"
    return 1
  fi

  # Rewrite internal Docker network URLs to host-accessible URLs.
  # Handle both plain and URL-encoded forms of the internal hostnames.
  local forge_url_enc wp_server_enc
  forge_url_enc=$(printf '%s' "$forge_url" | sed 's|:|%3A|g; s|/|%2F|g')
  wp_server_enc=$(printf '%s' "$wp_server" | sed 's|:|%3A|g; s|/|%2F|g')
  wp_redir=$(printf '%s' "$wp_redir" \
    | sed "s|http://forgejo:3000|${forge_url}|g" \
    | sed "s|http%3A%2F%2Fforgejo%3A3000|${forge_url_enc}|g" \
    | sed "s|http://woodpecker:8000|${wp_server}|g" \
    | sed "s|http%3A%2F%2Fwoodpecker%3A8000|${wp_server_enc}|g")

  # Step 3: Hit Forgejo OAuth authorize endpoint with session
  # First time: shows consent page. Already approved: redirects with code.
  local auth_headers redirect_loc auth_code
  auth_headers=$(curl -sf -b "$cookie_jar" -c "$cookie_jar" \
    -D - -o "$auth_body_file" \
    "$wp_redir" 2>/dev/null) || auth_headers=""

  redirect_loc=$(printf '%s' "$auth_headers" \
    | grep -i '^location:' | head -1 | tr -d '\r' | awk '{print $2}')

  if printf '%s' "${redirect_loc:-}" | grep -q 'code='; then
    # Auto-approved: extract code from redirect
    auth_code=$(printf '%s' "$redirect_loc" | sed 's/.*code=\([^&]*\).*/\1/')
  else
    # Consent page: extract CSRF and all form fields, POST grant approval
    local consent_csrf form_client_id form_state form_redirect_uri
    consent_csrf=$(grep -o 'name="_csrf"[^>]*' "$auth_body_file" 2>/dev/null \
      | head -1 | grep -oE '(content|value)="[^"]*"' | head -1 \
      | cut -d'"' -f2) || consent_csrf=""
    form_client_id=$(grep 'name="client_id"' "$auth_body_file" 2>/dev/null \
      | grep -oE 'value="[^"]*"' | cut -d'"' -f2) || form_client_id=""
    form_state=$(grep 'name="state"' "$auth_body_file" 2>/dev/null \
      | grep -oE 'value="[^"]*"' | cut -d'"' -f2) || form_state=""
    form_redirect_uri=$(grep 'name="redirect_uri"' "$auth_body_file" 2>/dev/null \
      | grep -oE 'value="[^"]*"' | cut -d'"' -f2) || form_redirect_uri=""

    if [ -n "$consent_csrf" ]; then
      local grant_headers
      grant_headers=$(curl -sf -b "$cookie_jar" -c "$cookie_jar" \
        -D - -o /dev/null -X POST \
        "${forge_url}/login/oauth/grant" \
        --data-urlencode "_csrf=${consent_csrf}" \
        --data-urlencode "client_id=${form_client_id}" \
        --data-urlencode "state=${form_state}" \
        --data-urlencode "scope=" \
        --data-urlencode "nonce=" \
        --data-urlencode "redirect_uri=${form_redirect_uri}" \
        --data-urlencode "granted=true" \
        2>/dev/null) || grant_headers=""

      redirect_loc=$(printf '%s' "$grant_headers" \
        | grep -i '^location:' | head -1 | tr -d '\r' | awk '{print $2}')

      if printf '%s' "${redirect_loc:-}" | grep -q 'code='; then
        auth_code=$(printf '%s' "$redirect_loc" | sed 's/.*code=\([^&]*\).*/\1/')
      fi
    fi
  fi

  rm -f "$auth_body_file"

  if [ -z "${auth_code:-}" ]; then
    echo "Warning: could not obtain OAuth2 authorization code — skipping token generation" >&2
    rm -f "$cookie_jar"
    return 1
  fi

  # Step 4: Complete Woodpecker OAuth callback (exchanges code for session)
  local state
  state=$(printf '%s' "$wp_redir" | sed -n 's/.*[&?]state=\([^&]*\).*/\1/p')

  local wp_headers wp_token
  wp_headers=$(curl -sf -c "$cookie_jar" \
    -D - -o /dev/null \
    "${wp_server}/authorize?code=${auth_code}&state=${state:-}" \
    2>/dev/null) || wp_headers=""

  # Extract token from redirect URL (Woodpecker returns ?access_token=...)
  redirect_loc=$(printf '%s' "$wp_headers" \
    | grep -i '^location:' | head -1 | tr -d '\r' | awk '{print $2}')

  wp_token=""
  if printf '%s' "${redirect_loc:-}" | grep -q 'access_token='; then
    wp_token=$(printf '%s' "$redirect_loc" | sed 's/.*access_token=\([^&]*\).*/\1/')
  fi

  # Fallback: check for user_sess cookie
  if [ -z "$wp_token" ]; then
    wp_token=$(awk '/user_sess/{print $NF}' "$cookie_jar" 2>/dev/null) || wp_token=""
  fi

  rm -f "$cookie_jar"

  if [ -z "$wp_token" ]; then
    echo "Warning: could not obtain Woodpecker token — skipping token generation" >&2
    return 1
  fi

  # Step 5: Create persistent personal access token via Woodpecker API
  # WP v3 requires CSRF header for POST operations with session tokens.
  local wp_csrf
  wp_csrf=$(curl -sf -b "user_sess=${wp_token}" \
    "${wp_server}/web-config.js" 2>/dev/null \
    | sed -n 's/.*WOODPECKER_CSRF = "\([^"]*\)".*/\1/p') || wp_csrf=""

  local pat_resp final_token
  pat_resp=$(curl -sf -X POST \
    -b "user_sess=${wp_token}" \
    ${wp_csrf:+-H "X-CSRF-Token: ${wp_csrf}"} \
    "${wp_server}/api/user/token" \
    2>/dev/null) || pat_resp=""

  final_token=""
  if [ -n "$pat_resp" ]; then
    final_token=$(printf '%s' "$pat_resp" \
      | jq -r 'if .token then .token elif .access_token then .access_token else empty end' \
      2>/dev/null) || final_token=""
  fi

  # Use persistent token if available, otherwise use session token
  final_token="${final_token:-$wp_token}"

  # Save to .env
  if grep -q '^WOODPECKER_TOKEN=' "$env_file" 2>/dev/null; then
    sed -i "s|^WOODPECKER_TOKEN=.*|WOODPECKER_TOKEN=${final_token}|" "$env_file"
  else
    printf 'WOODPECKER_TOKEN=%s\n' "$final_token" >> "$env_file"
  fi
  export WOODPECKER_TOKEN="$final_token"
  echo "Config:  WOODPECKER_TOKEN generated and saved to .env"
}

# Activate a repo in Woodpecker CI.
# Usage: activate_woodpecker_repo <forge_repo>
_activate_woodpecker_repo_impl() {
  local forge_repo="$1"
  local wp_server="${WOODPECKER_SERVER:-http://localhost:8000}"

  # Wait for Woodpecker to become ready after stack start
  local retries=0
  while [ $retries -lt 10 ]; do
    if curl -sf --max-time 3 "${wp_server}/api/version" >/dev/null 2>&1; then
      break
    fi
    retries=$((retries + 1))
    sleep 2
  done

  if ! curl -sf --max-time 5 "${wp_server}/api/version" >/dev/null 2>&1; then
    echo "Woodpecker: not reachable at ${wp_server} after stack start, skipping repo activation" >&2
    return
  fi

  echo ""
  echo "── Woodpecker repo activation ─────────────────────────"

  local wp_token="${WOODPECKER_TOKEN:-}"
  if [ -z "$wp_token" ]; then
    echo "Warning: WOODPECKER_TOKEN not set — cannot activate repo" >&2
    echo "  Activate manually: woodpecker-cli repo add ${forge_repo}" >&2
    return
  fi

  local wp_repo_id
  wp_repo_id=$(curl -sf \
    -H "Authorization: Bearer ${wp_token}" \
    "${wp_server}/api/repos/lookup/${forge_repo}" 2>/dev/null \
    | jq -r '.id // empty' 2>/dev/null) || true

  if [ -n "$wp_repo_id" ] && [ "$wp_repo_id" != "0" ]; then
    echo "Repo:    ${forge_repo} already active in Woodpecker (id=${wp_repo_id})"
  else
    # Get Forgejo repo numeric ID for WP activation
    local forge_repo_id
    forge_repo_id=$(curl -sf \
      -H "Authorization: token ${FORGE_TOKEN}" \
      "${FORGE_URL:-http://localhost:3000}/api/v1/repos/${forge_repo}" 2>/dev/null \
      | jq -r '.id // empty' 2>/dev/null) || forge_repo_id=""

    local activate_resp
    activate_resp=$(curl -sf -X POST \
      -H "Authorization: Bearer ${wp_token}" \
      "${wp_server}/api/repos?forge_remote_id=${forge_repo_id:-0}" \
      2>/dev/null) || activate_resp=""

    wp_repo_id=$(printf '%s' "$activate_resp" | jq -r '.id // empty' 2>/dev/null) || true

    if [ -n "$wp_repo_id" ] && [ "$wp_repo_id" != "0" ]; then
      echo "Repo:    ${forge_repo} activated in Woodpecker (id=${wp_repo_id})"

      # Set pipeline timeout to 5 minutes (default is 60)
      if curl -sf -X PATCH \
        -H "Authorization: Bearer ${wp_token}" \
        -H "Content-Type: application/json" \
        "${wp_server}/api/repos/${wp_repo_id}" \
        -d '{"timeout": 5}' >/dev/null 2>&1; then
        echo "Config:  pipeline timeout set to 5 minutes"
      fi
    else
      echo "Warning: could not activate repo in Woodpecker" >&2
      echo "  Activate manually: woodpecker-cli repo add ${forge_repo}" >&2
    fi
  fi

  # Store repo ID for later TOML generation
  if [ -n "$wp_repo_id" ] && [ "$wp_repo_id" != "0" ]; then
    _WP_REPO_ID="$wp_repo_id"
  fi
}
