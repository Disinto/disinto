#!/usr/bin/env bash
# =============================================================================
# disinto backup — export factory state for migration
#
# Usage: source this file, then call backup_create <outfile.tar.gz>
# Requires: FORGE_URL, FORGE_TOKEN, FORGE_REPO, FORGE_OPS_REPO, OPS_REPO_ROOT
# =============================================================================
set -euo pipefail

# Fetch all issues (open + closed) for a repo slug and emit the normalized JSON array.
# Usage: _backup_fetch_issues <org/repo>
_backup_fetch_issues() {
  local repo_slug="$1"
  local api_url="${FORGE_API_BASE}/repos/${repo_slug}"

  local all_issues="[]"
  for state in open closed; do
    local page=1
    while true; do
      local page_items
      page_items=$(curl -sf -X GET \
        -H "Authorization: token ${FORGE_TOKEN}" \
        -H "Content-Type: application/json" \
        "${api_url}/issues?state=${state}&type=issues&limit=50&page=${page}") || {
        echo "ERROR: failed to fetch ${state} issues from ${repo_slug} (page ${page})" >&2
        return 1
      }
      local count
      count=$(printf '%s' "$page_items" | jq 'length' 2>/dev/null) || count=0
      [ -z "$count" ] && count=0
      [ "$count" -eq 0 ] && break
      all_issues=$(printf '%s\n%s' "$all_issues" "$page_items" | jq -s 'add')
      [ "$count" -lt 50 ] && break
      page=$((page + 1))
    done
  done

  # Normalize to the schema: number, title, body, labels, state
  printf '%s' "$all_issues" | jq '[.[] | {
    number: .number,
    title: .title,
    body: .body,
    labels: [.labels[]?.name],
    state: .state
  }] | sort_by(.number)'
}

# Create a backup tarball of factory state.
# Usage: backup_create <outfile.tar.gz>
backup_create() {
  local outfile="${1:-}"
  if [ -z "$outfile" ]; then
    echo "Error: output file required" >&2
    echo "Usage: disinto backup create <outfile.tar.gz>" >&2
    return 1
  fi

  # Resolve to absolute path before cd-ing into tmpdir
  case "$outfile" in
    /*) ;;
    *) outfile="$(pwd)/${outfile}" ;;
  esac

  # Validate required env
  : "${FORGE_URL:?FORGE_URL must be set}"
  : "${FORGE_TOKEN:?FORGE_TOKEN must be set}"
  : "${FORGE_REPO:?FORGE_REPO must be set}"

  local forge_ops_repo="${FORGE_OPS_REPO:-${FORGE_REPO}-ops}"
  local ops_repo_root="${OPS_REPO_ROOT:-}"

  if [ -z "$ops_repo_root" ] || [ ! -d "$ops_repo_root/.git" ]; then
    echo "Error: OPS_REPO_ROOT (${ops_repo_root:-<unset>}) is not a valid git repo" >&2
    return 1
  fi

  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT

  local project_name="${FORGE_REPO##*/}"

  echo "=== disinto backup create ==="
  echo "Forge: ${FORGE_URL}"
  echo "Repos: ${FORGE_REPO}, ${forge_ops_repo}"

  # ── 1. Export issues ──────────────────────────────────────────────────────
  mkdir -p "${tmpdir}/issues"

  echo "Fetching issues for ${FORGE_REPO}..."
  _backup_fetch_issues "$FORGE_REPO" > "${tmpdir}/issues/${project_name}.json"
  local main_count
  main_count=$(jq 'length' "${tmpdir}/issues/${project_name}.json")
  echo "  ${main_count} issues exported"

  echo "Fetching issues for ${forge_ops_repo}..."
  _backup_fetch_issues "$forge_ops_repo" > "${tmpdir}/issues/${project_name}-ops.json"
  local ops_count
  ops_count=$(jq 'length' "${tmpdir}/issues/${project_name}-ops.json")
  echo "  ${ops_count} issues exported"

  # ── 2. Git bundle of ops repo ────────────────────────────────────────────
  mkdir -p "${tmpdir}/repos"

  echo "Creating git bundle for ${forge_ops_repo}..."
  git -C "$ops_repo_root" bundle create "${tmpdir}/repos/${project_name}-ops.bundle" --all 2>&1
  echo "  bundle created ($(du -h "${tmpdir}/repos/${project_name}-ops.bundle" | cut -f1))"

  # ── 3. Metadata ──────────────────────────────────────────────────────────
  local created_at
  created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  jq -n \
    --arg created_at "$created_at" \
    --arg source_host "$(hostname)" \
    --argjson schema_version 1 \
    --arg forgejo_url "$FORGE_URL" \
    '{
      created_at: $created_at,
      source_host: $source_host,
      schema_version: $schema_version,
      forgejo_url: $forgejo_url
    }' > "${tmpdir}/metadata.json"

  # ── 4. Pack tarball ──────────────────────────────────────────────────────
  echo "Creating tarball: ${outfile}"
  tar -czf "$outfile" -C "$tmpdir" metadata.json issues repos
  local size
  size=$(du -h "$outfile" | cut -f1)
  echo "=== Backup complete: ${outfile} (${size}) ==="
}
