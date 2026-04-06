#!/usr/bin/env bash
# ops-setup.sh — Setup ops repository (disinto-ops)
#
# Source from bin/disinto:
#   source "$(dirname "$0")/../lib/ops-setup.sh"
#
# Required globals: FORGE_URL, FORGE_TOKEN, FACTORY_ROOT
# Optional: admin_token (falls back to FORGE_TOKEN for admin operations)
#
# Functions:
#   setup_ops_repo <forge_url> <ops_slug> <ops_root> [primary_branch]
#     - Create ops repo on Forgejo if it doesn't exist
#     - Configure bot collaborators with appropriate permissions
#     - Clone or initialize ops repo locally
#     - Seed directory structure (vault, knowledge, evidence)
#     - Export _ACTUAL_OPS_SLUG for caller to use
#
# Globals modified:
#   _ACTUAL_OPS_SLUG - resolved ops repo slug after function completes

set -euo pipefail

setup_ops_repo() {

  local forge_url="$1" ops_slug="$2" ops_root="$3" primary_branch="${4:-main}"
  local org_name="${ops_slug%%/*}"
  local ops_name="${ops_slug##*/}"

  echo ""
  echo "── Ops repo setup ─────────────────────────────────────"

  # Determine the actual ops repo location by searching across possible namespaces
  # This handles cases where the repo was created under a different namespace
  # due to past bugs (e.g., dev-bot/disinto-ops instead of disinto-admin/disinto-ops)
  local actual_ops_slug=""
  local -a possible_namespaces=( "$org_name" "dev-bot" "disinto-admin" )
  local http_code

  for ns in "${possible_namespaces[@]}"; do
    slug="${ns}/${ops_name}"
    if curl -sf --max-time 5 \
      -H "Authorization: token ${FORGE_TOKEN}" \
      "${forge_url}/api/v1/repos/${slug}" >/dev/null 2>&1; then
      actual_ops_slug="$slug"
      echo "Ops repo: ${slug} (found at ${slug})"
      break
    fi
  done

  # If not found, try to create it in the configured namespace
  if [ -z "$actual_ops_slug" ]; then
    echo "Creating ops repo in namespace: ${org_name}"
    # Create org if it doesn't exist
    curl -sf -X POST \
      -H "Authorization: token ${admin_token:-${FORGE_TOKEN}}" \
      -H "Content-Type: application/json" \
      "${forge_url}/api/v1/orgs" \
      -d "{\"username\":\"${org_name}\",\"visibility\":\"public\"}" >/dev/null 2>&1 || true
    if curl -sf -X POST \
      -H "Authorization: token ${admin_token:-${FORGE_TOKEN}}" \
      -H "Content-Type: application/json" \
      "${forge_url}/api/v1/orgs/${org_name}/repos" \
      -d "{\"name\":\"${ops_name}\",\"auto_init\":true,\"default_branch\":\"${primary_branch}\",\"description\":\"Operational data for ${org_name}/${ops_name%-ops}\"}" >/dev/null 2>&1; then
      actual_ops_slug="${org_name}/${ops_name}"
      echo "Ops repo: ${actual_ops_slug} created on Forgejo"
    else
      # Fallback: use admin API to create repo under the target namespace
      http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Authorization: token ${admin_token:-${FORGE_TOKEN}}" \
        -H "Content-Type: application/json" \
        "${forge_url}/api/v1/admin/users/${org_name}/repos" \
        -d "{\"name\":\"${ops_name}\",\"auto_init\":true,\"default_branch\":\"${primary_branch}\",\"description\":\"Operational data for ${org_name}/${ops_name%-ops}\"}" 2>/dev/null || echo "0")
      if [ "$http_code" = "201" ]; then
        actual_ops_slug="${org_name}/${ops_name}"
        echo "Ops repo: ${actual_ops_slug} created on Forgejo (via admin API)"
      else
        echo "Error: failed to create ops repo '${org_name}/${ops_name}' (HTTP ${http_code})" >&2
        return 1
      fi
    fi
  fi

  # Configure collaborators on the ops repo
  local bot_user bot_perm
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

  # Add all bot users as collaborators with appropriate permissions
  # vault branch protection (#77) requires:
  # - Admin-only merge to main (enforced by admin_enforced: true)
  # - Bots can push branches and create PRs, but cannot merge
  for bot_user in "${!bot_permissions[@]}"; do
    bot_perm="${bot_permissions[$bot_user]}"
    if curl -sf -X PUT \
      -H "Authorization: token ${admin_token:-${FORGE_TOKEN}}" \
      -H "Content-Type: application/json" \
      "${forge_url}/api/v1/repos/${actual_ops_slug}/collaborators/${bot_user}" \
      -d "{\"permission\":\"${bot_perm}\"}" >/dev/null 2>&1; then
      echo "  + ${bot_user} = ${bot_perm} collaborator"
    else
      echo "  ! ${bot_user} = ${bot_perm} (already set or failed)"
    fi
  done

  # Add disinto-admin as admin collaborator
  if curl -sf -X PUT \
    -H "Authorization: token ${admin_token:-${FORGE_TOKEN}}" \
    -H "Content-Type: application/json" \
    "${forge_url}/api/v1/repos/${actual_ops_slug}/collaborators/disinto-admin" \
    -d '{"permission":"admin"}' >/dev/null 2>&1; then
    echo "  + disinto-admin = admin collaborator"
  else
    echo "  ! disinto-admin = admin (already set or failed)"
  fi

  # Clone ops repo locally if not present
  if [ ! -d "${ops_root}/.git" ]; then
    local auth_url
    auth_url=$(printf '%s' "$forge_url" | sed "s|://|://dev-bot:${FORGE_TOKEN}@|")
    local clone_url="${auth_url}/${actual_ops_slug}.git"
    echo "Cloning: ops repo -> ${ops_root}"
    if git clone --quiet "$clone_url" "$ops_root" 2>/dev/null; then
      echo "Ops repo: ${actual_ops_slug} cloned successfully"
    else
      echo "Initializing: ops repo at ${ops_root}"
      mkdir -p "$ops_root"
      git -C "$ops_root" init --initial-branch="${primary_branch}" -q
      # Set remote to the actual ops repo location
      git -C "$ops_root" remote add origin "${forge_url}/${actual_ops_slug}.git"
      echo "Ops repo: ${actual_ops_slug} initialized locally"
    fi
  else
    echo "Ops repo: ${ops_root} (already exists locally)"
    # Verify remote is correct
    local current_remote
    current_remote=$(git -C "$ops_root" remote get-url origin 2>/dev/null || true)
    local expected_remote="${forge_url}/${actual_ops_slug}.git"
    if [ -n "$current_remote" ] && [ "$current_remote" != "$expected_remote" ]; then
      echo "  Fixing: remote URL from ${current_remote} to ${expected_remote}"
      git -C "$ops_root" remote set-url origin "$expected_remote"
    fi
  fi

  # Seed directory structure
  local seeded=false
  mkdir -p "${ops_root}/vault/pending"
  mkdir -p "${ops_root}/vault/approved"
  mkdir -p "${ops_root}/vault/fired"
  mkdir -p "${ops_root}/vault/rejected"
  mkdir -p "${ops_root}/knowledge"
  mkdir -p "${ops_root}/evidence/engagement"

  if [ ! -f "${ops_root}/README.md" ]; then
    cat > "${ops_root}/README.md" <<OPSEOF
# ${ops_name}

Operational data for the ${ops_name%-ops} project.

## Structure

\`\`\`
${ops_name}/
├── vault/
│   ├── pending/          # vault items awaiting approval
│   ├── approved/         # approved vault items
│   ├── fired/            # executed vault items
│   └── rejected/         # rejected vault items
├── knowledge/            # shared agent knowledge and best practices
├── evidence/             # engagement data, experiment results
├── portfolio.md          # addressables + observables
├── prerequisites.md      # dependency graph
└── RESOURCES.md          # accounts, tokens (refs), infra inventory
\`\`\`

> **Note:** Journal directories (journal/planner/ and journal/supervisor/) have been removed from the ops repo. Agent journals are now stored in each agent's .profile repo on Forgejo.

## Branch protection

- \`main\`: 2 reviewers required for vault items
- Journal/evidence commits may use lighter rules
OPSEOF
    seeded=true
  fi

  # Create stub files if they don't exist
  [ -f "${ops_root}/portfolio.md" ] || { echo "# Portfolio" > "${ops_root}/portfolio.md"; seeded=true; }
  [ -f "${ops_root}/prerequisites.md" ] || { echo "# Prerequisite Tree" > "${ops_root}/prerequisites.md"; seeded=true; }
  [ -f "${ops_root}/RESOURCES.md" ] || { echo "# Resources" > "${ops_root}/RESOURCES.md"; seeded=true; }

  # Commit and push seed content
  if [ "$seeded" = true ] && [ -d "${ops_root}/.git" ]; then
    # Auto-configure repo-local git identity if missing (#778)
    if [ -z "$(git -C "$ops_root" config user.name 2>/dev/null)" ]; then
      git -C "$ops_root" config user.name "disinto-admin"
    fi
    if [ -z "$(git -C "$ops_root" config user.email 2>/dev/null)" ]; then
      git -C "$ops_root" config user.email "disinto-admin@localhost"
    fi

    git -C "$ops_root" add -A
    if ! git -C "$ops_root" diff --cached --quiet 2>/dev/null; then
      git -C "$ops_root" commit -m "chore: seed ops repo structure" -q
      # Push if remote exists
      if git -C "$ops_root" remote get-url origin >/dev/null 2>&1; then
        if git -C "$ops_root" push origin "${primary_branch}" -q 2>/dev/null; then
          echo "Seeded:  ops repo with initial structure"
        else
          echo "Warning: failed to push seed content to ops repo" >&2
        fi
      fi
    fi
  fi

  # Export resolved slug for the caller to write back to the project TOML
  _ACTUAL_OPS_SLUG="${actual_ops_slug}"
}
