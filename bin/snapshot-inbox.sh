#!/usr/bin/env bash
# =============================================================================
# snapshot-inbox.sh — inbox-collector for snapshot daemon
#
# Scans action-vault drops, forge issues, and completed delegate threads to
# surface unread items for the operator (voice/chat: "architect produced a
# sprint draft, want me to read it?").
#
# Scans:
#   - action-vault/ for files newer than action-vault/.last-ack sentinel.
#   - Forge issues labeled prediction/unreviewed (label id 11).
#   - Forge issues opened in the last 24h by automation accounts.
#   - Completed delegate threads from the last 24h (not yet acked).
#
# Output under "inbox" key in state.json:
#   {"inbox":{"items":[...],"unread_count":N}}
#
# Cap: most recent 20 items (sorted by timestamp descending).
#
# Environment:
#   FACTORY_FORGE_PAT  — Forge admin PAT (required for forge queries)
#   FORGE_URL          — Forgejo base URL (default http://localhost:3000)
#   FORGE_REPO         — repo slug owner/name (default disinto-admin/disinto)
#   SNAPSHOT_PATH      — path to state.json (default /var/lib/disinto/snapshot/state.json)
#   FORGE_TIMEOUT      — per-call timeout in seconds (default 15)
#   VAULT_DIR          — action-vault dir relative to repo root (default action-vault)
#   THREADS_ROOT       — parent directory for thread stores (default /var/lib/disinto/threads)
#
# .last-ack sentinel: updated by a future ack skill. Until then, everything
# is treated as unread.
# =============================================================================
set -euo pipefail

: "${FACTORY_FORGE_PAT:?FACTORY_FORGE_PAT is required}"
FORGE_URL="${FORGE_URL:-http://localhost:3000}"
FORGE_REPO="${FORGE_REPO:-disinto-admin/disinto}"
SNAPSHOT_PATH="${SNAPSHOT_PATH:-/var/lib/disinto/snapshot/state.json}"
FORGE_TIMEOUT="${FORGE_TIMEOUT:-15}"
VAULT_DIR="${VAULT_DIR:-action-vault}"

readonly PREDICTION_LABEL_ID=11

