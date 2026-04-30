#!/usr/bin/env bash
# gardener-pr.sh — PR detection helpers shared by gardener-run.sh and gardener-step.sh.
#
# Usage: source lib/gardener-pr.sh
#   detect_pr_number <branch_prefix>   # sets PR_NUMBER global
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
