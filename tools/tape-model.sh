#!/usr/bin/env bash
# =============================================================================
# tools/tape-model.sh — proposal id → the model that served its run (#2059)
#
# The tape joins a result to a model only through the run: a run record carries
# `agent` = <harness>/<model> (formula_tape_agent, lib/formula-session.sh; the
# served model since #2012), an outcome carries `proposal_id` only, and a dev
# proposal carries `context.backend` (the served model since #2014, stale or
# absent before). Nothing reads that join, so calibration (#1393),
# tools/tape-stuck.sh (#1648) and the column tools pool every model into one
# (loop, class) row. This tool is the map the readers need: one JSON object on
# stdout keyed by proposal id, each value the model label of the run that
# served that proposal. It is the small standalone map; the big files get a
# wiring edit (#1648/#1649 style).
#
# Usage:
#   tools/tape-model.sh
#
# Reads ${TAPE_DIR:-/srv/disinto/tape}/tape.jsonl. No arguments.
#
# Model per proposal, in order:
#   1. the last run record in tape order with that proposal_id whose `agent`
#      is a string containing `/`: the agent with everything up to and
#      including the first `/` removed (dsh/unsloth/Qwen3.8-27B ->
#      unsloth/Qwen3.8-27B, dsh/qwen3.8-flash-next-q2_0 ->
#      qwen3.8-flash-next-q2_0, claude/sonnet -> sonnet);
#   2. else the proposal's `context.backend` when it is a non-empty string;
#   3. else the proposal is absent from the object (readers print `-`).
# A run whose agent has no `/` (bash) names no model. No lowercasing and no
# override table: the label is the string the run wrote.
#
# A missing or empty tape prints `{}`. Malformed tape lines (a torn final line
# from a crashed writer) are skipped with one stderr note, as
# tools/calibration.sh does; they never fail the tool.
#
# Bash plus jq; nothing else. No git, no network.
#
# Exit codes:
#   0  JSON object printed
#   1  jq missing
# =============================================================================
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "tape-model: required tool missing: jq" >&2; exit 1; }

TAPE_DIR="${TAPE_DIR:-/srv/disinto/tape}"
TAPE_FILE="${TAPE_DIR}/tape.jsonl"

if [ ! -f "$TAPE_FILE" ] || [ ! -s "$TAPE_FILE" ]; then
  echo "{}"
  exit 0
fi

# Count all lines and the parseable records; the difference is the number of
# malformed lines to skip (a torn final line from a crashed writer),
# mirroring tools/calibration.sh.
total_lines=$(grep -c '' "$TAPE_FILE" || true)
valid_lines=$(jq -R -c 'fromjson? | select(type == "object")' < "$TAPE_FILE" | grep -c '' || true)
total_lines="${total_lines:-0}"
valid_lines="${valid_lines:-0}"
skipped=$(( total_lines - valid_lines ))
[ "$skipped" -ge 0 ] || skipped=0
[ "$skipped" -eq 0 ] || echo "tape-model: skipped ${skipped} malformed line(s) in ${TAPE_FILE}" >&2

jq -R -s '
  [ split("\n")[]
    | (try fromjson catch null)
    | select(type == "object") ] as $recs
  # run records, tape order: proposal_id -> model label from the agent string.
  # from_entries keeps the last entry per key, so the last run wins.
  | ($recs
      | map(select(.type == "run"
                   and ((.proposal_id | type) == "string")
                   and ((.agent | type) == "string")
                   and (.agent | test("/"))))
      | map({ key: .proposal_id,
              value: (.agent | sub("^[^/]+/"; "")) })
      | from_entries) as $run_model
  # proposal records: id -> context.backend when it is a non-empty string.
  | ($recs
      | map(select(.type == "proposal"
                   and ((.id | type) == "string")
                   and ((.context | type) == "object")
                   and ((.context.backend | type) == "string")
                   and .context.backend != ""))
      | map({ key: .id, value: .context.backend })
      | from_entries) as $backend
  # one entry per proposal: the run label if any run named one, else the
  # backend, else absent.
  | [ $recs[]
      | select(.type == "proposal" and ((.id | type) == "string"))
      | { key: .id, value: ($run_model[.id] // $backend[.id]) }
      | select(.value != null) ]
  | from_entries
' "$TAPE_FILE"
exit 0
