#!/usr/bin/env bash
# ops-setup.sh — Setup ops repository (disinto-ops)
#
# Source from bin/disinto:
#   source "$(dirname "$0")/../lib/ops-setup.sh"
#
# Required globals: FORGE_URL, FORGE_TOKEN, FACTORY_ROOT
# Optional: HUMAN_TOKEN (falls back to FORGE_TOKEN for admin operations)
#
# Functions:
#   setup_ops_repo <forge_url> <ops_slug> <ops_root> [primary_branch] [admin_token]
#     - Create ops repo on Forgejo if it doesn't exist
#     - Configure bot collaborators with appropriate permissions
#     - Clone or initialize ops repo locally
#     - Seed directory structure (vault, knowledge, evidence)
#     - Export _ACTUAL_OPS_SLUG for caller to use
#   migrate_ops_repo <ops_root> [primary_branch]
#     - Seed missing directories/files on existing ops repos (idempotent)
#     - Creates .gitkeep files and template content for canonical structure
#
# Globals modified:
#   _ACTUAL_OPS_SLUG - resolved ops repo slug after setup_ops_repo completes

set -euo pipefail

setup_ops_repo() {

  local forge_url="$1" ops_slug="$2" ops_root="$3" primary_branch="${4:-main}"
  local admin_token="${5:-${HUMAN_TOKEN:-${FORGE_TOKEN}}}"
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

    # Determine if target namespace is a user or an org
    local ns_type=""
    if curl -sf -H "Authorization: token ${admin_token}" \
      "${forge_url}/api/v1/users/${org_name}" >/dev/null 2>&1; then
      # User endpoint exists - check if it's an org
      if curl -sf -H "Authorization: token ${admin_token}" \
        "${forge_url}/api/v1/users/${org_name}" | grep -q '"is_org":true'; then
        ns_type="org"
      else
        ns_type="user"
      fi
    elif curl -sf -H "Authorization: token ${admin_token}" \
      "${forge_url}/api/v1/orgs/${org_name}" >/dev/null 2>&1; then
      # Org endpoint exists
      ns_type="org"
    fi

    local create_endpoint="" via_msg=""
    if [ "$ns_type" = "org" ]; then
      # Org namespace — use org API
      create_endpoint="/api/v1/orgs/${org_name}/repos"
      # Create org if it doesn't exist
      curl -sf -X POST \
        -H "Authorization: token ${admin_token}" \
        -H "Content-Type: application/json" \
        "${forge_url}/api/v1/orgs" \
        -d "{\"username\":\"${org_name}\",\"visibility\":\"public\"}" >/dev/null 2>&1 || true
    else
      # User namespace — use admin API (requires admin token)
      create_endpoint="/api/v1/admin/users/${org_name}/repos"
      via_msg=" (via admin API)"
    fi

    if curl -sf -X POST \
      -H "Authorization: token ${admin_token}" \
      -H "Content-Type: application/json" \
      "${forge_url}${create_endpoint}" \
      -d "{\"name\":\"${ops_name}\",\"auto_init\":true,\"default_branch\":\"${primary_branch}\",\"description\":\"Operational data for ${org_name}/${ops_name%-ops}\"}" >/dev/null 2>&1; then
      actual_ops_slug="${org_name}/${ops_name}"
      echo "Ops repo: ${actual_ops_slug} created on Forgejo${via_msg}"
    else
      http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Authorization: token ${admin_token}" \
        -H "Content-Type: application/json" \
        "${forge_url}${create_endpoint}" \
        -d "{\"name\":\"${ops_name}\",\"auto_init\":true,\"default_branch\":\"${primary_branch}\",\"description\":\"Operational data for ${org_name}/${ops_name%-ops}\"}" 2>/dev/null || echo "0")
      if [ "$http_code" = "201" ]; then
        actual_ops_slug="${org_name}/${ops_name}"
        echo "Ops repo: ${actual_ops_slug} created on Forgejo${via_msg}"
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
    [supervisor-bot]="write"
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
      -H "Authorization: token ${admin_token}" \
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
    -H "Authorization: token ${admin_token}" \
    -H "Content-Type: application/json" \
    "${forge_url}/api/v1/repos/${actual_ops_slug}/collaborators/disinto-admin" \
    -d '{"permission":"admin"}' >/dev/null 2>&1; then
    echo "  + disinto-admin = admin collaborator"
  else
    echo "  ! disinto-admin = admin (already set or failed)"
  fi

  # Clone ops repo locally if not present — use clean URL, credential helper
  # supplies auth (#604).
  if [ ! -d "${ops_root}/.git" ]; then
    local clone_url="${forge_url}/${actual_ops_slug}.git"
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
  mkdir -p "${ops_root}/evidence/red-team"
  mkdir -p "${ops_root}/evidence/holdout"
  mkdir -p "${ops_root}/evidence/evolution"
  mkdir -p "${ops_root}/evidence/user-test"
  mkdir -p "${ops_root}/sprints"
  [ -f "${ops_root}/sprints/.gitkeep" ] || { touch "${ops_root}/sprints/.gitkeep"; seeded=true; }
  [ -f "${ops_root}/evidence/red-team/.gitkeep" ] || { touch "${ops_root}/evidence/red-team/.gitkeep"; seeded=true; }
  [ -f "${ops_root}/evidence/holdout/.gitkeep" ] || { touch "${ops_root}/evidence/holdout/.gitkeep"; seeded=true; }
  [ -f "${ops_root}/evidence/evolution/.gitkeep" ] || { touch "${ops_root}/evidence/evolution/.gitkeep"; seeded=true; }
  [ -f "${ops_root}/evidence/user-test/.gitkeep" ] || { touch "${ops_root}/evidence/user-test/.gitkeep"; seeded=true; }
  [ -f "${ops_root}/knowledge/.gitkeep" ] || { touch "${ops_root}/knowledge/.gitkeep"; seeded=true; }

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
├── sprints/              # sprint specs written by architect agent
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

  # Copy vault policy.toml template if not already present
  if [ ! -f "${ops_root}/vault/policy.toml" ]; then
    local policy_src="${FACTORY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/vault/policy.toml"
    if [ -f "$policy_src" ]; then
      cp "$policy_src" "${ops_root}/vault/policy.toml"
      echo "  + Copied vault/policy.toml template"
      seeded=true
    fi
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

# migrate_ops_repo — Seed missing ops repo directories and files on existing deployments
#
# This function is idempotent — safe to run on every container start.
# It checks for missing directories/files and creates them with .gitkeep files
# or template content as appropriate.
#
# Called from entrypoint.sh after setup_ops_repo() to bring pre-#407 deployments
# up to date with the canonical ops repo structure.
migrate_ops_repo() {
  local ops_root="${1:-}"
  local primary_branch="${2:-main}"

  # Validate ops_root argument
  if [ -z "$ops_root" ]; then
    # Try to determine ops_root from environment or project config
    if [ -n "${OPS_REPO_ROOT:-}" ]; then
      ops_root="${OPS_REPO_ROOT}"
    elif [ -n "${PROJECT_TOML:-}" ] && [ -f "$PROJECT_TOML" ]; then
      source "$(dirname "$0")/load-project.sh" "$PROJECT_TOML"
      ops_root="${OPS_REPO_ROOT:-}"
    fi
  fi

  # Skip if we still don't have an ops root
  if [ -z "$ops_root" ]; then
    echo "migrate_ops_repo: skipping — no ops repo root determined"
    return 0
  fi

  # Verify it's a git repo
  if [ ! -d "${ops_root}/.git" ]; then
    echo "migrate_ops_repo: skipping — ${ops_root} is not a git repo"
    return 0
  fi

  echo ""
  echo "── Ops repo migration ───────────────────────────────────"
  echo "Checking ${ops_root} for missing directories and files..."

  # Change to ops_root directory to ensure all git operations use the correct repo
  # This prevents "fatal: not in a git directory" errors from stray git commands
  local orig_dir
  orig_dir=$(pwd)
  cd "$ops_root" || {
    echo "Error: failed to change to ${ops_root}" >&2
    return 1
  }

  local migrated=false

  # Canonical ops repo structure (post #407)
  # Directories to ensure exist with .gitkeep files
  local -a dir_keepfiles=(
    "vault/pending/.gitkeep"
    "vault/approved/.gitkeep"
    "vault/fired/.gitkeep"
    "vault/rejected/.gitkeep"
    "knowledge/.gitkeep"
    "evidence/engagement/.gitkeep"
    "evidence/red-team/.gitkeep"
    "evidence/holdout/.gitkeep"
    "evidence/evolution/.gitkeep"
    "evidence/user-test/.gitkeep"
    "sprints/.gitkeep"
  )

  # Create missing directories and .gitkeep files
  for keepfile in "${dir_keepfiles[@]}"; do
    if [ ! -f "$keepfile" ]; then
      mkdir -p "$(dirname "$keepfile")"
      touch "$keepfile"
      echo "  + Created: ${keepfile}"
      migrated=true
    fi
  done

  # Template files to create if missing (starter content)
  local -a template_files=(
    "portfolio.md"
    "prerequisites.md"
    "RESOURCES.md"
  )

  for tfile in "${template_files[@]}"; do
    if [ ! -f "$tfile" ]; then
      local title
      title=$(basename "$tfile" | sed 's/\.md$//; s/_/ /g' | sed 's/\b\(.\)/\u\1/g')
      case "$tfile" in
        portfolio.md)
          {
            echo "# ${title}"
            echo ""
            echo "## Addressables"
            echo ""
            echo "<!-- Add addressables here -->"
            echo ""
            echo "## Observables"
            echo ""
            echo "<!-- Add observables here -->"
          } > "$tfile"
          ;;
        RESOURCES.md)
          {
            echo "# ${title}"
            echo ""
            echo "## Accounts"
            echo ""
            echo "<!-- Add account references here -->"
            echo ""
            echo "## Tokens"
            echo ""
            echo "<!-- Add token references here -->"
            echo ""
            echo "## Infrastructure"
            echo ""
            echo "<!-- Add infrastructure inventory here -->"
          } > "$tfile"
          ;;
        prerequisites.md)
          {
            echo "# ${title}"
            echo ""
            echo "<!-- Add dependency graph here -->"
          } > "$tfile"
          ;;
        *)
          {
            echo "# ${title}"
            echo ""
            echo "## Overview"
            echo ""
            echo "<!-- Add content here -->"
          } > "$tfile"
          ;;
      esac
      echo "  + Created: ${tfile}"
      migrated=true
    fi
  done

  # Commit and push changes if any were made
  if [ "$migrated" = true ]; then
    # Auto-configure repo-local git identity if missing
    if [ -z "$(git config user.name 2>/dev/null)" ]; then
      git config user.name "disinto-admin"
    fi
    if [ -z "$(git config user.email 2>/dev/null)" ]; then
      git config user.email "disinto-admin@localhost"
    fi

    git add -A
    if ! git diff --cached --quiet 2>/dev/null; then
      if ! git commit -m "chore: migrate ops repo structure to canonical layout" -q; then
        echo "Error: failed to commit migration changes" >&2
        cd "$orig_dir"
        return 1
      fi
      # Push if remote exists
      if git remote get-url origin >/dev/null 2>&1; then
        if ! git push origin "${primary_branch}" -q 2>/dev/null; then
          echo "Warning: failed to push migration to ops repo" >&2
        else
          echo "Migrated:  ops repo structure updated and pushed"
        fi
      fi
    fi
  else
    echo "  (all directories and files already present)"
  fi

  # Return to original directory
  cd "$orig_dir"
}
