#!/usr/bin/env bash
# issue-lifecycle.sh — Reusable issue lifecycle library for agents
#
# Source after lib/env.sh:
#   source "$FACTORY_ROOT/lib/issue-lifecycle.sh"
#
# Required globals: FORGE_TOKEN, FORGE_API, FACTORY_ROOT
#
# Functions:
#   issue_claim           ISSUE_NUMBER
#   issue_release         ISSUE_NUMBER
#   issue_block           ISSUE_NUMBER REASON [RESULT_TEXT]
#   issue_close           ISSUE_NUMBER
#   issue_check_deps      ISSUE_NUMBER
#   issue_suggest_next
#   issue_post_refusal    ISSUE_NUMBER EMOJI TITLE BODY
#
# Output variables (set by issue_check_deps):
#   _ISSUE_BLOCKED_BY     array of blocking issue numbers
#   _ISSUE_SUGGESTION     suggested next issue number (or empty)
#
# Output variables (set by issue_suggest_next):
#   _ISSUE_NEXT           next unblocked backlog issue number (or empty)
#
# shellcheck shell=bash

set -euo pipefail

# Source secret scanner for redacting text before posting to issues
# shellcheck source=secret-scan.sh
source "$(dirname "${BASH_SOURCE[0]}")/secret-scan.sh"

# ---------------------------------------------------------------------------
# Internal log helper
# ---------------------------------------------------------------------------
_ilc_log() {
  if declare -f log >/dev/null 2>&1; then
    log "issue-lifecycle: $*"
  else
    printf '[%s] issue-lifecycle: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" >&2
  fi
}

# ---------------------------------------------------------------------------
# Label ID caching — lookup once per name, cache in globals.
# ---------------------------------------------------------------------------
declare -A _ILC_LABEL_IDS
_ILC_LABEL_IDS["backlog"]=""
_ILC_LABEL_IDS["in-progress"]=""
_ILC_LABEL_IDS["blocked"]=""

# _ilc_ensure_label_id LABEL_NAME [COLOR]
# Looks up label by name, creates if missing, caches in associative array.
_ilc_ensure_label_id() {
  local name="$1" color="${2:-#e0e0e0}"
  local current="${_ILC_LABEL_IDS[$name]:-}"
  if [ -n "$current" ]; then
    printf '%s' "$current"
    return 0
  fi
  local label_id
  label_id=$(forge_api GET "/labels" 2>/dev/null \
    | jq -r --arg n "$name" '.[] | select(.name == $n) | .id' 2>/dev/null || true)
  if [ -z "$label_id" ]; then
    label_id=$(curl -sf -X POST \
      -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      "${FORGE_API}/labels" \
      -d "$(jq -nc --arg n "$name" --arg c "$color" '{name:$n,color:$c}')" 2>/dev/null \
      | jq -r '.id // empty' 2>/dev/null || true)
  fi
  if [ -n "$label_id" ]; then
    _ILC_LABEL_IDS["$name"]="$label_id"
  fi
  printf '%s' "$label_id"
}

_ilc_backlog_id()      { _ilc_ensure_label_id "backlog"     "#0075ca"; }
_ilc_in_progress_id()  { _ilc_ensure_label_id "in-progress" "#1d76db"; }
_ilc_blocked_id()      { _ilc_ensure_label_id "blocked"     "#e11d48"; }

# ---------------------------------------------------------------------------
# Labels that indicate an issue belongs to a non-dev agent workflow.
# Any issue carrying one of these should NOT be touched by dev-poll's
# stale-detection or orphan-recovery logic.  See issue #608.
# ---------------------------------------------------------------------------
_ILC_NON_DEV_LABELS="bug-report vision in-triage prediction/unreviewed prediction/dismissed action formula"

