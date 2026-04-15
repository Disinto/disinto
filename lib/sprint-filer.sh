#!/usr/bin/env bash
# =============================================================================
# sprint-filer.sh — Parse merged sprint PRs and file sub-issues via filer-bot
#
# Invoked by the ops-filer Woodpecker pipeline after a sprint PR merges on the
# ops repo main branch.  Parses each sprints/*.md file for a structured
# ## Sub-issues block (filer:begin/end markers), then creates idempotent
# Forgejo issues on the project repo using FORGE_FILER_TOKEN.
#
# Permission model (#764):
#   filer-bot has issues:write on the project repo.
#   architect-bot is read-only on the project repo.
#
# Usage:
#   sprint-filer.sh <sprint-file.md>          — file sub-issues from one sprint
#   sprint-filer.sh --all <sprints-dir>       — scan all sprint files in dir
#
# Environment:
#   FORGE_FILER_TOKEN   — filer-bot API token (issues:write on project repo)
#   FORGE_API           — project repo API base (e.g. http://forgejo:3000/api/v1/repos/org/repo)
#   FORGE_API_BASE      — API base URL (e.g. http://forgejo:3000/api/v1)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source env.sh only if not already loaded (allows standalone + sourced use)
if [ -z "${FACTORY_ROOT:-}" ]; then
  FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"
  # shellcheck source=env.sh
  source "$SCRIPT_DIR/env.sh"
fi

# ── Logging ──────────────────────────────────────────────────────────────
LOG_AGENT="${LOG_AGENT:-filer}"

filer_log() {
  printf '[%s] %s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$LOG_AGENT" "$*" >&2
}

# ── Validate required environment ────────────────────────────────────────
: "${FORGE_FILER_TOKEN:?sprint-filer.sh requires FORGE_FILER_TOKEN}"
: "${FORGE_API:?sprint-filer.sh requires FORGE_API}"

# ── Parse sub-issues block from a sprint markdown file ───────────────────
# Extracts the YAML-in-markdown between <!-- filer:begin --> and <!-- filer:end -->
# Args: sprint_file_path
# Output: the raw sub-issues block (YAML lines) to stdout
# Returns: 0 if block found, 1 if not found or malformed
parse_subissues_block() {
  local sprint_file="$1"

  if [ ! -f "$sprint_file" ]; then
    filer_log "ERROR: sprint file not found: ${sprint_file}"
    return 1
  fi

  local in_block=false
  local block=""
  local found=false

  while IFS= read -r line; do
    if [[ "$line" == *"<!-- filer:begin -->"* ]]; then
      in_block=true
      found=true
      continue
    fi
    if [[ "$line" == *"<!-- filer:end -->"* ]]; then
      in_block=false
      continue
    fi
    if [ "$in_block" = true ]; then
      block+="${line}"$'\n'
    fi
  done < "$sprint_file"

  if [ "$found" = false ]; then
    filer_log "No filer:begin/end block found in ${sprint_file}"
    return 1
  fi

  if [ "$in_block" = true ]; then
    filer_log "ERROR: malformed sub-issues block in ${sprint_file} — filer:begin without filer:end"
    return 1
  fi

  if [ -z "$block" ]; then
    filer_log "WARNING: empty sub-issues block in ${sprint_file}"
    return 1
  fi

  printf '%s' "$block"
}

# ── Extract vision issue number from sprint file ─────────────────────────
# Looks for "## Vision issues" section with "#N" references
# Args: sprint_file_path
# Output: first vision issue number found
extract_vision_issue() {
  local sprint_file="$1"
  grep -oE '#[0-9]+' "$sprint_file" | head -1 | tr -d '#'
}

# ── Extract sprint slug from file path ───────────────────────────────────
# Args: sprint_file_path
# Output: slug (filename without .md)
extract_sprint_slug() {
  local sprint_file="$1"
  basename "$sprint_file" .md
}

