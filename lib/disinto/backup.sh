#!/usr/bin/env bash
# =============================================================================
# backup.sh — backup/restore utilities for disinto factory state
#
# Subcommands:
#   create <outfile.tar.gz>  Create backup of factory state
#   import <infile.tar.gz>   Restore factory state from backup
#
# Usage:
#   source "${FACTORY_ROOT}/lib/disinto/backup.sh"
#   backup_import <tarball>
#
# Environment:
#   FORGE_URL    - Forgejo instance URL (target)
#   FORGE_TOKEN  - Admin token for target Forgejo
#
# Idempotency:
#   - Repos: created via API if missing
#   - Issues: check if exists by number, skip if present
#   - Runs twice = same end state, no errors
# =============================================================================
set -euo pipefail

# ── Helper: log with timestamp ───────────────────────────────────────────────
backup_log() {
  local msg="$1"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg"
}

# ── Helper: create repo if it doesn't exist ─────────────────────────────────
# Usage: backup_create_repo_if_missing <slug>
# Returns: 0 if repo exists or was created, 1 on error
backup_create_repo_if_missing() {
  local slug="$1"
  local org_name="${slug%%/*}"
  local repo_name="${slug##*/}"

  # Check if repo exists
  if curl -sf --max-time 5 \
    -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_URL}/api/v1/repos/${slug}" >/dev/null 2>&1; then
    backup_log "Repo ${slug} already exists"
    return 0
  fi

  backup_log "Creating repo ${slug}..."

  # Create org if needed
  curl -sf -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_URL}/api/v1/orgs" \
    -d "{\"username\":\"${org_name}\",\"visibility\":\"public\"}" >/dev/null 2>&1 || true

  # Create repo
  local response
  response=$(curl -sf -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_URL}/api/v1/orgs/${org_name}/repos" \
    -d "{\"name\":\"${repo_name}\",\"auto_init\":false,\"default_branch\":\"main\"}" 2>/dev/null) \
    || response=""

  if [ -n "$response" ] && echo "$response" | grep -q '"id":\|[0-9]'; then
    backup_log "Created repo ${slug}"
    BACKUP_CREATED_REPOS=$((BACKUP_CREATED_REPOS + 1))
    return 0
  fi

  # Fallback: admin endpoint
  response=$(curl -sf -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_URL}/api/v1/admin/users/${org_name}/repos" \
    -d "{\"name\":\"${repo_name}\",\"auto_init\":false,\"default_branch\":\"main\"}" 2>/dev/null) \
    || response=""

  if [ -n "$response" ] && echo "$response" | grep -q '"id":\|[0-9]'; then
    backup_log "Created repo ${slug} (via admin API)"
    BACKUP_CREATED_REPOS=$((BACKUP_CREATED_REPOS + 1))
    return 0
  fi

  backup_log "ERROR: failed to create repo ${slug}" >&2
  return 1
}

# ── Helper: check if issue exists by number ──────────────────────────────────
# Usage: backup_issue_exists <slug> <issue_number>
# Returns: 0 if exists, 1 if not
backup_issue_exists() {
  local slug="$1"
  local issue_num="$2"

  curl -sf --max-time 5 \
    -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_URL}/api/v1/repos/${slug}/issues/${issue_num}" >/dev/null 2>&1
}