log() {
  printf '[%s] snapshot-inbox: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

# ── Temp file tracking ───────────────────────────────────────────────────────

TMPFILES=()

mktemp_safe() {
  local tmp
  tmp="$(mktemp "$@")"
  TMPFILES+=("$tmp")
  printf '%s' "$tmp"
}

cleanup() {
  rm -f "${TMPFILES[@]}" 2>/dev/null || true
}
trap cleanup EXIT

# ── Forge HTTP helpers ───────────────────────────────────────────────────────

forge_get() {
  local url="$1"
  local body_file="$2"
  local headers_file="$3"

  curl -fsS --max-time "$FORGE_TIMEOUT" \
    -H "Authorization: token ${FACTORY_FORGE_PAT}" \
    -H "Accept: application/json" \
    -D "$headers_file" -o "$body_file" "$url" 2>/dev/null
}

# ── Scan action-vault/ ──────────────────────────────────────────────────────

# Collects files from action-vault/ newer than .last-ack sentinel.
# If .last-ack doesn't exist, all files are included.
# Returns JSON array of inbox items.
scan_action_vault() {
  local vault_path
  vault_path="$(pwd)/${VAULT_DIR}"

  if [ ! -d "$vault_path" ]; then
    printf '[]'
    return
  fi

  local last_ack
  last_ack="${vault_path}/.last-ack"
  local cutoff_epoch=""
  if [ -f "$last_ack" ]; then
    cutoff_epoch="$(date -d "@$(cat "$last_ack" 2>/dev/null)" +%s 2>/dev/null)" || true
  fi

  local items="[]"

  # Find files (not directories, not the sentinel itself), skip hidden files
  while IFS= read -r -d '' filepath; do
    local basename
    basename="$(basename "$filepath")"

    # Skip hidden files (includes .last-ack sentinel)
    [[ "$basename" == .* ]] && continue

    # Skip if newer-than sentinel and sentinel exists
    if [ -n "$cutoff_epoch" ]; then
      local file_epoch
      file_epoch="$(stat -c '%Y' "$filepath" 2>/dev/null)" || continue
      [ "$file_epoch" -le "$cutoff_epoch" ] && continue
    fi

    # Get file modification timestamp (ISO 8601 UTC)
    local file_ts
    file_ts="$(date -u -d "@$(stat -c '%Y' "$filepath" 2>/dev/null)" '+%Y-%m-%dT%H:%M:%SZ')" || continue

    # Derive title from filename (strip extension, replace hyphens/spaces)
    local title
    title="$(printf '%s' "$basename" | sed 's/\.[^.]*$//' | sed 's/[-_]/ /g' | sed 's/\b\(.\)/\u\1/g')"

    # Derive author from git log (most recent commit author), fallback to formula
    local author="vault"
    local git_root
    git_root="$(git -C "$(dirname "$vault_path")" rev-parse --show-toplevel 2>/dev/null)" || true
    if [ -n "$git_root" ]; then
      local git_author
      git_author="$(git -C "$git_root" log -1 --format='%an' -- "$filepath" 2>/dev/null)" || true
      if [ -n "$git_author" ] && [ "$git_author" != "unknown" ]; then
        author="$git_author"
      fi
    fi

    # Try to read formula from TOML as a secondary author hint
    local formula=""
    if [ -f "$filepath" ]; then
      formula="$(grep -m1 '^formula\s*=' "$filepath" 2>/dev/null | sed 's/^formula\s*=\s*"\{0,1\}//;s/"\{0,1\}$//' | tr -d ' ')" || true
      if [ -n "$formula" ]; then
        author="$formula"
      fi
    fi

    # Relative path from repo root
    local rel_path
    if [ -n "${git_root:-}" ]; then
      rel_path="${filepath#"${git_root}"/}"
    else
      rel_path="${filepath#./}"
    fi

    local item_id
    item_id="av-$(printf '%s' "$basename" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
    local item
    item=$(jq -n -c \
      --arg id "$item_id" \
      --arg kind "action-vault" \
      --arg path "$rel_path" \
      --arg title "$title" \
      --arg author "$author" \
      --arg ts "$file_ts" \
      '{id: $id, kind: $kind, path: $path, title: $title, author: $author, ts: $ts}')

    items="$(printf '%s' "$items" | jq -c --argjson item "$item" '. + [$item]')"
  done < <(find "$vault_path" -maxdepth 2 -type f -print0 2>/dev/null | sort -z -r)

  printf '%s' "$items"
}

# ── Scan Forge prediction issues ─────────────────────────────────────────────

# Returns JSON array of inbox items for issues labeled prediction/unreviewed.
scan_prediction_issues() {
  local url="${FORGE_URL%/}/api/v1/repos/${FORGE_REPO}/issues?type=issues&state=open&limit=100"
  local body_file headers_file
  body_file="$(mktemp_safe /tmp/snapshot-inbox-predictions.XXXXXX)"
  headers_file="$(mktemp_safe /tmp/snapshot-inbox-predictions-headers.XXXXXX)"

  if ! forge_get "$url" "$body_file" "$headers_file" >/dev/null 2>&1; then
    printf '[]'
    return
  fi

  jq -c --argjson label_id "$PREDICTION_LABEL_ID" '
    [ .[]
      | select(. != null)
      | select(
          (.labels // [])
          | map(select(.id == $label_id))
          | length > 0
        )
      | {
          id: ("forge-issue-" + (.number | tostring)),
          kind: "prediction",
          number: .number,
          title: .title,
          ts: .created_at
        }
    ]
  ' < "$body_file" 2>/dev/null || printf '[]'
}

# ── Scan Forge automation issues ─────────────────────────────────────────────

# Returns JSON array of inbox items for issues opened in the last 24h by
# automation accounts (bot usernames).
scan_automation_issues() {
  local url="${FORGE_URL%/}/api/v1/repos/${FORGE_REPO}/issues?type=issues&state=open&limit=100"
  local body_file headers_file
  body_file="$(mktemp_safe /tmp/snapshot-inbox-automation.XXXXXX)"
  headers_file="$(mktemp_safe /tmp/snapshot-inbox-automation-headers.XXXXXX)"

  if ! forge_get "$url" "$body_file" "$headers_file" >/dev/null 2>&1; then
    printf '[]'
    return
  fi

  local cutoff_epoch
  cutoff_epoch="$(date -d '24 hours ago' +%s 2>/dev/null)" || cutoff_epoch=0

  jq -c --argjson cutoff "$cutoff_epoch" '
    # Automation account name patterns (adjust as needed)
    def is_bot:
      (.user.login // "")
      | test("bot|op|agent|dispatcher|triage|reproduce|edge"; "i");

    [ .[]
      | select(. != null)
      | select(is_bot)
      | (.created_at | fromdateiso8601) as $created
      | select($created >= $cutoff)
      | {
          id: ("forge-issue-" + (.number | tostring)),
          kind: "forge-agent",
          number: .number,
          title: .title,
          author: .user.login,
          ts: .created_at
        }
    ]
  ' < "$body_file" 2>/dev/null || printf '[]'
}

# ── Scan completed threads ────────────────────────────────────────────────────

# Returns JSON array of inbox items for completed, unacked threads from the
# last 24 hours.
#
# Thread meta.json shape:
#   {"id":"del-abc123","query":"...","started":"...","status":"completed",
#    "completed":"...","result_summary":"..."}
#
# Ack marker: <THREADS_ROOT>/<task-id>/.acked
scan_completed_threads() {
  local threads_root="${THREADS_ROOT:-/var/lib/disinto/threads}"

  if [ ! -d "$threads_root" ]; then
    printf '[]'
    return
  fi

  local cutoff_epoch
  cutoff_epoch="$(date -d '24 hours ago' +%s 2>/dev/null)" || cutoff_epoch=0

  local items="[]"

  for thread_dir in "$threads_root"/*/; do
    [ -d "$thread_dir" ] || continue

    local meta_path="$thread_dir/meta.json"
    [ -f "$meta_path" ] || continue

    local task_id status
    task_id="$(basename "$thread_dir")"
    status="$(jq -r '.status // ""' "$meta_path" 2>/dev/null)" || continue

    # Only completed threads
    [ "$status" = "completed" ] || continue

    # Skip if acked
    [ -f "$thread_dir/.acked" ] && continue

    # Check age — use completed timestamp if available, fall back to started
    local ts_epoch
    local completed_ts
    completed_ts="$(jq -r '.completed // empty' "$meta_path" 2>/dev/null)" || completed_ts=""
    if [ -n "$completed_ts" ]; then
      ts_epoch="$(date -d "$completed_ts" +%s 2>/dev/null)" || ts_epoch=0
    else
      local started_ts
      started_ts="$(jq -r '.started // empty' "$meta_path" 2>/dev/null)" || started_ts=""
      ts_epoch="$(date -d "$started_ts" +%s 2>/dev/null)" || ts_epoch=0
    fi

    # Skip if older than 24h
    [ "$ts_epoch" -ge "$cutoff_epoch" ] 2>/dev/null || continue

    # Derive title from query (first line, truncated to 60 chars)
    local query title
    query="$(jq -r '.query // ""' "$meta_path" 2>/dev/null)" || query=""
    title="$(printf '%s' "$query" | head -n1 | cut -c1-60)"

    # Truncate summary to 200 chars
    local summary
    summary="$(jq -r '.result_summary // ""' "$meta_path" 2>/dev/null)" || summary=""
    summary="$(printf '%s' "$summary" | head -c 200)"

    local ts
    if [ -n "$completed_ts" ]; then
      ts="$completed_ts"
    else
      ts="$(date -u -d "@$ts_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)" || ts=""
    fi

    local item
    item=$(jq -n -c \
      --arg id "thread-del-${task_id#del-}" \
      --arg kind "thread-result" \
      --arg task_id "$task_id" \
      --arg title "$title" \
      --arg summary "$summary" \
      --arg ts "$ts" \
      '{id: $id, kind: $kind, task_id: $task_id, title: $title, summary: $summary, ts: $ts}')

    items="$(printf '%s' "$items" | jq -c --argjson item "$item" '. + [$item]')"
  done

  printf '%s' "$items"
}

# ── Merge and cap ─────────────────────────────────────────────────────────────

merge_inbox() {
  local vault_items prediction_items automation_items thread_items
  vault_items="$(scan_action_vault)"
  prediction_items="$(scan_prediction_issues)"
  automation_items="$(scan_automation_issues)"
  thread_items="$(scan_completed_threads)"

  # Merge all items, sort by timestamp descending, cap at 20
  jq -cn --argjson vault "$vault_items" \
        --argjson predictions "$prediction_items" \
        --argjson automation "$automation_items" \
        --argjson threads "$thread_items" '
    ($vault + $predictions + $automation + $threads)
    | sort_by(.ts) | reverse
    | .[:20]
    | {items: ., unread_count: length}
  ' 2>/dev/null || printf '{"items":[],"unread_count":0}'
}

# ── Merge into state.json ─────────────────────────────────────────────────────

main() {
  if [ ! -f "$SNAPSHOT_PATH" ]; then
    log "no state.json found — skipping (daemon not yet initialized)"
    return 0
  fi

  local inbox_data
  inbox_data="$(merge_inbox)"

  local tmpfile
  tmpfile="$(mktemp_safe "${SNAPSHOT_PATH}.inbox.XXXXXX")"

  # Read previous snapshot, merge inbox key, write atomically.
  jq -c --argjson inbox "$inbox_data" '.inbox = $inbox' "$SNAPSHOT_PATH" > "$tmpfile" 2>/dev/null
  mv -f "$tmpfile" "$SNAPSHOT_PATH"

  local unread_count
  unread_count=$(printf '%s' "$inbox_data" | jq -r '.unread_count')
  log "inbox snapshot merged — ${unread_count} unread item(s)"
}

main "$@"
