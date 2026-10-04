#!/usr/bin/env bash
# =============================================================================
# tools/sprint-children.sh — count a sprint's children from the tape (#1674)
#
# The sprint's outcome carries its children's rollup: code-derived counts,
# never scores. This tool is that reader. It lists the proposals in
# ${TAPE_DIR:-/srv/disinto/tape}/tape.jsonl whose `parent` is SPRINT_ID —
# the issues dev-poll picked under the milestone's sprint proposal
# (lib/sprint-tape.sh, #1619; dev/dev-poll.sh) — and prints one JSON object:
#
#   {"n_children":N,"n_merged":N,"n_rejected":N,"n_failed":N}
#
#   n_children  all of them
#   n_merged    child whose last outcome (last in tape order, not the
#               latest t) carries bits.merged 1 or true
#   n_rejected  otherwise, child whose last outcome carries
#               bits.rejected 1 or true
#   n_failed    the rest: last outcome carrying neither bit 1 or true, and
#               children with no outcome at all
#
# Only the last outcome decides: a child whose first outcome is merged: 0
# and last outcome merged: 1 counts as merged; a child whose first outcome
# is merged: 1 and last outcome rejected: 1 counts as rejected.
#
# Missing tape (no tape.jsonl, or empty) prints all four as 0. Malformed
# tape lines (a torn final line from a crashed writer) are skipped with a
# stderr note, as tools/calibration.sh and tools/claims-report.sh do; they
# never fail the count.
#
# Usage:
#   tools/sprint-children.sh SPRINT_ID
#
# Environment (test seam):
#   TAPE_DIR  tape directory (default /srv/disinto/tape)
#
# Exit codes:
#   0  JSON object printed
#   1  jq missing, or the tape cannot be counted
#
# Part of the four pieces replacing #1620; the first caller is
# tools/sprint-outcomes.sh (#1676). Nothing calls this tool yet.
#
# Read-only: the tape is only read; no writes, no git, no network.
# =============================================================================
set -euo pipefail

command -v jq >/dev/null 2>&1 || {
  echo "sprint-children: required tool missing: jq" >&2
  exit 1
}

SPRINT_ID="${1:-}"
TAPE_DIR="${TAPE_DIR:-/srv/disinto/tape}"
TAPE_FILE="${TAPE_DIR}/tape.jsonl"

# Count a sprint's children over the tape. Prints the four-way count on
# stdout as one compact JSON object, ending with a newline. All four fields
# are 0 when no proposal names the sprint as parent.
count_children() {
  local sprint_id="$1" tape_file="$2"
  jq -c -sR --arg sprint_id "$sprint_id" '
    [ split("\n")[] | (try fromjson catch null) | select(type == "object") ] as $rows
    | ($rows | map(select(.type == "proposal" and .parent == $sprint_id))) as $children
    | ($children | map(. as $child
        | ($rows | map(select(.type == "outcome" and .proposal_id == $child.id)) | last) as $last
        | if $last == null then "failed"
          elif $last.bits.merged == 1 or $last.bits.merged == true then "merged"
          elif $last.bits.rejected == 1 or $last.bits.rejected == true then "rejected"
          else "failed" end)) as $states
    | { n_children: ($children | length),
        n_merged:   ($states | map(select(. == "merged")) | length),
        n_rejected: ($states | map(select(. == "rejected")) | length),
        n_failed:   ($states | map(select(. == "failed")) | length) }
  ' "$tape_file" 2>/dev/null
}

# Missing or empty tape: all four counts are 0. In a non-empty tape,
# malformed lines (a torn final line from a crashed writer) are skipped with
# a stderr note, as tools/calibration.sh and tools/claims-report.sh do;
# the count over the parseable lines is printed either way.
if [ ! -f "$TAPE_FILE" ] || [ ! -s "$TAPE_FILE" ]; then
  printf '%s\n' '{"n_children":0,"n_merged":0,"n_rejected":0,"n_failed":0}'
  exit 0
fi

total_lines=$(grep -c '' "$TAPE_FILE" || true)
valid_lines=$(jq -R -c 'fromjson? | select(type == "object")' \
  < "$TAPE_FILE" 2>/dev/null | grep -c '' || true)
total_lines="${total_lines:-0}"
valid_lines="${valid_lines:-0}"
skipped=$(( total_lines - valid_lines ))
[ "$skipped" -ge 0 ] || skipped=0
if [ "$skipped" -gt 0 ]; then
  echo "sprint-children: skipped ${skipped} malformed line(s) in ${TAPE_FILE}" >&2
fi

count_children "$SPRINT_ID" "$TAPE_FILE"
exit 0