# ── Parse individual sub-issue entries from the block ────────────────────
# The block is a simple YAML-like format:
#   - id: foo
#     title: "..."
#     labels: [backlog, priority]
#     depends_on: [bar]
#     body: |
#       multi-line body
#
# Args: raw_block (via stdin)
# Output: JSON array of sub-issue objects
parse_subissue_entries() {
  local block
  block=$(cat)

  # Use awk to parse the YAML-like structure into JSON
  printf '%s' "$block" | awk '
  BEGIN {
    printf "["
    first = 1
    in_body = 0
    id = ""; title = ""; labels = ""; depends = ""; body = ""
  }

  function flush_entry() {
    if (id == "") return
    if (!first) printf ","
    first = 0

    # Escape JSON special characters in body
    gsub(/\\/, "\\\\", body)
    gsub(/"/, "\\\"", body)
    gsub(/\t/, "\\t", body)
    # Replace newlines with \n for JSON
    gsub(/\n/, "\\n", body)
    # Remove trailing \n
    sub(/\\n$/, "", body)

    # Clean up title (remove surrounding quotes)
    gsub(/^"/, "", title)
    gsub(/"$/, "", title)

    printf "{\"id\":\"%s\",\"title\":\"%s\",\"labels\":%s,\"depends_on\":%s,\"body\":\"%s\"}", id, title, labels, depends, body

    id = ""; title = ""; labels = "[]"; depends = "[]"; body = ""
    in_body = 0
  }

  /^- id:/ {
    flush_entry()
    sub(/^- id: */, "")
    id = $0
    labels = "[]"
    depends = "[]"
    next
  }

  /^  title:/ {
    sub(/^  title: */, "")
    title = $0
    # Remove surrounding quotes
    gsub(/^"/, "", title)
    gsub(/"$/, "", title)
    next
  }

  /^  labels:/ {
    sub(/^  labels: */, "")
    # Convert [a, b] to JSON array ["a","b"]
    gsub(/\[/, "", $0)
    gsub(/\]/, "", $0)
    n = split($0, arr, /, */)
    labels = "["
    for (i = 1; i <= n; i++) {
      gsub(/^ */, "", arr[i])
      gsub(/ *$/, "", arr[i])
      if (arr[i] != "") {
        if (i > 1) labels = labels ","
        labels = labels "\"" arr[i] "\""
      }
    }
    labels = labels "]"
    next
  }

  /^  depends_on:/ {
    sub(/^  depends_on: */, "")
    gsub(/\[/, "", $0)
    gsub(/\]/, "", $0)
    n = split($0, arr, /, */)
    depends = "["
    for (i = 1; i <= n; i++) {
      gsub(/^ */, "", arr[i])
      gsub(/ *$/, "", arr[i])
      if (arr[i] != "") {
        if (i > 1) depends = depends ","
        depends = depends "\"" arr[i] "\""
      }
    }
    depends = depends "]"
    next
  }

  /^  body: *\|/ {
    in_body = 1
    body = ""
    next
  }

  in_body && /^    / {
    sub(/^    /, "")
    body = body $0 "\n"
    next
  }

  in_body && !/^    / && !/^$/ {
    in_body = 0
    # This line starts a new field or entry — re-process it
    # (awk does not support re-scanning, so handle common cases)
    if ($0 ~ /^- id:/) {
      flush_entry()
      sub(/^- id: */, "")
      id = $0
      labels = "[]"
      depends = "[]"
    }
  }

  END {
    flush_entry()
    printf "]"
  }
  '
}

# ── Check if sub-issue already exists (idempotency) ─────────────────────
# Searches for the decomposed-from marker in existing issues.
# Args: vision_issue_number sprint_slug subissue_id
# Returns: 0 if already exists, 1 if not
subissue_exists() {
  local vision_issue="$1"
  local sprint_slug="$2"
  local subissue_id="$3"

  local marker="<!-- decomposed-from: #${vision_issue}, sprint: ${sprint_slug}, id: ${subissue_id} -->"

  # Search for issues with this exact marker
  local issues_json
  issues_json=$(curl -sf -H "Authorization: token ${FORGE_FILER_TOKEN}" \
    "${FORGE_API}/issues?state=all&limit=50&type=issues" 2>/dev/null) || issues_json="[]"

  if printf '%s' "$issues_json" | jq -e --arg marker "$marker" \
    '[.[] | select(.body // "" | contains($marker))] | length > 0' >/dev/null 2>&1; then
    return 0  # Already exists
  fi

  return 1  # Does not exist
}

# ── Resolve label names to IDs ───────────────────────────────────────────
# Args: label_names_json (JSON array of strings)
# Output: JSON array of label IDs
resolve_label_ids() {
  local label_names_json="$1"

  # Fetch all labels from project repo
  local all_labels
  all_labels=$(curl -sf -H "Authorization: token ${FORGE_FILER_TOKEN}" \
    "${FORGE_API}/labels" 2>/dev/null) || all_labels="[]"

  # Map names to IDs
  printf '%s' "$label_names_json" | jq -r '.[]' | while IFS= read -r label_name; do
    [ -z "$label_name" ] && continue
    printf '%s' "$all_labels" | jq -r --arg name "$label_name" \
      '.[] | select(.name == $name) | .id' 2>/dev/null
  done | jq -Rs 'split("\n") | map(select(. != "") | tonumber)'
}

# ── Add in-progress label to vision issue ────────────────────────────────
# Args: vision_issue_number
add_inprogress_label() {
  local issue_num="$1"

  local labels_json
  labels_json=$(curl -sf -H "Authorization: token ${FORGE_FILER_TOKEN}" \
    "${FORGE_API}/labels" 2>/dev/null) || return 1

  local label_id
  label_id=$(printf '%s' "$labels_json" | jq -r '.[] | select(.name == "in-progress") | .id' 2>/dev/null) || true

  if [ -z "$label_id" ]; then
    filer_log "WARNING: in-progress label not found"
    return 1
  fi

  if curl -sf -X POST \
    -H "Authorization: token ${FORGE_FILER_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API}/issues/${issue_num}/labels" \
    -d "{\"labels\": [${label_id}]}" >/dev/null 2>&1; then
    filer_log "Added in-progress label to vision issue #${issue_num}"
    return 0
  else
    filer_log "WARNING: failed to add in-progress label to vision issue #${issue_num}"
    return 1
  fi
}

# ── File sub-issues from a sprint file ───────────────────────────────────
# This is the main entry point. Parses the sprint file, extracts sub-issues,
# and creates them idempotently via the Forgejo API.
# Args: sprint_file_path
# Returns: 0 on success, 1 on any error (fail-fast)
file_subissues() {
  local sprint_file="$1"

  filer_log "Processing sprint file: ${sprint_file}"

  # Extract metadata
  local vision_issue sprint_slug
  vision_issue=$(extract_vision_issue "$sprint_file")
  sprint_slug=$(extract_sprint_slug "$sprint_file")

  if [ -z "$vision_issue" ]; then
    filer_log "ERROR: could not extract vision issue number from ${sprint_file}"
    return 1
  fi

  filer_log "Vision issue: #${vision_issue}, sprint slug: ${sprint_slug}"

  # Parse the sub-issues block
  local raw_block
  raw_block=$(parse_subissues_block "$sprint_file") || return 1

  # Parse individual entries
  local entries_json
  entries_json=$(printf '%s' "$raw_block" | parse_subissue_entries)

  # Validate parsing produced valid JSON
  if ! printf '%s' "$entries_json" | jq empty 2>/dev/null; then
    filer_log "ERROR: failed to parse sub-issues block as valid JSON in ${sprint_file}"
    return 1
  fi

  local entry_count
  entry_count=$(printf '%s' "$entries_json" | jq 'length')

  if [ "$entry_count" -eq 0 ]; then
    filer_log "WARNING: no sub-issue entries found in ${sprint_file}"
    return 1
  fi

  filer_log "Found ${entry_count} sub-issue(s) to file"

  # File each sub-issue (fail-fast on first error)
  local filed_count=0
  local i=0
  while [ "$i" -lt "$entry_count" ]; do
    local entry
    entry=$(printf '%s' "$entries_json" | jq ".[$i]")

    local subissue_id subissue_title subissue_body labels_json
    subissue_id=$(printf '%s' "$entry" | jq -r '.id')
    subissue_title=$(printf '%s' "$entry" | jq -r '.title')
    subissue_body=$(printf '%s' "$entry" | jq -r '.body')
    labels_json=$(printf '%s' "$entry" | jq -c '.labels')

    if [ -z "$subissue_id" ] || [ "$subissue_id" = "null" ]; then
      filer_log "ERROR: sub-issue entry at index ${i} has no id — aborting"
      return 1
    fi

    if [ -z "$subissue_title" ] || [ "$subissue_title" = "null" ]; then
      filer_log "ERROR: sub-issue '${subissue_id}' has no title — aborting"
      return 1
    fi

    # Idempotency check
    if subissue_exists "$vision_issue" "$sprint_slug" "$subissue_id"; then
      filer_log "Sub-issue '${subissue_id}' already exists — skipping"
      i=$((i + 1))
      continue
    fi

    # Append decomposed-from marker to body
    local marker="<!-- decomposed-from: #${vision_issue}, sprint: ${sprint_slug}, id: ${subissue_id} -->"
    local full_body="${subissue_body}

${marker}"

    # Resolve label names to IDs
    local label_ids
    label_ids=$(resolve_label_ids "$labels_json")

    # Build issue payload using jq for safe JSON construction
    local payload
    payload=$(jq -n \
      --arg title "$subissue_title" \
      --arg body "$full_body" \
      --argjson labels "$label_ids" \
      '{title: $title, body: $body, labels: $labels}')

    # Create the issue
    local response
    response=$(curl -sf -X POST \
      -H "Authorization: token ${FORGE_FILER_TOKEN}" \
      -H "Content-Type: application/json" \
      "${FORGE_API}/issues" \
      -d "$payload" 2>/dev/null) || {
      filer_log "ERROR: failed to create sub-issue '${subissue_id}' — aborting (${filed_count}/${entry_count} filed so far)"
      return 1
    }

    local new_issue_num
    new_issue_num=$(printf '%s' "$response" | jq -r '.number // empty')
    filer_log "Filed sub-issue '${subissue_id}' as #${new_issue_num}: ${subissue_title}"

    filed_count=$((filed_count + 1))
    i=$((i + 1))
  done

  # Add in-progress label to the vision issue
  add_inprogress_label "$vision_issue" || true

  filer_log "Successfully filed ${filed_count}/${entry_count} sub-issue(s) for sprint ${sprint_slug}"
  return 0
}

# ── Vision lifecycle: close completed vision issues ──────────────────────
# Checks open vision issues and closes any whose sub-issues are all closed.
# Uses the decomposed-from marker to find sub-issues.
check_and_close_completed_visions() {
  filer_log "Checking for vision issues with all sub-issues complete..."

  local vision_issues_json
  vision_issues_json=$(curl -sf -H "Authorization: token ${FORGE_FILER_TOKEN}" \
    "${FORGE_API}/issues?labels=vision&state=open&limit=100" 2>/dev/null) || vision_issues_json="[]"

  if [ "$vision_issues_json" = "[]" ] || [ "$vision_issues_json" = "null" ]; then
    filer_log "No open vision issues found"
    return 0
  fi

  local all_issues
  all_issues=$(curl -sf -H "Authorization: token ${FORGE_FILER_TOKEN}" \
    "${FORGE_API}/issues?state=all&limit=200&type=issues" 2>/dev/null) || all_issues="[]"

  local vision_nums
  vision_nums=$(printf '%s' "$vision_issues_json" | jq -r '.[].number' 2>/dev/null) || return 0

  local closed_count=0
  while IFS= read -r vid; do
    [ -z "$vid" ] && continue

    # Find sub-issues with decomposed-from marker for this vision
    local sub_issues
    sub_issues=$(printf '%s' "$all_issues" | jq --arg vid "$vid" \
      '[.[] | select(.body // "" | contains("<!-- decomposed-from: #" + $vid))]')

    local sub_count
    sub_count=$(printf '%s' "$sub_issues" | jq 'length')

    # No sub-issues means not ready to close
    [ "$sub_count" -eq 0 ] && continue

    # Check if all are closed
    local open_count
    open_count=$(printf '%s' "$sub_issues" | jq '[.[] | select(.state != "closed")] | length')

    if [ "$open_count" -gt 0 ]; then
      continue
    fi

    # All sub-issues closed — close the vision issue
    filer_log "All ${sub_count} sub-issues for vision #${vid} are closed — closing vision"

    local comment_body="## Vision Issue Completed

All sub-issues have been implemented and merged. This vision issue is now closed.

---
*Automated closure by filer-bot · $(date -u '+%Y-%m-%d %H:%M UTC')*"

    local comment_payload
    comment_payload=$(jq -n --arg body "$comment_body" '{body: $body}')

    curl -sf -X POST \
      -H "Authorization: token ${FORGE_FILER_TOKEN}" \
      -H "Content-Type: application/json" \
      "${FORGE_API}/issues/${vid}/comments" \
      -d "$comment_payload" >/dev/null 2>&1 || true

    curl -sf -X PATCH \
      -H "Authorization: token ${FORGE_FILER_TOKEN}" \
      -H "Content-Type: application/json" \
      "${FORGE_API}/issues/${vid}" \
      -d '{"state":"closed"}' >/dev/null 2>&1 || true

    closed_count=$((closed_count + 1))
  done <<< "$vision_nums"

  if [ "$closed_count" -gt 0 ]; then
    filer_log "Closed ${closed_count} vision issue(s)"
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────
main() {
  if [ "${1:-}" = "--all" ]; then
    local sprints_dir="${2:?Usage: sprint-filer.sh --all <sprints-dir>}"
    local exit_code=0

    for sprint_file in "${sprints_dir}"/*.md; do
      [ -f "$sprint_file" ] || continue

      # Only process files with filer:begin markers
      if ! grep -q '<!-- filer:begin -->' "$sprint_file"; then
        continue
      fi

      if ! file_subissues "$sprint_file"; then
        filer_log "ERROR: failed to process ${sprint_file}"
        exit_code=1
      fi
    done

    # Run vision lifecycle check after filing
    check_and_close_completed_visions || true

    return "$exit_code"
  elif [ -n "${1:-}" ]; then
    file_subissues "$1"
    # Run vision lifecycle check after filing
    check_and_close_completed_visions || true
  else
    echo "Usage: sprint-filer.sh <sprint-file.md>" >&2
    echo "       sprint-filer.sh --all <sprints-dir>" >&2
    return 1
  fi
}

# Run main only when executed directly (not when sourced for testing)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
