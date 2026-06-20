#!/usr/bin/env bash
# gardener-pr.sh — PR detection and creation helpers shared by gardener-run.sh
# and gardener-step.sh.
#
# Usage: source lib/gardener-pr.sh
#   detect_pr_number <branch_prefix>          # sets PR_NUMBER global
#   gardener_pr_find_by_branch <branch>       # prints PR number, returns 1 if not found
#   gardener_pr_create <branch> <title> <body> [base]  # prints PR number, returns 1 on failure
#
# Requires: GARDENER_PR_FILE, FORGE_TOKEN, FORGE_API

# ── Read PR_NUMBER from scratch file, fallback to Forgejo API search ─────
# Usage: detect_pr_number <branch_prefix>
#   e.g. detect_pr_number "chore/agents-md-"
detect_pr_number() {
  local branch_prefix="${1:?detect_pr_number: branch_prefix required}"

  PR_NUMBER=""
  if [ -f "${GARDENER_PR_FILE:-}" ]; then
    PR_NUMBER=$(tr -d '[:space:]' < "$GARDENER_PR_FILE")
  fi

  if [ -z "$PR_NUMBER" ]; then
    PR_NUMBER=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${FORGE_API}/pulls?state=open&limit=10" | \
      jq -r "[.[] | select(.head.ref | startswith(\"${branch_prefix}\"))] | .[0].number // empty") || true
  fi
}

# ── Find an open PR by head branch name ──────────────────────────────────
# Usage: gardener_pr_find_by_branch <branch>
#   Prints the PR number on stdout. Returns 1 if not found.
gardener_pr_find_by_branch() {
  local branch="${1:?gardener_pr_find_by_branch: branch required}"
  local pr_num

  pr_num=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API}/pulls?state=open&limit=20" | \
    jq -r --arg b "$branch" '.[] | select(.head.ref == $b) | .number' \
    | head -1) || true

  if [ -n "$pr_num" ]; then
    printf '%s' "$pr_num"
    return 0
  fi
  return 1
}

# ── Create a PR via Forgejo API ─────────────────────────────────────────
# Usage: gardener_pr_create <branch> <title> <body> [base_branch]
#   Prints the PR number on stdout. Returns 1 on failure.
#   Idempotent — returns existing PR number if one already exists.
gardener_pr_create() {
  local branch="${1:?gardener_pr_create: branch required}"
  local title="${2:?gardener_pr_create: title required}"
  local body="${3:?gardener_pr_create: body required}"
  local base="${4:-${PRIMARY_BRANCH:-main}}"
  local tmpfile resp http_code resp_body pr_num

  tmpfile=$(mktemp /tmp/gardener-pr-XXXXXX.json)
  jq -n --arg t "$title" --arg b "$body" --arg h "$branch" --arg base "$base" \
    '{title:$t, body:$b, head:$h, base:$base}' > "$tmpfile"

  resp=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API}/pulls" \
    --data-binary @"$tmpfile") || true
  rm -f "$tmpfile"

  http_code=$(printf '%s\n' "$resp" | tail -1)
  resp_body=$(printf '%s\n' "$resp" | sed '$d')

  case "$http_code" in
    200|201)
      pr_num=$(printf '%s' "$resp_body" | jq -r '.number')
      printf '%s' "$pr_num"
      return 0
      ;;
    409)
      # PR already exists — try to find it
      pr_num=$(gardener_pr_find_by_branch "$branch") || true
      if [ -n "$pr_num" ]; then
        printf '%s' "$pr_num"
        return 0
      fi
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}
