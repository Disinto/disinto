#!/usr/bin/env bash
# =============================================================================
# planner/pitch-open.sh — open at most one planner pitch (#1976)
#
# A planner pitch is an ops-repo PR titled `architect: <title>` that adds
# sprints/<slug>.md. This file opens that PR as the token user and refuses a
# second one while planner-bot already has an `architect:` PR open. It does
# not merge, does not file an issue, and does not source lib/env.sh.
#
# Functions (sourced; called by planner/pitch-or-idle.sh):
#   planner_pitch_pending
#     GET /repos/${FORGE_OPS_REPO}/pulls?state=open&limit=50. Print the
#     .number of the first item whose .title starts with `architect:` and
#     whose .user.login equals ${PLANNER_LOGIN:-planner-bot}. Print nothing
#     and return 0 when none. Print nothing and return 1 when the GET fails,
#     the body is not a JSON array, or the array length is 50 (a full page
#     is not a complete list, so a second pitch must not be opened).
#   planner_pitch_open TITLE SLUG FILE [PROBE_SRC PROBE_DEST]
#     1. FILE missing, pitch_sprint_block fails, or FILE contains
#        `filer:begin`: print nothing, return 1, no forge call.
#     2. A pending number: print nothing, return 0. pending's failure:
#        print nothing, return 1.
#     3. POST /branches with new_branch_name `planner/pitch-<SLUG>` and
#        old_branch_name ${PRIMARY_BRANCH:-main}, the same call
#        formulas/pitch-vision.toml uses. A failed create is ignored only
#        when a later GET of that branch shows it. Otherwise return 1.
#     4. PUT /contents/sprints/<SLUG>.md on that branch. Message
#        `architect: <TITLE>`. Content is the base64 of FILE. No author and
#        no committer, so the token user is the author. Include sha only
#        when a GET of that path on the branch returns one.
#     5. POST /pulls. Title `architect: <TITLE>`, head the pitch branch,
#        base the primary branch, body the file text. Print .number.
#        Return 1 when it is empty.
#     PROBE_SRC and PROBE_DEST are both unset (no probe PUT), both set, or
#     the call is refused. Exactly one set: print nothing, return 1, no
#     forge call. Both set: PROBE_SRC must be a non-empty file, and
#     PROBE_DEST must match ^probes/[A-Za-z0-9][A-Za-z0-9.-]*\.sh$ and must
#     not contain `..`. Otherwise print nothing, return 1, no forge call.
#     That check is before step 2. After step 4 and before step 5, PUT
#     /contents/<PROBE_DEST> on the same branch (same message, no author,
#     no committer, sha only when a GET returns one). A failed PUT returns
#     1 and does not POST the pull.
#
# Env: FORGE_TOKEN, FORGE_API_BASE, FORGE_OPS_REPO, PRIMARY_BRANCH (default
# main), PLANNER_LOGIN (default planner-bot).
# Requires: curl, jq, base64. Sources lib/pitch.sh.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/pitch.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/pitch.sh"

# A probe added beside the sprint file. Two dots are rejected even though
# the character class would allow them (`probes/can..sense.sh`).
_PLANNER_PITCH_PROBE_RE='^probes/[A-Za-z0-9][A-Za-z0-9.-]*\.sh$'

# _planner_pitch_put BRANCH PATH SRC MESSAGE — commit SRC at PATH on BRANCH.
# GET contents/PATH?ref=BRANCH first; include sha only when that GET returns
# one. A missing blob is not a failure. Return 1 when the PUT fails.
_planner_pitch_put() {
  local branch="$1" path="$2" src="$3" message="$4"
  local api sha="" body="" content payload
  api="${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}"

  if body="$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${api}/contents/${path}?ref=${branch}")"; then
    sha="$(printf '%s' "$body" | jq -r '.sha // empty')" || sha=""
  fi

  content="$(base64 -w0 < "$src")" || return 1
  if [ -n "$sha" ]; then
    payload="$(jq -n \
      --arg branch "$branch" \
      --arg message "$message" \
      --arg content "$content" \
      --arg sha "$sha" \
      '{branch:$branch, message:$message, content:$content, sha:$sha}')" || return 1
  else
    payload="$(jq -n \
      --arg branch "$branch" \
      --arg message "$message" \
      --arg content "$content" \
      '{branch:$branch, message:$message, content:$content}')" || return 1
  fi

  curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    -X PUT \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "${api}/contents/${path}" >/dev/null || return 1
}

