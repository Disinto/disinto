#!/usr/bin/env bash
# =============================================================================
# tools/sprint-held.sh — read whether a sprint's merges held (#2030)
#
# The effect scale (docs/design/proposal-loop.md §3) grades a sprint's soak by
# what survived it: `held` (0.25) means its merges are still on main after the
# soak; `broke` (-1) means the work was reverted. The tape knows which children
# merged (tools/sprint-children.sh: the last outcome carries bits.merged), but
# it holds no commit and no tool reads git for a sprint. This is that reader:
# it takes the sprint's merged children, finds their dev merge commits in the
# project repo, and checks whether any was reverted.
#
# A dev PR lands as a merge commit whose message reads
#   Merge pull request '…' (#PR) from fix/issue-N into main
# (dev/dev-agent.sh names the branch fix/issue-N and retries as fix/issue-N-k,
# so the pattern accepts the -k suffix), and a revert's message carries
# `This reverts commit <sha>`.
#
# Usage:
#   tools/sprint-held.sh SPRINT_ID
#
# Prints exactly one word on stdout and exits 0:
#   broke  at least one merged child's merge commit was found in git and some
#          found merge is reverted
#   held   at least one merge was found and none is reverted
#   none   no merge was found: no merged child in the tape, or none of the
#          merged children has a matching merge commit in git
#
# Environment (test seams):
#   TAPE_DIR            tape directory (default /srv/disinto/tape)
#   PROJECT_REPO_ROOT   the project repo to read (required; must be a git
#                       checkout — the caller's own repo root)
#   SPRINT_HELD_REF     the ref to read (default HEAD; the caller passes a
#                       freshly fetched origin/main)
#
# Exit codes:
#   0  one of the three words printed
#   1  SPRINT_ID empty, jq or git missing, PROJECT_REPO_ROOT is not a git
#      checkout, or the tape cannot be read (nothing printed on stdout)
#
# Hermetic aside from the tape and one git checkout: no network, no secrets,
# jq and git only; it does not source lib/env.sh. No caller yet; #2036 wires
# it into sprint-grades.sh.
# =============================================================================
set -euo pipefail

command -v jq >/dev/null 2>&1 || {
  echo "sprint-held: required tool missing: jq" >&2
  exit 1
}
command -v git >/dev/null 2>&1 || {
  echo "sprint-held: required tool missing: git" >&2
  exit 1
}

SPRINT_ID="${1:-}"
if [ -z "$SPRINT_ID" ]; then
  echo "sprint-held: usage: tools/sprint-held.sh SPRINT_ID" >&2
  exit 1
fi

REPO_ROOT="${PROJECT_REPO_ROOT:?sprint-held: PROJECT_REPO_ROOT must name the project repo checkout}"
if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "sprint-held: PROJECT_REPO_ROOT is not a git checkout: ${REPO_ROOT}" >&2
  exit 1
fi

TAPE_DIR="${TAPE_DIR:-/srv/disinto/tape}"
TAPE_FILE="${TAPE_DIR}/tape.jsonl"
REF="${SPRINT_HELD_REF:-HEAD}"

if [ ! -r "$TAPE_FILE" ]; then
  echo "sprint-held: cannot read the tape: ${TAPE_FILE}" >&2
  exit 1
fi

# Malformed lines (a torn final line from a crashed writer) are skipped, not
# fatal: one jq pass counts the parseable object records and the gap to the
# line count is how many lines were torn; the note goes to stderr.
skipped=$(jq -R -s '
  [ split("\n")[] | select(length != 0) ] as $lines
  | ($lines | length) - ([ $lines[] | select(try fromjson | type == "object") ] | length)
' "$TAPE_FILE" 2>/dev/null || echo 0)
if [ "${skipped:-0}" -gt 0 ]; then
  echo "sprint-held: skipped ${skipped} malformed line(s) in ${TAPE_FILE}" >&2
fi

# The sprint's merged children, the same rule tools/sprint-children.sh uses for
# n_merged: proposals whose parent is SPRINT_ID whose LAST outcome (last in
# tape order) carries bits.merged 1 or true. Each contributes its ref, the
# issue number; a ref that is not a plain number carries no merge to read.
# One issue number per line on stdout.
merged_issues() {
  jq -srR --arg sprint_id "$SPRINT_ID" '
    [ split("\n")[] | (try fromjson catch null) | select(type == "object") ] as $rows
    | ($rows | map(select(.type == "proposal" and .parent == $sprint_id))) as $children
    | ($children | map(. as $child
        | ($rows | map(select(.type == "outcome" and .proposal_id == $child.id)) | last) as $last
        | select($last != null and ($last.bits.merged == 1 or $last.bits.merged == true))
        | .ref))
    | map(tostring)
    | map(select(test("^[0-9]+$")))
    | .[]
  ' "$TAPE_FILE"
}

found=0
while IFS= read -r issue; do
  [ -n "$issue" ] || continue
  merges="$(git -C "$REPO_ROOT" log --merges --format=%H -E \
    --grep="from fix/issue-${issue}(-[0-9]+)? into " "$REF" 2>/dev/null)" \
    || {
      echo "sprint-held: git log failed on ref ${REF} in ${REPO_ROOT}" >&2
      exit 1
    }
  for sha in $merges; do
    found=1
    # A merge is reverted when some commit after it, up to the ref, carries
    # the revert of exactly that sha. The message is captured into a variable
    # rather than piped to grep: `grep -q` closes stdin early, and under
    # pipefail a SIGPIPE-killed git would report 141 even when grep matched.
    body="$(git -C "$REPO_ROOT" log --format=%B "${sha}..${REF}" 2>/dev/null || true)"
    if [[ "$body" == *"This reverts commit ${sha}"* ]]; then
      echo broke
      exit 0
    fi
  done
done < <(merged_issues)

if [ "$found" -eq 1 ]; then
  echo held
else
  echo none
fi
exit 0