# issue_is_dev_claimable COMMA_SEPARATED_LABELS
# Returns 0 if the issue's labels are compatible with dev-agent ownership,
# 1 if any non-dev label is present (meaning another agent owns this issue).
issue_is_dev_claimable() {
  local labels="$1"
  local lbl
  for lbl in $_ILC_NON_DEV_LABELS; do
    if echo ",$labels," | grep -qF ",$lbl,"; then
      return 1
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# issue_claim — assign issue to bot, add "in-progress" label, remove "backlog".
# Args: issue_number
# Returns: 0 on success, 1 if already assigned to another agent
# ---------------------------------------------------------------------------
issue_claim() {
  local issue="$1"

  # Get current bot identity
  local me
  me=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_URL}/api/v1/user" | jq -r '.login') || return 1

  # Check current assignee
  local current
  current=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API}/issues/${issue}" | jq -r '.assignee.login // ""') || return 1

  if [ -n "$current" ] && [ "$current" != "$me" ]; then
    _ilc_log "issue #${issue} already assigned to ${current} — skipping"
    return 1
  fi

  # Assign to self BEFORE adding in-progress label (issue #471).
  # This ordering ensures the assignee is set by the time other pollers
  # see the in-progress label, reducing the stale-detection race window.
  curl -sf -X PATCH \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API}/issues/${issue}" \
    -d "{\"assignees\":[\"${me}\"]}" >/dev/null 2>&1 || return 1

  # Verify the PATCH stuck.  Forgejo's assignees PATCH is last-write-wins, so
  # under concurrent claims from multiple dev agents two invocations can both
  # see .assignee == null at the pre-check, both PATCH, and the loser's write
  # gets silently overwritten (issue #830).  Re-reading the assignee closes
  # that TOCTOU window: only the actual winner observes its own login.
  # Labels are intentionally applied AFTER this check so the losing claim
  # leaves no stray "in-progress" label to roll back.
  local actual
  actual=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API}/issues/${issue}" | jq -r '.assignee.login // ""') || return 1
  if [ "$actual" != "$me" ]; then
    _ilc_log "issue #${issue} claim lost to ${actual:-<none>} — skipping"
    return 1
  fi

  local ip_id bl_id
  ip_id=$(_ilc_in_progress_id)
  bl_id=$(_ilc_backlog_id)
  if [ -n "$ip_id" ]; then
    curl -sf -X POST \
      -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      "${FORGE_API}/issues/${issue}/labels" \
      -d "{\"labels\":[${ip_id}]}" >/dev/null 2>&1 || true
  fi
  if [ -n "$bl_id" ]; then
    curl -sf -X DELETE \
      -H "Authorization: token ${FORGE_TOKEN}" \
      "${FORGE_API}/issues/${issue}/labels/${bl_id}" >/dev/null 2>&1 || true
  fi
  _ilc_log "claimed issue #${issue}"
  return 0
}

# ---------------------------------------------------------------------------
# issue_release — remove "in-progress" label, add "backlog" label, clear assignee.
# Args: issue_number
# ---------------------------------------------------------------------------
issue_release() {
  local issue="$1"

  # Clear assignee
  curl -sf -X PATCH \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API}/issues/${issue}" \
    -d '{"assignees":[]}' >/dev/null 2>&1 || true

  local ip_id bl_id
  ip_id=$(_ilc_in_progress_id)
  bl_id=$(_ilc_backlog_id)
  if [ -n "$ip_id" ]; then
    curl -sf -X DELETE \
      -H "Authorization: token ${FORGE_TOKEN}" \
      "${FORGE_API}/issues/${issue}/labels/${ip_id}" >/dev/null 2>&1 || true
  fi
  if [ -n "$bl_id" ]; then
    curl -sf -X POST \
      -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      "${FORGE_API}/issues/${issue}/labels" \
      -d "{\"labels\":[${bl_id}]}" >/dev/null 2>&1 || true
  fi
  _ilc_log "released issue #${issue}"
}

# ---------------------------------------------------------------------------
# _ilc_post_comment — Post a comment to an issue (internal helper)
# Args: issue_number body_text
# Uses a temp file to avoid large inline strings.
# ---------------------------------------------------------------------------
_ilc_post_comment() {
  local issue="$1" body="$2"

  local tmpfile tmpjson
  tmpfile=$(mktemp /tmp/ilc-comment-XXXXXX.md)
  tmpjson="${tmpfile}.json"
  printf '%s' "$body" > "$tmpfile"
  jq -Rs '{body:.}' < "$tmpfile" > "$tmpjson"
  curl -sf -o /dev/null -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API}/issues/${issue}/comments" \
    --data-binary @"$tmpjson" 2>/dev/null || true
  rm -f "$tmpfile" "$tmpjson"
}

