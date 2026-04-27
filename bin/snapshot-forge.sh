#!/usr/bin/env bash
# =============================================================================
# snapshot-forge.sh — forge-collector for snapshot daemon
#
# Queries Forgejo for open issues and PRs, classifies by label/status, and
# merges into state.json under key "forge". Invoked by the snapshot-daemon
# loop each tick.
#
# Environment:
#   FACTORY_FORGE_PAT  — Forge admin PAT (required)
#   FORGE_URL          — Forgejo base URL (default http://localhost:3000)
#   FORGE_REPO         — repo slug owner/name (default disinto-admin/disinto)
#   SNAPSHOT_PATH      — path to state.json (default /var/lib/disinto/snapshot/state.json)
#   FORGE_ETAG_PATH    — path for cached ETag file (default /tmp/snapshot-forge.etag)
#   FORGE_TIMEOUT      — per-call timeout in seconds (default 15)
#
# Label IDs for issue classification:
#   backlog=2, in-progress=6, blocked=3, underspecified=16, vision=17
#
# PR status taxonomy:
#   awaiting-review   — no reviews
#   changes-requested — at least one REQUEST_CHANGES (non-stale)
#   approved-not-merged — at least one APPROVED (non-stale) but not yet merged
#   mergeable-failure — CI not passing
#
# Output shape:
#   {"forge":{"backlog_count":N,"in_progress_count":N,...,"prs_open":[...],"prs_blocked":[]}}
#
# ETag/If-None-Match: skips API call if forge returns 304.
# =============================================================================
set -euo pipefail

: "${FACTORY_FORGE_PAT:?FACTORY_FORGE_PAT is required}"
FORGE_URL="${FORGE_URL:-http://localhost:3000}"
FORGE_REPO="${FORGE_REPO:-disinto-admin/disinto}"
SNAPSHOT_PATH="${SNAPSHOT_PATH:-/var/lib/disinto/snapshot/state.json}"
FORGE_ETAG_PATH="${FORGE_ETAG_PATH:-/tmp/snapshot-forge.etag}"
FORGE_TIMEOUT="${FORGE_TIMEOUT:-15}"

# Label IDs for issue classification
readonly BACKLOG_LABEL_ID=2
readonly INPROGRESS_LABEL_ID=6
readonly BLOCKED_LABEL_ID=3
readonly UNDERSPECIFIED_LABEL_ID=16
readonly VISION_LABEL_ID=17

