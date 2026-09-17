#!/usr/bin/env bash
# =============================================================================
# tools/calibration.sh — promised vs actual over the proposal-loop tape (#1393)
#
# Reads $TAPE_DIR/tape.jsonl (default /srv/disinto/tape/tape.jsonl) — the
# append-only tape written by lib/tape.sh (#1389) — and pairs each proposal
# with the outcome it reached: the LAST outcome record (in tape order) whose
# proposal_id matches the proposal's id (records are immutable, so a later
# outcome is the more recent state — e.g. the dev PR's terminal-state
# outcome, #1399, follows the formula session's end-of-session outcome,
# #1391). run/grade records are ignored. An outcome whose proposal_id
# matches no proposal (orphan) is skipped; a proposal without any outcome
# forms no pair.
#
# Pairs are grouped by (loop, class) — both taken from the proposal — and
# summarised as a markdown table on stdout:
#
#   | loop | class | n | merged rate | mean duration_s |
#
#   n               number of pairs in the group
#   merged rate     share of the group's pairs whose outcome carries
#                   bits.merged true or 1, as an integer percentage
#   mean duration_s mean of the pairs' outcome numbers.duration_s over the
#                   pairs that carry one (missing ones are skipped, never
#                   counted as zero); "-" when no pair in the group carries
#                   a duration
#
# Pure bash + jq. No git, no network, no writes: the tape is only read.
# Malformed tape lines (e.g. a torn final line from a crashed writer) are
# skipped with a stderr note, mirroring lib/stats.sh; they never fail the
# report.
#
# Usage:
#   tools/calibration.sh
#
# Environment:
#   TAPE_DIR  tape directory (default /srv/disinto/tape)
#
# Exit codes:
#   0  report printed; a missing or empty tape prints the header row only
#   1  jq missing
# =============================================================================
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "calibration: required tool missing: jq" >&2; exit 1; }

TAPE_DIR="${TAPE_DIR:-/srv/disinto/tape}"
TAPE_FILE="${TAPE_DIR}/tape.jsonl"

echo '| loop | class | n | merged rate | mean duration_s |'
echo '|---|---|---|---|---|'

[ -f "$TAPE_FILE" ] || exit 0
[ -s "$TAPE_FILE" ] || exit 0

# Count all lines and the parseable records; the difference is the number of
# malformed lines to skip (a torn final line from a crashed writer),
# mirroring lib/stats.sh.
total_lines=$(grep -c '' "$TAPE_FILE" || true)
valid_lines=$(jq -R -c 'fromjson? | select(type == "object")' < "$TAPE_FILE" | grep -c '' || true)
total_lines="${total_lines:-0}"
valid_lines="${valid_lines:-0}"
skipped=$(( total_lines - valid_lines ))
[ "$skipped" -ge 0 ] || skipped=0
[ "$skipped" -eq 0 ] || echo "calibration: skipped ${skipped} malformed line(s) in ${TAPE_FILE}" >&2

# One tab-separated row per (loop, class) group:
# loop <tab> class <tab> n <tab> merged rate (integer %) <tab> mean
# duration_s (the literal "NA" when no pair in the group carries one).
jq -R -s -r '
  [ split("\n")[]
    | (try fromjson catch null)
    | select(type == "object") ] as $recs
  | ($recs | map(select(.type == "proposal"
                 and ((.id | type) == "string")
                 and ((.loop | type) == "string")
                 and ((.class | type) == "string")))
      | map({key: .id, value: {loop: .loop, class: .class}})
      | from_entries) as $props
  | [ $recs[]
      | select(.type == "outcome"
               and ((.proposal_id | type) == "string")
               and ($props[.proposal_id] != null)) ]
  | group_by(.proposal_id)
  | map(last)
  | map({ loop: $props[.proposal_id].loop,
          class: $props[.proposal_id].class,
          merged: (.bits.merged == true or .bits.merged == 1),
          duration: (.numbers.duration_s
                     | if type == "number" then . else null end) })
  | group_by([.loop, .class])
  | map({ loop: .[0].loop,
          class: .[0].class,
          n: length,
          mr: (100 * (map(select(.merged)) | length) / length | round),
          md: ((map(.duration) | map(select(. != null)))
               | if length > 0 then add / length else null end) })
  | .[]
  | "\(.loop)\t\(.class)\t\(.n)\t\(.mr)\t\(if .md == null then "NA" else (.md | tostring) end)"
' "$TAPE_FILE" |
while IFS=$'\t' read -r lp cl n mr md; do
  if [ "$md" = "NA" ]; then
    mean="-"
  else
    mean="$(printf "%.1f" "$md")"
  fi
  printf '| %s | %s | %s | %s%% | %s |\n' "$lp" "$cl" "$n" "$mr" "$mean"
done
