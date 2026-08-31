#!/usr/bin/env bash
# agent-metrics.sh — Per-session agent telemetry (#1101)
#
# Appends one JSON line per agent session to
# ${DISINTO_LOG_DIR}/metrics/agent-runs.jsonl so run time, token usage,
# throughput and compaction counts survive past the run.
#
# Sourced by lib/agent-sdk.sh, which calls metrics_record_run() from
# agent_run() — the one choke point every agent role passes through —
# immediately after agent-run-last.json is written.
#
#   metrics_record_run <stream_json_file> <exit_code> [task_ref]
#
# The emitter is total: a missing/truncated stream, an empty file, a bad
# exit code, or an unwritable target all yield a clean return 0 — a metrics
# write failure must never fail an agent run.
#
# Concurrency: dev and review agents run concurrently; the record is one
# sub-PIPE_BUF line and a single `>>` append is atomic on Linux, so no
# locking is needed.
#
# Tests: tests/lib-agent-metrics.bats

set -euo pipefail

# metrics_record_run — append one JSONL record for a finished session.
#
#   $1  stream_json_file — path to the session's stream-json output
#   $2  exit_code        — exit code of the run (124 = CLAUDE_TIMEOUT watchdog kill)
#   $3  task_ref         — optional issue/PR reference for attribution
#
# Fields and where they come from in the stream:
#   session_id, model        — the init row (subtype "init")
#   num_turns, duration_ms, duration_api_ms, cost_usd (total_cost_usd),
#   input/output/cache token counts, context_window
#                             (modelUsage.<model>.contextWindow)
#                          — the terminal result row (type "result")
#   compactions, compaction_pre_tokens — compact_boundary rows, in order
#   output_tps               — output_tokens / (duration_api_ms/1000), one
#                              decimal; null when duration_api_ms is 0 or absent
#   outcome                  — the result row's subtype (success |
#                              error_max_turns); "timeout" when there is no
#                              result row and exit_code is 124; "no_result"
#                              otherwise. With no result row, every
#                              result-derived field is null, but session_id
#                              and compaction counts are still recovered from
#                              the partial stream.
metrics_record_run() {
  local stream_file="${1:-}" rc="${2:-0}" task_ref="${3:-}"
  local out_dir="${DISINTO_LOG_DIR:-/tmp}/metrics"
  local metrics_file="${out_dir}/agent-runs.jsonl"
  local ts line

  # exit_code must be numeric for --argjson; never let garbage sink the record.
  case "$rc" in '' | *[!0-9]*) rc=0 ;; esac

  [ -r "$stream_file" ] || return 0
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) || return 0

  # -R -s + lenient fromjson: a watchdog kill can leave a truncated JSON line
  # at the end of the stream — drop unparseable lines, keep the record.
  line=$(jq -R -s -c \
    --arg ts "$ts" \
    --arg role "${AGENT_ROLES:-}" \
    --arg project "${PROJECT_NAME:-}" \
    --arg task_ref "$task_ref" \
    --argjson rc "$rc" \
    'split("\n")
     | map(select(. != "") | (try fromjson))
     | map(select(type == "object"))
     | . as $rows
     | ([ $rows[] | select(.subtype == "init") ] | last) as $init
     | ([ $rows[] | select(.type == "result") ] | last) as $res
     | ([ $rows[] | select(.subtype == "compact_boundary")
          | .compact_metadata.pre_tokens ] | map(select(. != null))) as $pre
     | (if $res != null then $res.subtype
        elif $rc == 124 then "timeout"
        else "no_result" end) as $outcome
     | (if $res == null then null else $res.usage.output_tokens end) as $out_t
     | (if $res == null then null else $res.duration_api_ms end) as $dapi
     | { ts: $ts,
         session_id: ($init.session_id // ([ $rows[] | .session_id ] | last) // null),
         task_ref: $task_ref,
         role: $role,
         project: $project,
         model: $init.model,
         outcome: $outcome,
         exit_code: $rc,
         num_turns: (if $res == null then null else $res.num_turns end),
         duration_ms: (if $res == null then null else $res.duration_ms end),
         duration_api_ms: $dapi,
         input_tokens: (if $res == null then null else $res.usage.input_tokens end),
         output_tokens: $out_t,
         cache_read_input_tokens: (if $res == null then null else $res.usage.cache_read_input_tokens end),
         cache_creation_input_tokens: (if $res == null then null else $res.usage.cache_creation_input_tokens end),
         output_tps: (if ($out_t != null and $dapi != null and $dapi > 0)
                      then (($out_t / ($dapi / 1000) * 10 | round) / 10)
                      else null end),
         cost_usd: (if $res == null then null else $res.total_cost_usd end),
         context_window: (if ($res == null or $init == null or $init.model == null)
                           then null
                           else $res.modelUsage[$init.model].contextWindow end),
         compactions: ($pre | length),
         compaction_pre_tokens: $pre }' \
    "$stream_file" 2>/dev/null) || return 0

  [ -n "$line" ] || return 0
  mkdir -p "$out_dir" 2>/dev/null || return 0
  printf '%s\n' "$line" >> "$metrics_file" 2>/dev/null || return 0
  return 0
}