log() {
  printf '[%s] snapshot-forge: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

# ── Temp file tracking ───────────────────────────────────────────────────────

TMPFILES=()

# Assigns through a global `_TMPFILE` rather than printing to stdout. Reason:
# command substitution forks a subshell, so any TMPFILES+=() inside it is
# discarded when the subshell exits — the parent's array stays empty and
# the cleanup trap rm -fs nothing. Calling mktemp_safe directly (no $(…))
# keeps the array updates in the parent shell where the trap can see them.
mktemp_safe() {
  _TMPFILE="$(mktemp "$@")"
  TMPFILES+=("$_TMPFILE")
}

cleanup() {
  rm -f "${TMPFILES[@]}" 2>/dev/null || true
}
trap cleanup EXIT

# ── ETag helpers ─────────────────────────────────────────────────────────────

cached_etag() {
  cat "${FORGE_ETAG_PATH}" 2>/dev/null || true
}

save_etag() {
  printf '%s' "$1" > "${FORGE_ETAG_PATH}"
}

# ── Forge HTTP GET with ETag support ─────────────────────────────────────────
# Writes response body to $FORGE_BODY_FILE, headers to $FORGE_HEADERS_FILE.
# Returns 2 on 304 (Not Modified), 1 on HTTP error, 0 on success.

FORGE_BODY_FILE=""
FORGE_HEADERS_FILE=""

forge_get() {
  local url="$1"
  local etag
  etag="$(cached_etag)"

  local -a curl_args=(
    -fsS --max-time "$FORGE_TIMEOUT"
    -H "Authorization: token ${FACTORY_FORGE_PAT}"
    -H "Accept: application/json"
  )

  if [ -n "$etag" ]; then
    curl_args+=(-H "If-None-Match: ${etag}")
  fi

  curl_args+=(-D "$FORGE_HEADERS_FILE" -o "$FORGE_BODY_FILE" "$url")

  local http_code
  http_code="$(curl -w '%{http_code}' "${curl_args[@]}")" || return 1

  if [ "$http_code" = "304" ]; then
    log "304 Not Modified — skipping ($url)"
    return 2
  fi

  if [ "$http_code" != "200" ]; then
    log "HTTP $http_code from $url"
    return 1
  fi

  # Persist ETag for future requests
  local resp_etag
  resp_etag="$(grep -i '^etag:' "$FORGE_HEADERS_FILE" 2>/dev/null | head -1 | sed 's/^[Ee][Tt][Aa][Gg]: *//' | tr -d '\r\n')" || true
  if [ -n "$resp_etag" ]; then
    save_etag "$resp_etag"
  fi

  return 0
}

# ── Fetch issues ─────────────────────────────────────────────────────────────

fetch_issues() {
  local url="${FORGE_URL%/}/api/v1/repos/${FORGE_REPO}/issues?type=issues&state=open&limit=100"
  mktemp_safe
  FORGE_BODY_FILE="$_TMPFILE"
  mktemp_safe
  FORGE_HEADERS_FILE="$_TMPFILE"

  forge_get "$url" || {
    rm -f "$FORGE_BODY_FILE" "$FORGE_HEADERS_FILE"
    return 1
  }
  cat "$FORGE_BODY_FILE"
}

# ── Fetch PRs ────────────────────────────────────────────────────────────────

fetch_pulls() {
  local url="${FORGE_URL%/}/api/v1/repos/${FORGE_REPO}/issues?type=pulls&state=open&limit=100"
  mktemp_safe
  FORGE_BODY_FILE="$_TMPFILE"
  mktemp_safe
  FORGE_HEADERS_FILE="$_TMPFILE"

  forge_get "$url" || {
    rm -f "$FORGE_BODY_FILE" "$FORGE_HEADERS_FILE"
    return 1
  }
  cat "$FORGE_BODY_FILE"
}

# ── Fetch reviews for a PR ───────────────────────────────────────────────────

fetch_pr_reviews() {
  local pr_number="$1"
  local url="${FORGE_URL%/}/api/v1/repos/${FORGE_REPO}/pulls/${pr_number}/reviews"
  local tmpfile
  mktemp_safe /tmp/snapshot-forge-pr-reviews.XXXXXX
  tmpfile="$_TMPFILE"
  curl -fsS --max-time "$FORGE_TIMEOUT" \
    -H "Authorization: token ${FACTORY_FORGE_PAT}" \
    -H "Accept: application/json" \
    -o "$tmpfile" "$url" 2>/dev/null && cat "$tmpfile" || printf '[]'
}

# ── Fetch CI commit status for a PR ─────────────────────────────────────────

fetch_pr_commit_status() {
  local pr_number="$1"
  local url="${FORGE_URL%/}/api/v1/repos/${FORGE_REPO}/pulls/${pr_number}/status"
  local tmpfile
  mktemp_safe /tmp/snapshot-forge-pr-status.XXXXXX
  tmpfile="$_TMPFILE"
  curl -fsS --max-time "$FORGE_TIMEOUT" \
    -H "Authorization: token ${FACTORY_FORGE_PAT}" \
    -H "Accept: application/json" \
    -o "$tmpfile" "$url" 2>/dev/null && cat "$tmpfile" || printf '{"state":"pending"}'
}

# ── Build forge data ─────────────────────────────────────────────────────────

build_forge_data() {
  local issues_json pulls_json
  issues_json="$(fetch_issues)" || {
    printf '{"backlog_count":0,"in_progress_count":0,"blocked_count":0,"underspecified_count":0,"vision_count":0,"prs_open":[],"prs_blocked":[]}'
    return
  }
  pulls_json="$(fetch_pulls)" || {
    printf '{"backlog_count":0,"in_progress_count":0,"blocked_count":0,"underspecified_count":0,"vision_count":0,"prs_open":[],"prs_blocked":[]}'
    return
  }

  # Classify issues by label ID via jq; emit intermediate JSON with pulls for PR processing.
  local classified
  classified=$(printf '%s' "$issues_json" | jq -c --argjson pulls "$pulls_json" \
    --argjson bl_id "$BACKLOG_LABEL_ID" \
    --argjson ip_id "$INPROGRESS_LABEL_ID" \
    --argjson bk_id "$BLOCKED_LABEL_ID" \
    --argjson us_id "$UNDERSPECIFIED_LABEL_ID" \
    --argjson vi_id "$VISION_LABEL_ID" '

    # ── Classify issues by label ID ──
    (map(select(. != null)) | map(
      if .labels then
        [.labels[] | .id | tostring] | join(",")
      else
        ""
      end
    )) as $issue_label_ids |

    ($issue_label_ids | map(select(. == ($bl_id | tostring))) | length) as $backlog_count |
    ($issue_label_ids | map(select(. == ($ip_id | tostring))) | length) as $inprogress_count |
    ($issue_label_ids | map(select(. == ($bk_id | tostring))) | length) as $blocked_count |
    ($issue_label_ids | map(select(. == ($us_id | tostring))) | length) as $underspecified_count |
    ($issue_label_ids | map(select(. == ($vi_id | tostring))) | length) as $vision_count |

    {
      backlog_count: $backlog_count,
      in_progress_count: $inprogress_count,
      blocked_count: $blocked_count,
      underspecified_count: $underspecified_count,
      vision_count: $vision_count,
      _pulls_raw: $pulls
    }
  ' 2>/dev/null) || printf '{}'

  # Extract pulls for PR classification
  local pulls_for_prs
  pulls_for_prs="$(printf '%s' "$classified" | jq -r '._pulls_raw // "[]"')"

  # Classify PRs
  local pr_result
  pr_result="$(classify_prs "$pulls_for_prs")"

  local prs_open prs_blocked
  prs_open="$(printf '%s' "$pr_result" | sed -n '1p')"
  prs_blocked="$(printf '%s' "$pr_result" | sed -n '2p')"

  # Merge PR results into classified data
  printf '%s' "$classified" | jq -c \
    --argjson prs_open "$prs_open" \
    --argjson prs_blocked "$prs_blocked" \
    'del(._pulls_raw) | .prs_open = $prs_open | .prs_blocked = $prs_blocked'
}

# ── Classify PRs ─────────────────────────────────────────────────────────────

classify_prs() {
  local pulls_json="$1"
  local now_epoch
  now_epoch="$(date +%s)"

  local prs_open="[]"
  local prs_blocked="[]"

  local pr_count
  pr_count="$(printf '%s' "$pulls_json" | jq 'length')" || return

  local i
  for ((i = 0; i < pr_count; i++)); do
    local pr_number pr_title merged created_at
    pr_number="$(printf '%s' "$pulls_json" | jq -r ".[$i].number // empty")" || continue
    [ -z "$pr_number" ] && continue

    pr_title="$(printf '%s' "$pulls_json" | jq -r ".[$i].title // empty")" || true
    merged="$(printf '%s' "$pulls_json" | jq -r ".[$i].merged // false")" || true
    created_at="$(printf '%s' "$pulls_json" | jq -r ".[$i].created_at // empty")" || true

    # Skip if already merged
    [ "$merged" = "true" ] && continue

    # Fetch reviews
    local reviews_json
    reviews_json="$(fetch_pr_reviews "$pr_number")"

    # Check for REQUEST_CHANGES (non-stale)
    local has_changes
    has_changes="$(printf '%s' "$reviews_json" | jq -c '[.[] | select(.state == "REQUEST_CHANGES" and (.stale == false or .stale == null))] | length')" || true
    has_changes="${has_changes:-0}"

    # Check for APPROVED (non-stale)
    local has_approved
    has_approved="$(printf '%s' "$reviews_json" | jq -c '[.[] | select(.state == "APPROVED" and (.stale == false or .stale == null))] | length')" || true
    has_approved="${has_approved:-0}"

    # Determine status
    local status="awaiting-review"
    if [ "$has_changes" -gt 0 ]; then
      status="changes-requested"
    elif [ "$has_approved" -gt 0 ]; then
      status="approved-not-merged"
    fi

    # Check CI status for mergeable-failure
    if [ "$status" = "awaiting-review" ] || [ "$status" = "approved-not-merged" ]; then
      local ci_state
      ci_state="$(fetch_pr_commit_status "$pr_number" | jq -r '.state // "pending"')" || true
      if [ "$ci_state" != "success" ]; then
        status="mergeable-failure"
      fi
    fi

    # Calculate age in hours
    local age_hours=0
    if [ -n "$created_at" ] && [ "$created_at" != "null" ]; then
      local created_epoch
      created_epoch="$(date -d "$created_at" +%s 2>/dev/null)" || true
      if [ -n "${created_epoch:-}" ]; then
        age_hours=$(( (now_epoch - created_epoch) / 3600 ))
      fi
    fi

    # Build PR entry
    local pr_entry
    pr_entry=$(jq -n -c \
      --argjson num "$pr_number" \
      --arg title "$pr_title" \
      --arg status "$status" \
      --argjson age "$age_hours" \
      '{number: $num, title: $title, status: $status, age_hours: $age}')

    # Classify into prs_open or prs_blocked (compact output so each is a single line)
    case "$status" in
      mergeable-failure)
        prs_blocked=$(printf '%s' "$prs_blocked" | jq -c --argjson entry "$pr_entry" '. + [$entry]')
        ;;
      *)
        prs_open=$(printf '%s' "$prs_open" | jq -c --argjson entry "$pr_entry" '. + [$entry]')
        ;;
    esac
  done

  printf '%s\n%s' "$prs_open" "$prs_blocked"
}

# ── Merge into state.json ─────────────────────────────────────────────────────

main() {
  if [ ! -f "$SNAPSHOT_PATH" ]; then
    log "no state.json found — skipping (daemon not yet initialized)"
    return 0
  fi

  local forge_data
  forge_data="$(build_forge_data)"

  local tmpfile
  mktemp_safe "${SNAPSHOT_PATH}.forge.XXXXXX"
  tmpfile="$_TMPFILE"

  # Read previous snapshot, merge forge key under .collectors.forge, write atomically.
  jq -c --argjson forge "$forge_data" '.collectors.forge = $forge' "$SNAPSHOT_PATH" > "$tmpfile" 2>/dev/null
  chmod 644 "$tmpfile"
  mv -f "$tmpfile" "$SNAPSHOT_PATH"

  local backlog_count
  backlog_count=$(printf '%s' "$forge_data" | jq -r '.backlog_count')
  log "forge snapshot merged — backlog=$backlog_count"
}

main "$@"
