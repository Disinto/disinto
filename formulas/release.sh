#!/usr/bin/env bash
# formulas/release.sh — Mechanical release script
#
# Implements the release workflow without Claude:
#   1. Validate prerequisites
#   2. Tag Forgejo main via API
#   3. Push tag to mirrors (Codeberg, GitHub) via token auth
#   4. Build and tag the agents Docker image
#   5. Restart agent containers
#
# Usage: release.sh <action-id>
#
# Expects env vars:
#   FORGE_URL, FORGE_TOKEN, FORGE_REPO, PRIMARY_BRANCH
#   GITHUB_TOKEN    — for pushing tags to GitHub mirror
#   CODEBERG_TOKEN  — for pushing tags to Codeberg mirror
#
# The action TOML context field must contain the version, e.g.:
#   context = "Release v1.2.0"
#
# Part of #516.

set -euo pipefail

FACTORY_ROOT="${FACTORY_ROOT:-/home/agent/disinto}"
OPS_REPO_ROOT="${OPS_REPO_ROOT:-/home/agent/ops}"

log() {
  printf '[%s] release: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

# ── Argument parsing ─────────────────────────────────────────────────────
# VAULT_ACTION_TOML is exported by the runner entrypoint (entrypoint-runner.sh)

action_id="${1:-}"
if [ -z "$action_id" ]; then
  log "ERROR: action-id argument required"
  exit 1
fi

action_toml="${VAULT_ACTION_TOML:-${OPS_REPO_ROOT}/vault/actions/${action_id}.toml}"
if [ ! -f "$action_toml" ]; then
  log "ERROR: vault action TOML not found: ${action_toml}"
  exit 1
fi

# Extract version from context field (e.g. "Release v1.2.0" → "v1.2.0")
context=$(grep -E '^context\s*=' "$action_toml" \
  | sed -E 's/^context\s*=\s*"(.*)"/\1/' | tr -d '\r')
RELEASE_VERSION=$(echo "$context" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+') || true

if [ -z "${RELEASE_VERSION:-}" ]; then
  log "ERROR: could not extract version from context: '${context}'"
  log "Context must contain a version like v1.2.0"
  exit 1
fi

log "Starting release ${RELEASE_VERSION} (action: ${action_id})"

# ── Step 1: Preflight ────────────────────────────────────────────────────

log "Step 1/6: Preflight checks"

# Validate version format
if ! echo "$RELEASE_VERSION" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
  log "ERROR: invalid version format: ${RELEASE_VERSION}"
  exit 1
fi

# Assert tree VERSION file matches the action context version (#605)
if [ ! -f "${FACTORY_ROOT}/VERSION" ]; then
  log "ERROR: VERSION file not found at ${FACTORY_ROOT}/VERSION"
  exit 1
fi
tree_ver=$(tr -d '[:space:]' < "${FACTORY_ROOT}/VERSION")
if [ "v${tree_ver}" != "${RELEASE_VERSION}" ]; then
  log "ERROR: VERSION file says ${tree_ver}, action context says ${RELEASE_VERSION}"
  exit 1
fi

# Required env vars
for var in FORGE_URL FORGE_TOKEN FORGE_REPO PRIMARY_BRANCH; do
  if [ -z "${!var:-}" ]; then
    log "ERROR: required env var not set: ${var}"
    exit 1
  fi
done

# Check Docker access
if ! docker info >/dev/null 2>&1; then
  log "ERROR: Docker not accessible"
  exit 1
fi

# Check tag doesn't already exist on Forgejo
if curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
  "${FORGE_URL}/api/v1/repos/${FORGE_REPO}/tags/${RELEASE_VERSION}" >/dev/null 2>&1; then
  log "ERROR: tag ${RELEASE_VERSION} already exists on Forgejo"
  exit 1
fi

log "Preflight passed"

# ── Step 2: Tag main via Forgejo API ─────────────────────────────────────

log "Step 2/6: Creating tag ${RELEASE_VERSION} on Forgejo"

# Get HEAD SHA of primary branch
head_sha=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
  "${FORGE_URL}/api/v1/repos/${FORGE_REPO}/branches/${PRIMARY_BRANCH}" \
  | jq -r '.commit.id // empty')

if [ -z "$head_sha" ]; then
  log "ERROR: could not get HEAD SHA for ${PRIMARY_BRANCH}"
  exit 1
fi

# Create tag via API
curl -sf -X POST \
  -H "Authorization: token ${FORGE_TOKEN}" \
  -H "Content-Type: application/json" \
  "${FORGE_URL}/api/v1/repos/${FORGE_REPO}/tags" \
  -d "{\"tag_name\":\"${RELEASE_VERSION}\",\"target\":\"${head_sha}\",\"message\":\"Release ${RELEASE_VERSION}\"}" \
  >/dev/null

log "Tag ${RELEASE_VERSION} created (SHA: ${head_sha})"

# ── Step 3: Push tag to mirrors ──────────────────────────────────────────

log "Step 3/6: Pushing tag to mirrors"

# Extract org/repo from FORGE_REPO (e.g. "disinto-admin/disinto" → "disinto")
project_name="${FORGE_REPO##*/}"

# Push to GitHub mirror (if GITHUB_TOKEN is available)
if [ -n "${GITHUB_TOKEN:-}" ]; then
  log "Pushing tag to GitHub mirror"
  # Create tag on GitHub via API
  if curl -sf -X POST \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/Disinto/${project_name}/git/refs" \
    -d "{\"ref\":\"refs/tags/${RELEASE_VERSION}\",\"sha\":\"${head_sha}\"}" \
    >/dev/null 2>&1; then
    log "GitHub: tag pushed"
  else
    log "WARNING: GitHub tag push failed (may already exist)"
  fi
else
  log "WARNING: GITHUB_TOKEN not set — skipping GitHub mirror"
fi

# Push to Codeberg mirror (if CODEBERG_TOKEN is available)
if [ -n "${CODEBERG_TOKEN:-}" ]; then
  log "Pushing tag to Codeberg mirror"
  # Codeberg uses Gitea-compatible API
  # Extract owner from FORGE_REPO for Codeberg (use same owner)
  codeberg_owner="${FORGE_REPO%%/*}"
  if curl -sf -X POST \
    -H "Authorization: token ${CODEBERG_TOKEN}" \
    -H "Content-Type: application/json" \
    "https://codeberg.org/api/v1/repos/${codeberg_owner}/${project_name}/tags" \
    -d "{\"tag_name\":\"${RELEASE_VERSION}\",\"target\":\"${head_sha}\",\"message\":\"Release ${RELEASE_VERSION}\"}" \
    >/dev/null 2>&1; then
    log "Codeberg: tag pushed"
  else
    log "WARNING: Codeberg tag push failed (may already exist)"
  fi
else
  log "WARNING: CODEBERG_TOKEN not set — skipping Codeberg mirror"
fi

# ── Step 4: Build agents Docker image ────────────────────────────────────

log "Step 4/6: Building agents Docker image"

cd "$FACTORY_ROOT" || exit 1
docker compose build --no-cache agents 2>&1 | tail -5
log "Image built"

# ── Step 5: Tag image with version ───────────────────────────────────────

log "Step 5/6: Tagging image"

docker tag disinto/agents:latest "disinto/agents:${RELEASE_VERSION}"
log "Tagged disinto/agents:${RELEASE_VERSION}"

# ── Step 6: Restart agent containers ─────────────────────────────────────

log "Step 6/6: Restarting agent containers"

docker compose stop agents 2>/dev/null || true
docker compose up -d agents
log "Agent containers restarted"

# ── Done ─────────────────────────────────────────────────────────────────

log "Release ${RELEASE_VERSION} completed successfully"