# planner_pitch_pending — see the file header.
planner_pitch_pending() {
  local body kind len number login api
  login="${PLANNER_LOGIN:-planner-bot}"
  api="${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}"

  body="$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${api}/pulls?state=open&limit=50")" || return 1
  kind="$(printf '%s' "$body" | jq -r 'type')" || return 1
  [ "$kind" = "array" ] || return 1
  len="$(printf '%s' "$body" | jq -r 'length')" || return 1
  # A full page may hide another open pitch. Fail closed.
  if [ "$len" -eq 50 ]; then
    return 1
  fi

  number="$(printf '%s' "$body" | jq -r --arg login "$login" '
    first(
      .[]
      | select((.title | type) == "string" and (.title | startswith("architect:")))
      | select(.user.login == $login)
      | .number
      | select(. != null)
    ) // empty
  ')" || return 1
  if [ -n "$number" ]; then
    printf '%s\n' "$number"
  fi
  return 0
}

# planner_pitch_open TITLE SLUG FILE [PROBE_SRC PROBE_DEST] — see the file header.
planner_pitch_open() {
  local title="${1:-}" slug="${2:-}" file="${3:-}"
  local probe_src="" probe_dest=""

  # Probe args are checked before any forge call (before step 2). Exactly
  # one of the two is a refusal; both must name a real probe file.
  if [ "$#" -eq 4 ] || [ "$#" -lt 3 ] || [ "$#" -gt 5 ]; then
    return 1
  fi
  if [ "$#" -eq 5 ]; then
    probe_src="$4"
    probe_dest="$5"
    if [ ! -f "$probe_src" ] || [ ! -s "$probe_src" ]; then
      return 1
    fi
    case "$probe_dest" in
      *..*) return 1 ;;
    esac
    if [[ ! "$probe_dest" =~ $_PLANNER_PITCH_PROBE_RE ]]; then
      return 1
    fi
  fi

  # Step 1. Local only: a missing file, a bad sprint block, or a filer
  # block never becomes a planner pitch.
  if [ ! -f "$file" ]; then
    return 1
  fi
  pitch_sprint_block "$file" >/dev/null || return 1
  if grep -qF 'filer:begin' "$file"; then
    return 1
  fi

  # Step 2. One open architect pitch is enough.
  local pending_out pending_rc=0
  pending_out="$(planner_pitch_pending)" || pending_rc=$?
  if [ "$pending_rc" -ne 0 ]; then
    return 1
  fi
  if [ -n "$pending_out" ]; then
    return 0
  fi

  local api base branch message create_payload show_body shown
  api="${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}"
  base="${PRIMARY_BRANCH:-main}"
  branch="planner/pitch-${slug}"
  message="architect: ${title}"

  # Step 3. Same branch-create call as formulas/pitch-vision.toml. A failed
  # create is ignored only when a later GET shows that branch.
  create_payload="$(jq -n --arg new "$branch" --arg old "$base" \
    '{new_branch_name:$new, old_branch_name:$old}')" || return 1
  if ! curl -sf -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${api}/branches" \
    -d "$create_payload" >/dev/null; then
    show_body="$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${api}/branches/${branch}")" || return 1
    shown="$(printf '%s' "$show_body" | jq -r '.name // empty')" || return 1
    [ "$shown" = "$branch" ] || return 1
  fi

  # Step 4. The sprint file, then the optional probe, then the pull.
  _planner_pitch_put "$branch" "sprints/${slug}.md" "$file" "$message" || return 1
  if [ "$#" -eq 5 ]; then
    _planner_pitch_put "$branch" "$probe_dest" "$probe_src" "$message" || return 1
  fi

  # Step 5. Body is the file text, not a footer. Print the PR number.
  local pr_payload pr_body number
  pr_payload="$(jq -n \
    --arg title "$message" \
    --arg head "$branch" \
    --arg base "$base" \
    --rawfile body "$file" \
    '{title:$title, body:$body, head:$head, base:$base}')" || return 1
  pr_body="$(curl -sf -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$pr_payload" \
    "${api}/pulls")" || return 1
  number="$(printf '%s' "$pr_body" | jq -r '.number // empty')" || return 1
  [ -n "$number" ] || return 1
  printf '%s\n' "$number"
}
