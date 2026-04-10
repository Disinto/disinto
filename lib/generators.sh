#!/usr/bin/env bash
# =============================================================================
# generators — template generation functions for disinto init
#
# Generates docker-compose.yml, Dockerfile, Caddyfile, staging index, and
# deployment pipeline configs.
#
# Globals expected (must be set before sourcing):
#   FACTORY_ROOT   - Root of the disinto factory
#   PROJECT_NAME   - Project name for the project repo (defaults to 'project')
#   PRIMARY_BRANCH - Primary branch name (defaults to 'main')
#
# Usage:
#   source "${FACTORY_ROOT}/lib/generators.sh"
#   generate_compose "$forge_port"
#   generate_caddyfile
#   generate_staging_index
#   generate_deploy_pipelines "$repo_root" "$project_name"
# =============================================================================
set -euo pipefail

# Assert required globals are set
: "${FACTORY_ROOT:?FACTORY_ROOT must be set}"
# PROJECT_NAME defaults to 'project' if not set (env.sh may have set it from FORGE_REPO)
PROJECT_NAME="${PROJECT_NAME:-project}"
# PRIMARY_BRANCH defaults to main (env.sh may have set it to 'master')
PRIMARY_BRANCH="${PRIMARY_BRANCH:-main}"

# Helper: extract woodpecker_repo_id from a project TOML file
# Returns empty string if not found or file doesn't exist
_get_woodpecker_repo_id() {
  local toml_file="$1"
  if [ -f "$toml_file" ]; then
    python3 -c "
import sys, tomllib
try:
    with open(sys.argv[1], 'rb') as f:
        cfg = tomllib.load(f)
    ci = cfg.get('ci', {})
    wp_id = ci.get('woodpecker_repo_id', '0')
    print(wp_id)
except Exception:
    print('0')
" "$toml_file" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

# Find all project TOML files and extract the highest woodpecker_repo_id
# (used for the main agents service which doesn't have a per-project TOML)
_get_primary_woodpecker_repo_id() {
  local projects_dir="${FACTORY_ROOT}/projects"
  local max_id="0"
  for toml in "${projects_dir}"/*.toml; do
    [ -f "$toml" ] || continue
    local repo_id
    repo_id=$(_get_woodpecker_repo_id "$toml")
    if [ -n "$repo_id" ] && [ "$repo_id" != "0" ]; then
      # Use the first non-zero repo_id found (or highest if multiple)
      if [ "$repo_id" -gt "$max_id" ] 2>/dev/null; then
        max_id="$repo_id"
      fi
    fi
  done
  echo "$max_id"
}

# Parse project TOML for local-model agents and emit compose services.
# Writes service definitions to stdout; caller handles insertion into compose file.
_generate_local_model_services() {
  local compose_file="$1"
  local projects_dir="${FACTORY_ROOT}/projects"
  local temp_file
  temp_file=$(mktemp)
  local has_services=false
  local all_vols=""

  # Find all project TOML files and extract [agents.*] sections
  for toml in "${projects_dir}"/*.toml; do
    [ -f "$toml" ] || continue

    # Get woodpecker_repo_id for this project
    local wp_repo_id
    wp_repo_id=$(_get_woodpecker_repo_id "$toml")

    # Parse [agents.*] sections using Python - output YAML-compatible format
    while IFS='=' read -r key value; do
      case "$key" in
        NAME) service_name="$value" ;;
        BASE_URL) base_url="$value" ;;
        MODEL) model="$value" ;;
        ROLES) roles="$value" ;;
        API_KEY) api_key="$value" ;;
        FORGE_USER) forge_user="$value" ;;
        COMPACT_PCT) compact_pct="$value" ;;
        POLL_INTERVAL) poll_interval_val="$value" ;;
        ---)
          if [ -n "$service_name" ] && [ -n "$base_url" ]; then
            cat >> "$temp_file" <<EOF

  agents-${service_name}:
    build:
      context: .
      dockerfile: docker/agents/Dockerfile
    container_name: disinto-agents-${service_name}
    restart: unless-stopped
    security_opt:
      - apparmor=unconfined
    volumes:
      - agents-${service_name}-data:/home/agent/data
      - project-repos:/home/agent/repos
      - \${HOME}/.claude:/home/agent/.claude
      - \${HOME}/.claude.json:/home/agent/.claude.json:ro
      - CLAUDE_BIN_PLACEHOLDER:/usr/local/bin/claude:ro
      - \${HOME}/.ssh:/home/agent/.ssh:ro
    environment:
      FORGE_URL: http://forgejo:3000
      # Use llama-specific credentials if available, otherwise fall back to main FORGE_TOKEN
      FORGE_TOKEN: \${FORGE_TOKEN_LLAMA:-\${FORGE_TOKEN:-}}
      FORGE_PASS: \${FORGE_PASS_LLAMA:-\${FORGE_PASS:-}}
      FORGE_REVIEW_TOKEN: \${FORGE_REVIEW_TOKEN:-}
      FORGE_BOT_USERNAMES: \${FORGE_BOT_USERNAMES:-}
      AGENT_ROLES: "${roles}"
      CLAUDE_TIMEOUT: \${CLAUDE_TIMEOUT:-7200}
      ANTHROPIC_BASE_URL: "${base_url}"
      ANTHROPIC_API_KEY: "${api_key}"
      CLAUDE_MODEL: "${model}"
      CLAUDE_CONFIG_DIR: /home/agent/.claude-${service_name}
      CLAUDE_CREDENTIALS_DIR: /home/agent/.claude-${service_name}/credentials
      CLAUDE_AUTOCOMPACT_PCT_OVERRIDE: "${compact_pct}"
      CLAUDE_CODE_ATTRIBUTION_HEADER: "0"
      CLAUDE_CODE_ENABLE_TELEMETRY: "0"
      DISINTO_CONTAINER: "1"
      PROJECT_REPO_ROOT: /home/agent/repos/${PROJECT_NAME:-project}
      WOODPECKER_DATA_DIR: /woodpecker-data
      WOODPECKER_REPO_ID: "${wp_repo_id}"
      FORGE_BOT_USER_${service_name^^}: "${forge_user}"
      POLL_INTERVAL: "${poll_interval_val}"
    depends_on:
      - forgejo
      - woodpecker
    networks:
      - disinto-net
    profiles: ["agents-${service_name}"]

EOF
            has_services=true
          fi
          # Collect volume name for later
          local vol_name="  agents-${service_name}-data:"
          if [ -n "$all_vols" ]; then
            all_vols="${all_vols}
${vol_name}"
          else
            all_vols="${vol_name}"
          fi
          service_name="" base_url="" model="" roles="" api_key="" forge_user="" compact_pct="" poll_interval_val=""
          ;;
      esac
    done < <(python3 -c '
import sys, tomllib, json, re

with open(sys.argv[1], "rb") as f:
    cfg = tomllib.load(f)

agents = cfg.get("agents", {})
for name, config in agents.items():
    if not isinstance(config, dict):
        continue

    base_url = config.get("base_url", "")
    model = config.get("model", "")
    if not base_url or not model:
        continue

    roles = config.get("roles", ["dev"])
    roles_str = " ".join(roles) if isinstance(roles, list) else roles
    api_key = config.get("api_key", "sk-no-key-required")
    forge_user = config.get("forge_user", f"{name}-bot")
    compact_pct = config.get("compact_pct", 60)
    poll_interval = config.get("poll_interval", 60)

    safe_name = name.lower()
    safe_name = re.sub(r"[^a-z0-9]", "-", safe_name)

    # Output as simple key=value lines
    print(f"NAME={safe_name}")
    print(f"BASE_URL={base_url}")
    print(f"MODEL={model}")
    print(f"ROLES={roles_str}")
    print(f"API_KEY={api_key}")
    print(f"FORGE_USER={forge_user}")
    print(f"COMPACT_PCT={compact_pct}")
    print(f"POLL_INTERVAL={poll_interval}")
    print("---")
' "$toml" 2>/dev/null)
  done

  if [ "$has_services" = true ]; then
    # Insert the services before the volumes section
    local temp_compose
    temp_compose=$(mktemp)
    # Get everything before volumes:
    sed -n '1,/^volumes:/p' "$compose_file" | sed '$d' > "$temp_compose"
    # Add the services
    cat "$temp_file" >> "$temp_compose"
    # Add the volumes section and everything after
    sed -n '/^volumes:/,$p' "$compose_file" >> "$temp_compose"

    # Add local-model volumes to the volumes section
    if [ -n "$all_vols" ]; then
      # Find the volumes section and add the new volumes
      sed -i "/^volumes:/{n;:a;n;/^[a-z]/!{s/$/\n$all_vols/;b};ba}" "$temp_compose"
    fi

    mv "$temp_compose" "$compose_file"
  fi

  rm -f "$temp_file"
}

# Generate docker-compose.yml in the factory root.
# **CANONICAL SOURCE**: This generator is the single source of truth for docker-compose.yml.
# The tracked docker-compose.yml file has been removed. Operators must run 'bin/disinto init'
# to materialize a working stack on a fresh checkout.
_generate_compose_impl() {
  local forge_port="${1:-3000}"
  local compose_file="${FACTORY_ROOT}/docker-compose.yml"

  # Check if compose file already exists
  if [ -f "$compose_file" ]; then
    echo "Compose: ${compose_file} (already exists, skipping)"
    return 0
  fi

  # Extract primary woodpecker_repo_id from project TOML files
  local wp_repo_id
  wp_repo_id=$(_get_primary_woodpecker_repo_id)

  cat > "$compose_file" <<'COMPOSEEOF'
# docker-compose.yml — generated by disinto init
# Brings up Forgejo, Woodpecker, and the agent runtime.

services:
  forgejo:
    image: codeberg.org/forgejo/forgejo:11.0
    container_name: disinto-forgejo
    restart: unless-stopped
    security_opt:
      - apparmor=unconfined
    volumes:
      - forgejo-data:/data
    environment:
      FORGEJO__database__DB_TYPE: sqlite3
      FORGEJO__server__ROOT_URL: http://forgejo:3000/
      FORGEJO__server__HTTP_PORT: "3000"
      FORGEJO__security__INSTALL_LOCK: "true"
      FORGEJO__service__DISABLE_REGISTRATION: "true"
      FORGEJO__webhook__ALLOWED_HOST_LIST: "private"
    networks:
      - disinto-net

  woodpecker:
    image: woodpeckerci/woodpecker-server:v3
    container_name: disinto-woodpecker
    restart: unless-stopped
    security_opt:
      - apparmor=unconfined
    ports:
      - "8000:8000"
      - "9000:9000"
    volumes:
      - woodpecker-data:/var/lib/woodpecker
    environment:
      WOODPECKER_FORGEJO: "true"
      WOODPECKER_FORGEJO_URL: http://forgejo:3000
      WOODPECKER_FORGEJO_CLIENT: ${WP_FORGEJO_CLIENT:-}
      WOODPECKER_FORGEJO_SECRET: ${WP_FORGEJO_SECRET:-}
      WOODPECKER_HOST: ${WOODPECKER_HOST:-http://woodpecker:8000}
      WOODPECKER_OPEN: "true"
      WOODPECKER_AGENT_SECRET: ${WOODPECKER_AGENT_SECRET:-}
      WOODPECKER_DATABASE_DRIVER: sqlite3
      WOODPECKER_DATABASE_DATASOURCE: /var/lib/woodpecker/woodpecker.sqlite
      WOODPECKER_ENVIRONMENT: "FORGE_TOKEN:${FORGE_TOKEN}"
    depends_on:
      - forgejo
    networks:
      - disinto-net

  woodpecker-agent:
    image: woodpeckerci/woodpecker-agent:v3
    container_name: disinto-woodpecker-agent
    restart: unless-stopped
    network_mode: host
    privileged: true
    security_opt:
      - apparmor=unconfined
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      WOODPECKER_SERVER: localhost:9000
      WOODPECKER_AGENT_SECRET: ${WOODPECKER_AGENT_SECRET:-}
      WOODPECKER_GRPC_SECURE: "false"
      WOODPECKER_HEALTHCHECK_ADDR: ":3333"
      WOODPECKER_BACKEND_DOCKER_NETWORK: disinto_disinto-net
      WOODPECKER_MAX_WORKFLOWS: 1
    depends_on:
      - woodpecker

  agents:
    build:
      context: .
      dockerfile: docker/agents/Dockerfile
    container_name: disinto-agents
    restart: unless-stopped
    security_opt:
      - apparmor=unconfined
    volumes:
      - agent-data:/home/agent/data
      - project-repos:/home/agent/repos
      - ${HOME}/.claude:/home/agent/.claude
      - ${HOME}/.claude.json:/home/agent/.claude.json:ro
      - CLAUDE_BIN_PLACEHOLDER:/usr/local/bin/claude:ro
      - ${HOME}/.ssh:/home/agent/.ssh:ro
      - ${HOME}/.config/sops/age:/home/agent/.config/sops/age:ro
      - woodpecker-data:/woodpecker-data:ro
    environment:
      FORGE_URL: http://forgejo:3000
      FORGE_TOKEN: ${FORGE_TOKEN:-}
      FORGE_REVIEW_TOKEN: ${FORGE_REVIEW_TOKEN:-}
      FORGE_PLANNER_TOKEN: ${FORGE_PLANNER_TOKEN:-}
      FORGE_GARDENER_TOKEN: ${FORGE_GARDENER_TOKEN:-}
      FORGE_VAULT_TOKEN: ${FORGE_VAULT_TOKEN:-}
      FORGE_SUPERVISOR_TOKEN: ${FORGE_SUPERVISOR_TOKEN:-}
      FORGE_PREDICTOR_TOKEN: ${FORGE_PREDICTOR_TOKEN:-}
      FORGE_ARCHITECT_TOKEN: ${FORGE_ARCHITECT_TOKEN:-}
      FORGE_BOT_USERNAMES: ${FORGE_BOT_USERNAMES:-}
      WOODPECKER_TOKEN: ${WOODPECKER_TOKEN:-}
      CLAUDE_TIMEOUT: ${CLAUDE_TIMEOUT:-7200}
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: ${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-1}
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY:-}
      FORGE_PASS: ${FORGE_PASS:-}
      FORGE_ADMIN_PASS: ${FORGE_ADMIN_PASS:-}
      FACTORY_REPO: ${FORGE_REPO:-disinto-admin/disinto}
      DISINTO_CONTAINER: "1"
      PROJECT_REPO_ROOT: /home/agent/repos/${PROJECT_NAME:-project}
      WOODPECKER_DATA_DIR: /woodpecker-data
      WOODPECKER_REPO_ID: "PLACEHOLDER_WP_REPO_ID"
    # IMPORTANT: agents get explicit environment variables (forge tokens, CI tokens, config).
    # Vault-only secrets (GITHUB_TOKEN, CLAWHUB_TOKEN, deploy keys) live in
    # .env.vault.enc and are NEVER injected here — only the runner
    # container receives them at fire time (AD-006, #745).
    depends_on:
      - forgejo
      - woodpecker
    networks:
      - disinto-net

  runner:
    build:
      context: .
      dockerfile: docker/agents/Dockerfile
    profiles: ["vault"]
    security_opt:
      - apparmor=unconfined
    volumes:
      - agent-data:/home/agent/data
    environment:
      FORGE_URL: http://forgejo:3000
      DISINTO_CONTAINER: "1"
      PROJECT_REPO_ROOT: /home/agent/repos/${PROJECT_NAME:-project}
    # Vault redesign in progress (PR-based approval, see #73-#77)
    # This container is being replaced — entrypoint will be updated in follow-up
    networks:
      - disinto-net

  # Edge proxy — reverse proxy to Forgejo, Woodpecker, and staging
  # Serves on ports 80/443, routes based on path
  edge:
    build: ./docker/edge
    container_name: disinto-edge
    security_opt:
      - apparmor=unconfined
    ports:
      - "80:80"
      - "443:443"
    environment:
      - DISINTO_VERSION=${DISINTO_VERSION:-main}
      - FORGE_URL=http://forgejo:3000
      - FORGE_REPO=${FORGE_REPO:-disinto-admin/disinto}
      - FORGE_OPS_REPO=${FORGE_OPS_REPO:-disinto-admin/disinto-ops}
      - FORGE_TOKEN=${FORGE_TOKEN:-}
      - FORGE_ADMIN_USERS=${FORGE_ADMIN_USERS:-disinto-admin}
      - FORGE_ADMIN_TOKEN=${FORGE_ADMIN_TOKEN:-}
      - OPS_REPO_ROOT=/opt/disinto-ops
      - PROJECT_REPO_ROOT=/opt/disinto
      - PRIMARY_BRANCH=main
    volumes:
      - ./docker/Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
      - /var/run/docker.sock:/var/run/docker.sock
    depends_on:
      - forgejo
      - woodpecker
      - staging
    networks:
      - disinto-net

  # Staging container — static file server for staging artifacts
  # Edge proxy routes to this container for default requests
  staging:
    image: caddy:alpine
    command: ["caddy", "file-server", "--root", "/srv/site"]
    security_opt:
      - apparmor=unconfined
    volumes:
      - ./docker:/srv/site:ro
    networks:
      - disinto-net

  # Staging deployment slot — activated by Woodpecker staging pipeline (#755).
  # Profile-gated: only starts when explicitly targeted by deploy commands.
  # Customize image/ports/volumes for your project after init.
  staging-deploy:
    image: alpine:3
    profiles: ["staging"]
    security_opt:
      - apparmor=unconfined
    environment:
      DEPLOY_ENV: staging
    networks:
      - disinto-net
    command: ["echo", "staging slot — replace with project image"]

volumes:
  forgejo-data:
  woodpecker-data:
  agent-data:
  project-repos:
  caddy_data:

networks:
  disinto-net:
    driver: bridge
COMPOSEEOF

  # Patch PROJECT_REPO_ROOT — interpolate PROJECT_NAME at generation time
  # (Docker Compose cannot resolve it; it's a shell variable, not a .env var)
  sed -i "s|\${PROJECT_NAME:-project}|${PROJECT_NAME}|g" "$compose_file"

  # Patch WOODPECKER_REPO_ID — interpolate at generation time
  # (Docker Compose cannot resolve it; it's a shell variable, not a .env var)
  if [ -n "$wp_repo_id" ] && [ "$wp_repo_id" != "0" ]; then
    sed -i "s|PLACEHOLDER_WP_REPO_ID|${wp_repo_id}|g" "$compose_file"
  else
    # Default to empty if no repo_id found (agents will handle gracefully)
    sed -i "s|PLACEHOLDER_WP_REPO_ID||g" "$compose_file"
  fi

  # Patch the forgejo port mapping into the file if non-default
  if [ "$forge_port" != "3000" ]; then
    # Add port mapping to forgejo service so it's reachable from host during init
    sed -i "/image: codeberg\.org\/forgejo\/forgejo:11\.0/a\\    ports:\\n      - \"${forge_port}:3000\"" "$compose_file"
  else
    sed -i "/image: codeberg\.org\/forgejo\/forgejo:11\.0/a\\    ports:\\n      - \"3000:3000\"" "$compose_file"
  fi

  # Append local-model agent services if any are configured
  # (must run before CLAUDE_BIN_PLACEHOLDER substitution so the placeholder
  # in local-model services is also resolved)
  _generate_local_model_services "$compose_file"

  # Patch the Claude CLI binary path — resolve from host PATH at init time.
  local claude_bin
  claude_bin="$(command -v claude 2>/dev/null || true)"
  if [ -n "$claude_bin" ]; then
    # Resolve symlinks to get the real binary path
    claude_bin="$(readlink -f "$claude_bin")"
    sed -i "s|CLAUDE_BIN_PLACEHOLDER|${claude_bin}|g" "$compose_file"
  else
    echo "Warning: claude CLI not found in PATH — update docker-compose.yml volumes manually" >&2
    sed -i "s|CLAUDE_BIN_PLACEHOLDER|/usr/local/bin/claude|g" "$compose_file"
  fi

  echo "Created: ${compose_file}"
}

# Generate docker/agents/ files if they don't already exist.
_generate_agent_docker_impl() {
  local docker_dir="${FACTORY_ROOT}/docker/agents"
  mkdir -p "$docker_dir"

  if [ ! -f "${docker_dir}/Dockerfile" ]; then
    echo "Warning: docker/agents/Dockerfile not found — expected in repo" >&2
  fi
  if [ ! -f "${docker_dir}/entrypoint.sh" ]; then
    echo "Warning: docker/agents/entrypoint.sh not found — expected in repo" >&2
  fi
}

# Generate docker/Caddyfile template for edge proxy.
_generate_caddyfile_impl() {
  local docker_dir="${FACTORY_ROOT}/docker"
  local caddyfile="${docker_dir}/Caddyfile"

  if [ -f "$caddyfile" ]; then
    echo "Caddyfile:  ${caddyfile} (already exists, skipping)"
    return
  fi

  cat > "$caddyfile" <<'CADDYFILEEOF'
# Caddyfile — edge proxy configuration
# IP-only binding at bootstrap; domain + TLS added later via vault resource request

:80 {
    # Reverse proxy to Forgejo
    handle /forgejo/* {
        reverse_proxy forgejo:3000
    }

    # Reverse proxy to Woodpecker CI
    handle /ci/* {
        reverse_proxy woodpecker:8000
    }

    # Default: proxy to staging container
    handle {
        reverse_proxy staging:80
    }
}
CADDYFILEEOF

  echo "Created: ${caddyfile}"
}

# Generate docker/index.html default page.
_generate_staging_index_impl() {
  local docker_dir="${FACTORY_ROOT}/docker"
  local index_file="${docker_dir}/index.html"

  if [ -f "$index_file" ]; then
    echo "Staging:  ${index_file} (already exists, skipping)"
    return
  fi

  cat > "$index_file" <<'INDEXEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Nothing shipped yet</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
            display: flex;
            align-items: center;
            justify-content: center;
            min-height: 100vh;
            margin: 0;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
        }
        .container {
            text-align: center;
            padding: 2rem;
        }
        h1 {
            font-size: 3rem;
            margin: 0 0 1rem 0;
        }
        p {
            font-size: 1.25rem;
            opacity: 0.9;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Nothing shipped yet</h1>
        <p>CI pipelines will update this page with your staging artifacts.</p>
    </div>
</body>
</html>
INDEXEOF

  echo "Created: ${index_file}"
}

# Generate template .woodpecker/ deployment pipeline configs in a project repo.
# Creates staging.yml and production.yml alongside the project's existing CI config.
# These pipelines trigger on Woodpecker's deployment event with environment filters.
_generate_deploy_pipelines_impl() {
  local repo_root="$1"
  local project_name="$2"
  : "${project_name// /}"  # Silence SC2034 - variable used in heredoc
  local wp_dir="${repo_root}/.woodpecker"

  mkdir -p "$wp_dir"

  # Skip if deploy pipelines already exist
  if [ -f "${wp_dir}/staging.yml" ] && [ -f "${wp_dir}/production.yml" ]; then
    echo "Deploy:  .woodpecker/{staging,production}.yml (already exist)"
    return
  fi

  if [ ! -f "${wp_dir}/staging.yml" ]; then
    cat > "${wp_dir}/staging.yml" <<'STAGINGEOF'
# .woodpecker/staging.yml — Staging deployment pipeline
# Triggered by runner via Woodpecker promote API.
# Human approves promotion in vault → runner calls promote → this runs.

when:
  event: deployment
  environment: staging

steps:
  - name: deploy-staging
    image: docker:27
    commands:
      - echo "Deploying to staging environment..."
      - echo "Pipeline ${CI_PIPELINE_NUMBER} promoted from CI #${CI_PIPELINE_PARENT}"
      # Pull the image built by CI and deploy to staging
      # Customize these commands for your project:
      # - docker compose -f docker-compose.yml --profile staging up -d
      - echo "Staging deployment complete"

  - name: verify-staging
    image: alpine:3
    commands:
      - echo "Verifying staging deployment..."
      # Add health checks, smoke tests, or integration tests here:
      # - curl -sf http://staging:8080/health || exit 1
      - echo "Staging verification complete"
STAGINGEOF
    echo "Created: ${wp_dir}/staging.yml"
  fi

  if [ ! -f "${wp_dir}/production.yml" ]; then
    cat > "${wp_dir}/production.yml" <<'PRODUCTIONEOF'
# .woodpecker/production.yml — Production deployment pipeline
# Triggered by runner via Woodpecker promote API.
# Human approves promotion in vault → runner calls promote → this runs.

when:
  event: deployment
  environment: production

steps:
  - name: deploy-production
    image: docker:27
    commands:
      - echo "Deploying to production environment..."
      - echo "Pipeline ${CI_PIPELINE_NUMBER} promoted from staging"
      # Pull the verified image and deploy to production
      # Customize these commands for your project:
      # - docker compose -f docker-compose.yml up -d
      - echo "Production deployment complete"

  - name: verify-production
    image: alpine:3
    commands:
      - echo "Verifying production deployment..."
      # Add production health checks here:
      # - curl -sf http://production:8080/health || exit 1
      - echo "Production verification complete"
PRODUCTIONEOF
    echo "Created: ${wp_dir}/production.yml"
  fi
}
