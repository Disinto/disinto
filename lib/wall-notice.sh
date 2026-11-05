#!/usr/bin/env bash
# =============================================================================
# lib/wall-notice.sh — one owner notice for a PR that changes a protected file
# (#2121)
#
# docs/design/notes/self-update.md, "The wall": the bots have write, not
# admin, so a PR that changes a file walled by lib/wall.sh (#2120) cannot be
# merged by them. Their merge attempt fails with HTTP 405, is retried and
# finally escalated (#1090), but the owner, who does not watch the forge, is
# never told — the PR just sits. This module closes that gap: a PR whose files
# hit the wall queues exactly one notice for the owner through lib/notice.sh
# (#2031), remembered by a marker under ${TAPE_DIR}/wall/ so it is never
# queued twice.
#
# Public (sourced; requires FORGE_TOKEN and FORGE_API):
#   wall_notice_once PR_NUM [PR_JSON]
#     1. If the marker ${TAPE_DIR:-/srv/disinto/tape}/wall/pr-<PR_NUM>.told
#        exists, return 0: the owner was already told about this PR.
#     2. GET ${FORGE_API}/pulls/<PR_NUM>/files?limit=50 and take each
#        .filename; a failed GET returns 0 with nothing written.
#     3. Pass the names through wall_hits disinto. No hit: return 0 with no
#        notice and no marker — a later push may add a walled file.
#     4. Queue notice_owner "disinto: PR #<n> cannot merge: it changes
#        protected files (<hits, comma-separated, at most 5>). Bots cannot
#        merge it; merge it as disinto-admin with the admin override, or close
#        it. <url>", where <url> is PR_JSON's .html_url when given.
#     5. When the notice is queued, mkdir -p the marker's directory and touch
#        the marker. A failed notice writes no marker, so a later merge
#        attempt retries.
#     Always returns 0: this helper must never break a merge attempt.
#
# Env seams: FORGE_TOKEN, FORGE_API (the API base, e.g.
# https://forge.example/api/v1); TAPE_DIR and NOTICES_DIR come from
# lib/notice.sh.
#
# Called from pr_merge's 405 branch (lib/pr-lifecycle.sh, #2122) when the
# caller sources this module; dev/dev-poll.sh does, wiring it into the dev
# merge paths.
# Tests: tests/acceptance/issue-2121.sh, tests/acceptance/issue-2122.sh.
# =============================================================================
set -euo pipefail

# shellcheck source=wall.sh
source "$(dirname "${BASH_SOURCE[0]}")/wall.sh"
# shellcheck source=notice.sh
source "$(dirname "${BASH_SOURCE[0]}")/notice.sh"

# wall_notice_once PR_NUM [PR_JSON] — tell the owner once about a PR that
# cannot merge because it changes a walled file. Always returns 0.
wall_notice_once() {
  local pr="${1:-}"
  local pr_json="${2:-}"

  if [ -z "$pr" ]; then
    printf 'wall-notice: wall_notice_once needs a PR number\n' >&2
    return 0
  fi

  if [ -z "${FORGE_API:-}" ] || [ -z "${FORGE_TOKEN:-}" ]; then
    printf 'wall-notice: FORGE_API and FORGE_TOKEN must be set\n' >&2
    return 0
  fi

  # 1. already told: one notice per PR, ever.
  local marker
  marker="${TAPE_DIR:-/srv/disinto/tape}/wall/pr-${pr}.told"
  if [ -e "$marker" ]; then
    return 0
  fi

  # 2. the PR's files; a failed GET means we know nothing — say nothing.
  local files
  files=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API%/}/pulls/${pr}/files?limit=50" 2>/dev/null \
    | jq -r '.[] | .filename // empty' 2>/dev/null) || return 0

  # 3. do any of them hit the wall?
  local hits
  hits=$(printf '%s\n' "$files" | wall_hits disinto) || return 0
  if [ -z "$hits" ]; then
    return 0
  fi

  # The first five hits, comma-separated: enough for the owner to judge the PR.
  local csv="" count=0 hit
  while IFS= read -r hit; do
    if [ -z "$hit" ]; then
      continue
    fi
    if [ "$count" -ge 5 ]; then
      break
    fi
    count=$((count + 1))
    if [ -n "$csv" ]; then
      csv+=", "
    fi
    csv+="$hit"
  done <<< "$hits"

  local url=""
  if [ -n "$pr_json" ]; then
    url=$(printf '%s' "$pr_json" | jq -r '.html_url // empty' 2>/dev/null) || url=""
  fi

  local text
  text="disinto: PR #${pr} cannot merge: it changes protected files (${csv}). Bots cannot merge it; merge it as disinto-admin with the admin override, or close it."
  if [ -n "$url" ]; then
    text+=" ${url}"
  fi

  # 5. only a queued notice writes the marker; a failed one retries later.
  if notice_owner "$text"; then
    if mkdir -p "$(dirname "$marker")" 2>/dev/null; then
      touch "$marker" 2>/dev/null
    fi
  fi
  return 0
}