# ---------------------------------------------------------------------------
# issue_block — add "blocked" label, post diagnostic comment, remove in-progress.
# Args: issue_number reason [result_text]
# The result_text (e.g. tmux pane capture) is redacted for secrets before posting.
# ---------------------------------------------------------------------------
issue_block() {
  local issue="$1" reason="$2" result_text="${3:-}"

  # Redact secrets from result text before posting to a public issue
  if [ -n "$result_text" ]; then
    result_text=$(redact_secrets "$result_text")
  fi

  # Build diagnostic comment via temp file (avoids large inline strings)
  local tmpfile
  tmpfile=$(mktemp /tmp/ilc-block-XXXXXX.md)
  {
    printf '### Blocked — issue #%s\n\n' "$issue"
    printf '| Field | Value |\n|---|---|\n'
    printf '| Exit reason | `%s` |\n' "$reason"
    printf '| Timestamp | `%s` |\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ -n "$result_text" ]; then
      printf '\n<details><summary>Diagnostic output</summary>\n\n```\n%s\n```\n</details>\n' "$result_text"
    fi
  } > "$tmpfile"

  # Post comment using shared helper
  _ilc_post_comment "$issue" "$(cat "$tmpfile")"
  rm -f "$tmpfile"

  # Remove in-progress, add blocked
  local ip_id bk_id
  ip_id=$(_ilc_in_progress_id)
  bk_id=$(_ilc_blocked_id)
  if [ -n "$ip_id" ]; then
    curl -sf -X DELETE \
      -H "Authorization: token ${FORGE_TOKEN}" \
      "${FORGE_API}/issues/${issue}/labels/${ip_id}" >/dev/null 2>&1 || true
  fi
  if [ -n "$bk_id" ]; then
    curl -sf -X POST \
      -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      "${FORGE_API}/issues/${issue}/labels" \
      -d "{\"labels\":[${bk_id}]}" >/dev/null 2>&1 || true
  fi

  _ilc_log "blocked issue #${issue}: ${reason}"
}

# ---------------------------------------------------------------------------
# issue_close — clear assignee, PATCH state to closed.
# Args: issue_number
# ---------------------------------------------------------------------------
issue_close() {
  local issue="$1"

  # Clear assignee before closing
  curl -sf -X PATCH \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API}/issues/${issue}" \
    -d '{"assignees":[]}' >/dev/null 2>&1 || true

  curl -sf -X PATCH \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API}/issues/${issue}" \
    -d '{"state":"closed"}' >/dev/null 2>&1 || true
  _ilc_log "closed issue #${issue}"
}

# ---------------------------------------------------------------------------
# issue_check_deps — parse Depends-on from issue body, check transitive deps.
# Args: issue_number
# Sets: _ISSUE_BLOCKED_BY (array), _ISSUE_SUGGESTION (string or empty)
# Returns: 0 if ready (all deps closed), 1 if blocked
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # output vars read by callers
issue_check_deps() {
  local issue="$1"
  _ISSUE_BLOCKED_BY=()
  _ISSUE_SUGGESTION=""

  # Fetch issue body
  local issue_body
  issue_body=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API}/issues/${issue}" | jq -r '.body // ""') || true

  if [ -z "$issue_body" ]; then
    return 0
  fi

  # Extract dep numbers via shared parser
  local dep_numbers
  dep_numbers=$(printf '%s' "$issue_body" | bash "${FACTORY_ROOT}/lib/parse-deps.sh") || true

  if [ -z "$dep_numbers" ]; then
    return 0
  fi

  # Check each direct dependency
  while IFS= read -r dep_num; do
    [ -z "$dep_num" ] && continue
    local dep_state
    dep_state=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${FORGE_API}/issues/${dep_num}" | jq -r '.state // "unknown"') || true
    if [ "$dep_state" != "closed" ]; then
      _ISSUE_BLOCKED_BY+=("$dep_num")
    fi
  done <<< "$dep_numbers"

  if [ "${#_ISSUE_BLOCKED_BY[@]}" -eq 0 ]; then
    return 0
  fi

  # Find suggestion: first open blocker whose own deps are all met
  local blocker
  for blocker in "${_ISSUE_BLOCKED_BY[@]}"; do
    local blocker_json blocker_state blocker_body
    blocker_json=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${FORGE_API}/issues/${blocker}") || continue
    blocker_state=$(printf '%s' "$blocker_json" | jq -r '.state') || continue
    [ "$blocker_state" != "open" ] && continue

    blocker_body=$(printf '%s' "$blocker_json" | jq -r '.body // ""')
    local blocker_deps
    blocker_deps=$(printf '%s' "$blocker_body" | bash "${FACTORY_ROOT}/lib/parse-deps.sh") || true

    local blocker_blocked=false
    if [ -n "$blocker_deps" ]; then
      local bd
      while IFS= read -r bd; do
        [ -z "$bd" ] && continue
        local bd_state
        bd_state=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
          "${FORGE_API}/issues/${bd}" | jq -r '.state // "unknown"') || true
        if [ "$bd_state" != "closed" ]; then
          blocker_blocked=true
          break
        fi
      done <<< "$blocker_deps"
    fi

    if [ "$blocker_blocked" = false ]; then
      _ISSUE_SUGGESTION="$blocker"
      break
    fi
  done

  _ilc_log "issue #${issue} blocked by: ${_ISSUE_BLOCKED_BY[*]}$([ -n "$_ISSUE_SUGGESTION" ] && printf ', suggest #%s' "$_ISSUE_SUGGESTION")"
  return 1
}

