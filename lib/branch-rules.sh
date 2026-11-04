#!/usr/bin/env bash
# =============================================================================
# lib/branch-rules.sh — Forgejo branch rules for the rollout branches (#2110)
#
# The self-update rollout moves two branches of the project repo, `live` and
# `canary` (docs/design/notes/self-update.md). This module creates them when
# they are missing and puts the push rule on `live` through the forge routes
# Forgejo 11 actually has:
#
#   GET   /api/v1/repos/<repo>/branch_protections/<rule>
#   POST  /api/v1/repos/<repo>/branch_protections
#   PATCH /api/v1/repos/<repo>/branch_protections/<rule>
#
# (lib/branch-protection.sh talks to /branches/<b>/protection, which this forge
# answers 404; this file is the working helper for rules.)
#
# Required env: FORGE_TOKEN, FORGE_URL. This module does NOT source lib/env.sh:
# a repo admin runs it with the two variables in the environment.
#
# Run directly (a deliberate step by a repo admin, #2110):
#   FORGE_URL=... FORGE_TOKEN=... lib/branch-rules.sh rollout-branches disinto-admin/disinto
#
# Or source it and call:
#   branch_rule_apply REPO RULE JSON     — create or patch one rule
#   rollout_branches_setup REPO          — create live + canary, rule on live
# =============================================================================
set -euo pipefail

# The rule `live` carries: only supervisor-bot and disinto-admin may push it,
# only disinto-admin may merge it. `canary` gets no rule on purpose — the forge
# refuses every non-fast-forward push to a protected branch, and a rollback
# moves `canary` back.
_BR_LIVE_RULE_JSON='{"enable_push":true,"enable_push_whitelist":true,"push_whitelist_usernames":["supervisor-bot","disinto-admin"],"enable_merge_whitelist":true,"merge_whitelist_usernames":["disinto-admin"]}'

_br_usage() {
  cat >&2 <<'EOF'
Usage: lib/branch-rules.sh rollout-branches <owner/repo>

  rollout-branches <owner/repo>   create the live and canary branches at main
                                  (existing ones are left where they are) and
                                  apply the push rule to live.

Requires FORGE_URL and FORGE_TOKEN in the environment (the token of a repo
admin, e.g. disinto-admin).
EOF
}

# _br_require_env — fail with one stderr line when the forge env is missing.
_br_require_env() {
  if [ -z "${FORGE_URL:-}" ] || [ -z "${FORGE_TOKEN:-}" ]; then
    printf 'branch-rules: FORGE_URL and FORGE_TOKEN must be set\n' >&2
    return 1
  fi
  return 0
}

# _br_api_base REPO — the repo's API base, e.g.
# https://forge.example/api/v1/repos/disinto-admin/disinto
_br_api_base() {
  printf '%s/api/v1/repos/%s' "${FORGE_URL%/}" "$1"
}

# _br_request METHOD URL [BODY] — one forge call; prints the HTTP status code.
# A transport failure prints 0.
_br_request() {
  local method="$1" url="$2" body="${3:-}"
  local args=(-s -o /dev/null -w '%{http_code}' -X "$method"
    -H "Authorization: token ${FORGE_TOKEN}"
    -H "Content-Type: application/json")
  if [ -n "$body" ]; then
    args+=(-d "$body")
  fi
  local code
  code=$(curl "${args[@]}" "$url" 2>/dev/null || echo 0)
  printf '%s' "$code"
}

# _br_is_2xx CODE — 0 when CODE starts with 2.
_br_is_2xx() {
  case "${1:-}" in
    2*) return 0 ;;
    *) return 1 ;;
  esac
}