# ── Helper: create issue with specific number (if Forgejo supports it) ───────
# Note: Forgejo API auto-assigns next integer; we accept renumbering and log mapping
# Usage: backup_create_issue <slug> <original_number> <title> <body> [labels...]
# Returns: new_issue_number on success, 0 on failure
backup_create_issue() {
  local slug="$1"
  local original_num="$2"
  local title="$3"
  local body="$4"
  shift 4

  # Build labels array
  local -a labels=()
  for label in "$@"; do
    # Resolve label name to ID
    local label_id
    label_id=$(curl -sf --max-time 5 \
      -H "Authorization: token ${FORGE_TOKEN}" \
      "${FORGE_URL}/api/v1/repos/${slug}/labels" 2>/dev/null \
      | jq -r ".[] | select(.name == \"${label}\") | .id" 2>/dev/null) || label_id=""

    if [ -n "$label_id" ] && [ "$label_id" != "null" ]; then
      labels+=("$label_id")
    fi
  done

  # Build payload
  local payload
  if [ ${#labels[@]} -gt 0 ]; then
    payload=$(jq -n \
      --arg title "$title" \
      --arg body "$body" \
      --argjson labels "$(printf '%s\n' "${labels[@]}" | jq -R . | jq -s .)" \
      '{title: $title, body: $body, labels: $labels}')
  else
    payload=$(jq -n --arg title "$title" --arg body "$body" '{title: $title, body: $body, labels: []}')
  fi

  local response
  response=$(curl -sf -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_URL}/api/v1/repos/${slug}/issues" \
    -d "$payload" 2>/dev/null) || {
    backup_log "ERROR: failed to create issue '${title}'" >&2
    return 1
  }

  local new_num
  new_num=$(printf '%s' "$response" | jq -r '.number // empty')

  # Log the mapping
  echo "${original_num}:${new_num}" >> "${BACKUP_MAPPING_FILE}"

  backup_log "Created issue '${title}' as #${new_num} (original: #${original_num})"
  echo "$new_num"
}

# ── Step 1: Unpack tarball to temp dir ───────────────────────────────────────
# Usage: backup_unpack_tarball <tarball>
# Returns: temp dir path via BACKUP_TEMP_DIR
backup_unpack_tarball() {
  local tarball="$1"

  if [ ! -f "$tarball" ]; then
    backup_log "ERROR: tarball not found: ${tarball}" >&2
    return 1
  fi

  BACKUP_TEMP_DIR=$(mktemp -d -t disinto-backup.XXXXXX)
  backup_log "Unpacking ${tarball} to ${BACKUP_TEMP_DIR}"

  if ! tar -xzf "$tarball" -C "$BACKUP_TEMP_DIR"; then
    backup_log "ERROR: failed to unpack tarball" >&2
    rm -rf "$BACKUP_TEMP_DIR"
    return 1
  fi

  # Verify expected structure
  if [ ! -d "${BACKUP_TEMP_DIR}/repos" ]; then
    backup_log "ERROR: tarball missing 'repos/' directory" >&2
    rm -rf "$BACKUP_TEMP_DIR"
    return 1
  fi

  backup_log "Tarball unpacked successfully"
}

# ── Step 2: disinto repo — create via Forgejo API, trigger sync (manual) ─────
# Usage: backup_import_disinto_repo
# Returns: 0 on success, 1 on failure
backup_import_disinto_repo() {
  backup_log "Step 2: Configuring disinto repo..."

  # Create disinto repo if missing
  backup_create_repo_if_missing "disinto-admin/disinto"

  # Note: Manual mirror configuration recommended (avoids SSH deploy-key handling)
  backup_log "Note: Configure Codeberg → Forgejo pull mirror manually"
  backup_log "  Run on Forgejo admin panel: Repository Settings → Repository Mirroring"
  backup_log "  Source: ssh://git@codeberg.org/johba/disinto.git"
  backup_log "  Mirror: disinto-admin/disinto"
  backup_log "  Or use: git clone --mirror ssh://git@codeberg.org/johba/disinto.git"
  backup_log "          cd disinto.git && git push --mirror ${FORGE_URL}/disinto-admin/disinto.git"

  return 0
}

# ── Step 3: disinto-ops repo — create empty, push from bundle ────────────────
# Usage: backup_import_disinto_ops_repo
# Returns: 0 on success, 1 on failure
backup_import_disinto_ops_repo() {
  backup_log "Step 3: Configuring disinto-ops repo from bundle..."

  local bundle_path="${BACKUP_TEMP_DIR}/repos/disinto-ops.bundle"

  if [ ! -f "$bundle_path" ]; then
    backup_log "WARNING: Bundle not found at ${bundle_path}, skipping"
    return 0
  fi

  # Create ops repo if missing
  backup_create_repo_if_missing "disinto-admin/disinto-ops"

  # Clone bundle and push to Forgejo
  local clone_dir
  clone_dir=$(mktemp -d -t disinto-ops-clone.XXXXXX)
  backup_log "Cloning bundle to ${clone_dir}"

  if ! git clone --bare "$bundle_path" "$clone_dir/disinto-ops.git"; then
    backup_log "ERROR: failed to clone bundle"
    rm -rf "$clone_dir"
    return 1
  fi

  # Build authenticated push URL
  local admin_user
  admin_user=$(forge_whoami)
  if [ -z "$admin_user" ] || [ "$admin_user" = "null" ]; then
    backup_log "ERROR: could not resolve admin username from token"
    rm -rf "$clone_dir"
    return 1
  fi
  # Inject credentials: http(s)://user:token@host/path
  local push_url
  local scheme="${FORGE_URL%%://*}"
  local rest="${FORGE_URL#*://}"
  push_url="${scheme}://${admin_user}:${FORGE_TOKEN}@${rest}"
  push_url="${push_url}/disinto-admin/disinto-ops.git"

  # Push all refs to Forgejo
  backup_log "Pushing refs to Forgejo..."
  local push_output
  if ! push_output=$(git -C "$clone_dir/disinto-ops.git" push --mirror "$push_url" 2>&1); then
    backup_log "ERROR: git push failed:"
    backup_log "$push_output"
    rm -rf "$clone_dir"
    return 1
  fi
  backup_log "$push_output"

  local ref_count
  ref_count=$(git -C "$clone_dir/disinto-ops.git" show-ref | wc -l)
  BACKUP_PUSHED_REFS=$((BACKUP_PUSHED_REFS + ref_count))

  # Verify the target repo is not empty
  local repo_empty
  repo_empty=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_URL}/api/v1/repos/disinto-admin/disinto-ops" \
    | jq -r '.empty') || repo_empty="unknown"
  if [ "$repo_empty" = "true" ]; then
    backup_log "ERROR: push reported success but target repo is still empty"
    rm -rf "$clone_dir"
    return 1
  fi

  backup_log "Pushed ${ref_count} refs to disinto-ops (verified: repo not empty)"
  rm -rf "$clone_dir"

  return 0
}