# ---------------------------------------------------------------------------
# issue_suggest_next — find next unblocked backlog issue.
# Sets: _ISSUE_NEXT (string or empty)
# Returns: 0 if found, 1 if none available
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # output vars read by callers
issue_suggest_next() {
  _ISSUE_NEXT=""

  local issues_json
  issues_json=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API}/issues?state=open&labels=backlog&limit=20&type=issues") || true

  if [ -z "$issues_json" ] || [ "$issues_json" = "null" ]; then
    return 1
  fi

  local issue_nums
  issue_nums=$(printf '%s' "$issues_json" | jq -r '.[].number') || true

  local num
  while IFS= read -r num; do
    [ -z "$num" ] && continue
    local body dep_nums
    body=$(printf '%s' "$issues_json" | \
      jq -r --argjson n "$num" '.[] | select(.number == $n) | .body // ""')
    dep_nums=$(printf '%s' "$body" | bash "${FACTORY_ROOT}/lib/parse-deps.sh") || true

    local all_met=true
    if [ -n "$dep_nums" ]; then
      local dep
      while IFS= read -r dep; do
        [ -z "$dep" ] && continue
        local dep_state
        dep_state=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
          "${FORGE_API}/issues/${dep}" | jq -r '.state // "open"') || dep_state="open"
        if [ "$dep_state" != "closed" ]; then
          all_met=false
          break
        fi
      done <<< "$dep_nums"
    fi

    if [ "$all_met" = true ]; then
      _ISSUE_NEXT="$num"
      _ilc_log "next unblocked issue: #${num}"
      return 0
    fi
  done <<< "$issue_nums"

  _ilc_log "no unblocked backlog issues found"
  return 1
}

# ---------------------------------------------------------------------------
# issue_post_refusal — post structured refusal comment with dedup check.
# Args: issue_number emoji title body
# ---------------------------------------------------------------------------
issue_post_refusal() {
  local issue="$1" emoji="$2" title="$3" body="$4"

  # Dedup: skip if recent comments already contain this title
  local last_has_title
  last_has_title=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API}/issues/${issue}/comments?limit=5" | \
    jq -r --arg t "Dev-agent: ${title}" \
    '[.[] | .body // ""] | any(contains($t)) | tostring') || true
  if [ "$last_has_title" = "true" ]; then
    _ilc_log "skipping duplicate refusal comment: ${title}"
    return 0
  fi

  local comment tmpfile
  comment="${emoji} **Dev-agent: ${title}**

${body}

---
*Automated assessment by dev-agent · $(date -u '+%Y-%m-%d %H:%M UTC')*"

  tmpfile=$(mktemp /tmp/ilc-refusal-XXXXXX.txt)
  printf '%s' "$comment" > "$tmpfile"
  jq -Rs '{body: .}' < "$tmpfile" > "${tmpfile}.json"
  curl -sf -o /dev/null -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API}/issues/${issue}/comments" \
    --data-binary @"${tmpfile}.json" 2>/dev/null || \
    _ilc_log "WARNING: failed to post refusal comment on issue #${issue}"
  rm -f "$tmpfile" "${tmpfile}.json"
}