# _br_rule_body JSON RULE — JSON with "rule_name": RULE added.
# Pure shell: no jq dependency, so the helper runs wherever curl does.
_br_rule_body() {
  local json="${1:-}" rule="$2"
  # strip surrounding whitespace
  json="${json#"${json%%[![:space:]]*}"}"
  json="${json%"${json##*[![:space:]]}"}"
  if [ -z "$json" ] || [ "$json" = "{}" ]; then
    printf '{"rule_name":"%s"}' "$rule"
  elif [ "${json:0:1}" = "{" ]; then
    printf '{"rule_name":"%s",%s' "$rule" "${json:1}"
  else
    printf '{"rule_name":"%s"}' "$rule"
  fi
}

# -----------------------------------------------------------------------------
# branch_rule_apply REPO RULE JSON
#
# Patch the rule RULE of REPO with JSON, creating it when it does not exist:
#   GET  <base>/branch_protections/RULE
#     200 -> PATCH that URL with JSON (the forge changes only the fields JSON
#             names)
#     404 -> POST <base>/branch_protections with JSON plus "rule_name": RULE
# Returns 0 on a 2xx answer, 1 otherwise with one stderr line naming the HTTP
# code.
# -----------------------------------------------------------------------------
branch_rule_apply() {
  if [ "$#" -ne 3 ]; then
    printf 'branch-rules: branch_rule_apply needs REPO RULE JSON\n' >&2
    return 2
  fi
  local repo="$1" rule="$2" json="$3"
  _br_require_env || return 1

  local base code
  base=$(_br_api_base "$repo")
  code=$(_br_request GET "$base/branch_protections/$rule" "")

  if [ "$code" = "200" ]; then
    code=$(_br_request PATCH "$base/branch_protections/$rule" "$json")
    if _br_is_2xx "$code"; then
      return 0
    fi
    printf 'branch-rules: PATCH rule %s on %s: HTTP %s\n' "$rule" "$repo" "$code" >&2
    return 1
  fi

  if [ "$code" = "404" ]; then
    code=$(_br_request POST "$base/branch_protections" "$(_br_rule_body "$json" "$rule")")
    if _br_is_2xx "$code"; then
      return 0
    fi
    printf 'branch-rules: POST rule %s on %s: HTTP %s\n' "$rule" "$repo" "$code" >&2
    return 1
  fi

  printf 'branch-rules: GET rule %s on %s: HTTP %s\n' "$rule" "$repo" "$code" >&2
  return 1
}

# -----------------------------------------------------------------------------
# rollout_branches_setup REPO
#
# Create the rollout branches: for `live` and `canary`, GET <base>/branches/B;
# on 404 POST <base>/branches with the branch taken at main. An existing branch
# is left where it is. Then apply the push rule to `live` (and only to `live`).
# Returns 1 at the first failure.
# -----------------------------------------------------------------------------
rollout_branches_setup() {
  if [ "$#" -ne 1 ] || [ -z "${1:-}" ]; then
    printf 'branch-rules: rollout_branches_setup needs REPO (owner/repo)\n' >&2
    return 2
  fi
  local repo="$1"
  _br_require_env || return 1

  local base branch code
  base=$(_br_api_base "$repo")
  for branch in live canary; do
    code=$(_br_request GET "$base/branches/$branch" "")
    if [ "$code" = "404" ]; then
      code=$(_br_request POST "$base/branches" \
        "{\"new_branch_name\":\"$branch\",\"old_branch_name\":\"main\"}")
      if ! _br_is_2xx "$code"; then
        printf 'branch-rules: POST branch %s on %s: HTTP %s\n' "$branch" "$repo" "$code" >&2
        return 1
      fi
    elif ! _br_is_2xx "$code"; then
      printf 'branch-rules: GET branch %s on %s: HTTP %s\n' "$branch" "$repo" "$code" >&2
      return 1
    fi
  done

  branch_rule_apply "$repo" live "$_BR_LIVE_RULE_JSON"
}

# -----------------------------------------------------------------------------
# CLI: run directly, not sourced.
# -----------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cmd="${1:-}"
  if [ "$cmd" = "rollout-branches" ]; then
    shift
    if [ "$#" -ne 1 ]; then
      _br_usage
      exit 2
    fi
    rollout_branches_setup "$1"
    exit $?
  fi
  _br_usage
  exit 2
fi