# ── Step 4: Import issues from backup ────────────────────────────────────────
# Usage: backup_import_issues <slug> <issues_file>
#        issues_file is a JSON array of issues (per create schema)
# Returns: 0 on success
backup_import_issues() {
  local slug="$1"
  local issues_file="$2"

  if [ ! -f "$issues_file" ]; then
    backup_log "No issues file found, skipping"
    return 0
  fi

  local count
  count=$(jq 'length' "$issues_file")
  backup_log "Importing ${count} issues from ${issues_file}"

  local created=0
  local skipped=0

  for i in $(seq 0 $((count - 1))); do
    local issue_num title body src_state
    issue_num=$(jq -r ".[${i}].number" "$issues_file")
    title=$(jq -r ".[${i}].title" "$issues_file")
    body=$(jq -r ".[${i}].body" "$issues_file")
    src_state=$(jq -r ".[${i}].state // \"open\"" "$issues_file")

    if [ -z "$issue_num" ] || [ "$issue_num" = "null" ]; then
      backup_log "WARNING: skipping issue without number at index ${i}"
      continue
    fi

    # Check if issue already exists
    if backup_issue_exists "$slug" "$issue_num"; then
      backup_log "Issue #${issue_num} already exists, skipping"
      skipped=$((skipped + 1))
      continue
    fi

    # Extract labels
    local -a labels=()
    while IFS= read -r label; do
      [ -n "$label" ] && labels+=("$label")
    done < <(jq -r ".[${i}].labels[]? // empty" "$issues_file")

    # Create issue
    local new_num
    if new_num=$(backup_create_issue "$slug" "$issue_num" "$title" "$body" "${labels[@]}"); then
      created=$((created + 1))

      # Forgejo POST /issues always creates open — PATCH closed issues
      if [ "$src_state" = "closed" ]; then
        curl -sf -X PATCH \
          -H "Authorization: token ${FORGE_TOKEN}" \
          -H 'Content-Type: application/json' \
          "${FORGE_URL}/api/v1/repos/${slug}/issues/${new_num}" \
          -d '{"state":"closed"}' >/dev/null 2>&1 || \
          backup_log "WARNING: failed to close issue #${new_num} (PATCH)" >&2
      fi
    fi
  done

  BACKUP_CREATED_ISSUES=$((BACKUP_CREATED_ISSUES + created))
  BACKUP_SKIPPED_ISSUES=$((BACKUP_SKIPPED_ISSUES + skipped))

  backup_log "Created ${created} issues, skipped ${skipped}"
}

