#!/usr/bin/env bash
# =============================================================================
# .claude/skills/forge/list-issues.sh — list Forgejo issues for chat-Claude
#
# Part of the chat-Claude operator surface (#727). Wraps the on-box Forgejo
# REST API at $FORGE_URL using $FACTORY_FORGE_PAT (rendered from
# kv/disinto/chat by nomad/jobs/edge.hcl, loaded into env by
# docker/edge/entrypoint-edge.sh).
#
# Output:
#   one issue per line, format: #<num> [<labels>] <title>
#   labels are comma-separated. Empty bracket "[]" when none.
#
# Usage:
#   list-issues.sh [--state open|closed|all] [--label <name>]
#                  [--limit N] [--repo <owner/name>]
# =============================================================================
set -euo pipefail

state="open"
label=""
limit="50"
repo="${FORGE_REPO:-disinto-admin/disinto}"

while [ $# -gt 0 ]; do
  case "$1" in
    --state) state="${2:?--state needs a value}"; shift 2 ;;
    --label) label="${2:?--label needs a value}"; shift 2 ;;
    --limit) limit="${2:?--limit needs a value}"; shift 2 ;;
    --repo)  repo="${2:?--repo needs a value}";   shift 2 ;;
    -h|--help)
      sed -n '2,17p' "$0" | sed 's|^# \{0,1\}||'
      exit 0
      ;;
    *)
      printf 'list-issues: unknown arg: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

case "$state" in open|closed|all) ;; *)
  printf 'list-issues: --state must be open|closed|all (got %s)\n' "$state" >&2
  exit 2
  ;;
esac

if ! [[ "$limit" =~ ^[0-9]+$ ]]; then
  printf 'list-issues: --limit must be a positive integer (got %s)\n' "$limit" >&2
  exit 2
fi

: "${FORGE_URL:?FORGE_URL not set — check nomad/jobs/edge.hcl local/forge.env render}"
: "${FACTORY_FORGE_PAT:?FACTORY_FORGE_PAT not set — run tools/vault-seed-chat.sh and restart edge}"

# Build query string. Forgejo accepts ?type=issues to suppress PRs (the
# /issues endpoint returns both by default).
qs="type=issues&state=${state}&limit=${limit}"
if [ -n "$label" ]; then
  qs="${qs}&labels=${label}"
fi

url="${FORGE_URL%/}/api/v1/repos/${repo}/issues?${qs}"

# curl: -f fails on HTTP errors; -sS is silent but shows errors on stderr;
# --max-time guards against a hung Forgejo.
body=$(curl -fsS --max-time 15 \
  -H "Authorization: token ${FACTORY_FORGE_PAT}" \
  -H "Accept: application/json" \
  "$url")

# jq: render one issue per line. labels[] map to .name, joined.
printf '%s\n' "$body" | jq -r \
  '.[] | "#\(.number) [\((.labels // []) | map(.name) | join(","))] \(.title)"'
