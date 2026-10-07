#!/usr/bin/env bash
# pitch-pr.sh — read and update a pitch file on its ops-repo PR branch (#1906)
#
# A pitch is an ops-repo PR that adds sprints/<slug>.md. The architect reads
# that file as it stands on the PR head and commits a new version back onto
# the same branch. This file does not merge, does not file issues, and does
# not source lib/env.sh. Nothing calls it yet (#1910 will).
#
# Every forge call is:
#   curl -sf -H "Authorization: token ${FORGE_TOKEN}"
# on a path under ${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}.
#
#   pitch_pr_path PR
#     GET /pulls/PR/files. Print the .filename of the first entry whose
#     .status is "added" and whose name matches ^sprints/[^/]+\.md$.
#     Return 1 when there is none, the call fails, or the answer is not
#     an array.
#   pitch_pr_fetch PR PATH DEST
#     GET /pulls/PR for .head.ref, then GET /contents/PATH?ref=<head.ref>.
#     Write .content, base64-decoded, to DEST and print "<head.ref> <sha>"
#     (sha is the response's .sha, the blob sha an update needs).
#     Return 1 and leave DEST alone when a call fails or a field is empty.
#   pitch_pr_put BRANCH PATH SHA SRC MESSAGE
#     PUT /contents/PATH with Content-Type: application/json. The body is
#     branch, sha, message, and the base64 of SRC — no author and no
#     committer, so the forge records the token's user as the commit's
#     author. Print .commit.sha. Return 1 when the call fails or that
#     field is empty.
#
# Env: FORGE_API_BASE, FORGE_OPS_REPO, FORGE_TOKEN.
# Requires: curl, jq, base64.

set -euo pipefail

# A pitch file is one added markdown file directly under sprints/.
_PITCH_PR_FILE_RE='^sprints/[^/]+\.md$'

# pitch_pr_path PR — see the file header.
pitch_pr_path() {
  local pr="${1:?pitch_pr_path: PR required}"
  local body kind filename

  body="$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls/${pr}/files")" || return 1
  kind="$(printf '%s' "$body" | jq -r 'type')" || return 1
  [ "$kind" = "array" ] || return 1
  filename="$(printf '%s' "$body" | jq -r --arg re "$_PITCH_PR_FILE_RE" '
    [.[] | select(.status == "added") | .filename
      | select(type == "string" and test($re))] | .[0] // empty
  ')" || return 1
  [ -n "$filename" ] || return 1
  printf '%s\n' "$filename"
}

# pitch_pr_fetch PR PATH DEST — see the file header.
pitch_pr_fetch() {
  local pr="${1:?pitch_pr_fetch: PR required}"
  local path="${2:?pitch_pr_fetch: PATH required}"
  local dest="${3:?pitch_pr_fetch: DEST required}"
  local pr_body ref file_body raw_b64 b64 sha tmp

  pr_body="$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls/${pr}")" || return 1
  ref="$(printf '%s' "$pr_body" | jq -r '.head.ref // empty')" || return 1
  [ -n "$ref" ] || return 1

  file_body="$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/contents/${path}?ref=${ref}")" || return 1
  raw_b64="$(printf '%s' "$file_body" | jq -r '.content // empty')" || return 1
  sha="$(printf '%s' "$file_body" | jq -r '.sha // empty')" || return 1
  # Forgejo wraps the blob at 60 columns. Strip that before decoding, and
  # do not open DEST until both fields are present and the decode succeeds.
  b64="$(printf '%s' "$raw_b64" | tr -d '[:space:]')"
  [ -n "$b64" ] && [ -n "$sha" ] || return 1

  tmp="$(mktemp)" || return 1
  if ! printf '%s' "$b64" | base64 -d >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv "$tmp" "$dest"; then
    rm -f "$tmp"
    return 1
  fi
  printf '%s %s\n' "$ref" "$sha"
}

# pitch_pr_put BRANCH PATH SHA SRC MESSAGE — see the file header.
pitch_pr_put() {
  local branch="${1:?pitch_pr_put: BRANCH required}"
  local path="${2:?pitch_pr_put: PATH required}"
  local sha="${3:?pitch_pr_put: SHA required}"
  local src="${4:?pitch_pr_put: SRC required}"
  local message="${5:?pitch_pr_put: MESSAGE required}"
  local payload response commit_sha

  # No author, no committer: the token's user is the commit's author.
  payload="$(jq -n \
    --arg branch "$branch" \
    --arg sha "$sha" \
    --arg message "$message" \
    --arg content "$(base64 -w0 < "$src")" \
    '{branch: $branch, sha: $sha, message: $message, content: $content}')" || return 1
  response="$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    -X PUT \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/contents/${path}")" || return 1
  commit_sha="$(printf '%s' "$response" | jq -r '.commit.sha // empty')" || return 1
  [ -n "$commit_sha" ] || return 1
  printf '%s\n' "$commit_sha"
}