# ── Main: import subcommand ──────────────────────────────────────────────────
# Usage: backup_import <tarball>
backup_import() {
  local tarball="$1"

  # Validate required environment
  [ -n "${FORGE_URL:-}" ] || { echo "Error: FORGE_URL not set" >&2; exit 1; }
  [ -n "${FORGE_TOKEN:-}" ] || { echo "Error: FORGE_TOKEN not set" >&2; exit 1; }

  backup_log "=== Backup Import Started ==="
  backup_log "Target: ${FORGE_URL}"
  backup_log "Tarball: ${tarball}"

  # Initialize counters
  BACKUP_CREATED_REPOS=0
  BACKUP_PUSHED_REFS=0
  BACKUP_CREATED_ISSUES=0
  BACKUP_SKIPPED_ISSUES=0

  # Create temp dir for mapping file
  BACKUP_MAPPING_FILE=$(mktemp -t disinto-mapping.XXXXXX.json)
  echo '{"mappings": []}' > "$BACKUP_MAPPING_FILE"

  # Step 1: Unpack tarball
  if ! backup_unpack_tarball "$tarball"; then
    exit 1
  fi

  # Step 2: disinto repo
  if ! backup_import_disinto_repo; then
    exit 1
  fi

  # Step 3: disinto-ops repo
  if ! backup_import_disinto_ops_repo; then
    exit 1
  fi

  # Step 4: Import issues — iterate issues/<slug>.json files, each is a JSON array
  for issues_file in "${BACKUP_TEMP_DIR}/issues"/*.json; do
    [ -f "$issues_file" ] || continue

    local slug_filename
    slug_filename=$(basename "$issues_file" .json)

    # Map slug-filename → forgejo-slug: "disinto" → "disinto-admin/disinto",
    #                                    "disinto-ops" → "disinto-admin/disinto-ops"
    local slug
    case "$slug_filename" in
      "disinto") slug="${FORGE_REPO}" ;;
      "disinto-ops") slug="${FORGE_OPS_REPO}" ;;
      *) slug="disinto-admin/${slug_filename}" ;;
    esac

    backup_log "Processing issues from ${slug_filename}.json (${slug})"
    backup_import_issues "$slug" "$issues_file"
  done

  # Summary
  backup_log "=== Backup Import Complete ==="
  backup_log "Created ${BACKUP_CREATED_REPOS} repos"
  backup_log "Pushed ${BACKUP_PUSHED_REFS} refs"
  backup_log "Imported ${BACKUP_CREATED_ISSUES} issues"
  backup_log "Skipped ${BACKUP_SKIPPED_ISSUES} (already present)"
  backup_log "Issue mapping saved to: ${BACKUP_MAPPING_FILE}"

  # Cleanup
  rm -rf "$BACKUP_TEMP_DIR"

  exit 0
}

# ── Entry point: if sourced, don't run; if executed directly, run import ────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [ $# -lt 1 ]; then
    echo "Usage: $0 <tarball>" >&2
    exit 1
  fi

  backup_import "$1"
fi
