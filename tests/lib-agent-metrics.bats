#!/usr/bin/env bats
# =============================================================================
# tests/lib-agent-metrics.bats — Unit tests for metrics_record_run (#1101)
#
# Fixture-based: no live agent. Covers the record schema, the no-result-row
# paths (watchdog kill / empty stream), output_tps null cases, task_ref,
# the unwritable-target guarantee, and the agent_run() wiring (--task flag,
# survival of a metrics write failure under set -e).
# =============================================================================

# A complete session: init row, two compact_boundary rows (in order),
# and a terminal result row.
# Expected output_tps: 50395 / (3480000/1000) = 14.481... -> 14.5
write_ok_stream() {
  cat > "$1" <<'EOF'
{"type":"system","subtype":"init","session_id":"fce3b61b-aaaa-bbbb-cccc-000000000001","model":"unsloth/Qwen3.8-27B"}
{"type":"assistant","session_id":"fce3b61b-aaaa-bbbb-cccc-000000000001","message":{"content":[{"type":"text","text":"hi"}]}}
{"subtype":"compact_boundary","session_id":"fce3b61b-aaaa-bbbb-cccc-000000000001","compact_metadata":{"pre_tokens":91082}}
{"subtype":"compact_boundary","session_id":"fce3b61b-aaaa-bbbb-cccc-000000000001","compact_metadata":{"pre_tokens":150000}}
{"type":"result","subtype":"success","session_id":"fce3b61b-aaaa-bbbb-cccc-000000000001","num_turns":60,"duration_ms":3511000,"duration_api_ms":3480000,"total_cost_usd":2.47,"usage":{"input_tokens":983044,"output_tokens":50395,"cache_read_input_tokens":1820172,"cache_creation_input_tokens":0},"modelUsage":{"unsloth/Qwen3.8-27B":{"contextWindow":200000}}}
EOF
}

# A session killed by the watchdog: init row, one compaction, and a
# truncated final line (what a kill mid-write leaves behind).
write_killed_stream() {
  cat > "$1" <<'EOF'
{"type":"system","subtype":"init","session_id":"aa11-22bb-33cc-44dd-55ee66ff7788","model":"unsloth/Qwen3.8-27B"}
{"subtype":"compact_boundary","session_id":"aa11-22bb-33cc-44dd-55ee66ff7788","compact_metadata":{"pre_tokens":91082}}
{"type":"assistant","session_id":"aa11-22bb-33cc-44dd-55ee66ff7788","mess
EOF
}

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TMP_DIR="$(mktemp -d)"
  export DISINTO_LOG_DIR="$TMP_DIR/logs"
  export AGENT_ROLES=dev
  export PROJECT_NAME=disinto

  # agent-sdk.sh sources agent-metrics.sh itself; also defines
  # claude_run_with_watchdog() and log(), which tests stub out.
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/agent-sdk.sh"
}

teardown() {
  rm -rf "$TMP_DIR"
}

# ── Completed session: full record ──────────────────────────────────────────

@test "completed session writes exactly one record with every field correct" {
  local stream="$TMP_DIR/ok.jsonl"
  write_ok_stream "$stream"
  metrics_record_run "$stream" 0 1101

  local file="$DISINTO_LOG_DIR/metrics/agent-runs.jsonl"
  [ "$(wc -l < "$file")" -eq 1 ]
  local line
  line=$(cat "$file")

  [ "$(jq -r '.session_id' <<<"$line")" = "fce3b61b-aaaa-bbbb-cccc-000000000001" ]
  [ "$(jq -r '.task_ref' <<<"$line")" = "1101" ]
  [ "$(jq -r '.role' <<<"$line")" = "dev" ]
  [ "$(jq -r '.project' <<<"$line")" = "disinto" ]
  [ "$(jq -r '.model' <<<"$line")" = "unsloth/Qwen3.8-27B" ]
  [ "$(jq -r '.outcome' <<<"$line")" = "success" ]
  [ "$(jq -r '.exit_code' <<<"$line")" = "0" ]
  [ "$(jq -r '.num_turns' <<<"$line")" = "60" ]
  [ "$(jq -r '.duration_ms' <<<"$line")" = "3511000" ]
  [ "$(jq -r '.duration_api_ms' <<<"$line")" = "3480000" ]
  [ "$(jq -r '.input_tokens' <<<"$line")" = "983044" ]
  [ "$(jq -r '.output_tokens' <<<"$line")" = "50395" ]
  [ "$(jq -r '.cache_read_input_tokens' <<<"$line")" = "1820172" ]
  [ "$(jq -r '.cache_creation_input_tokens' <<<"$line")" = "0" ]
  [ "$(jq -r '.output_tps' <<<"$line")" = "14.5" ]
  [ "$(jq -r '.cost_usd' <<<"$line")" = "2.47" ]
  [ "$(jq -r '.context_window' <<<"$line")" = "200000" ]
  [ "$(jq -r '.compactions' <<<"$line")" = "2" ]
  [ "$(jq -c '.compaction_pre_tokens' <<<"$line")" = "[91082,150000]" ]
  [[ "$(jq -r '.ts' <<<"$line")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]

  # Exactly the schema keys, in schema order — no missing or extra keys.
  [ "$(jq -r 'keys_unsorted | join(",")' <<<"$line")" = \
    "ts,session_id,task_ref,role,project,model,outcome,exit_code,num_turns,duration_ms,duration_api_ms,input_tokens,output_tokens,cache_read_input_tokens,cache_creation_input_tokens,output_tps,cost_usd,context_window,compactions,compaction_pre_tokens" ]
}

@test "two calls append two lines (no overwrite)" {
  local stream="$TMP_DIR/ok.jsonl"
  write_ok_stream "$stream"
  metrics_record_run "$stream" 0
  metrics_record_run "$stream" 0
  local file="$DISINTO_LOG_DIR/metrics/agent-runs.jsonl"
  [ "$(wc -l < "$file")" -eq 2 ]
}

# ── No result row (watchdog kill / crash) ───────────────────────────────────

@test "killed session (exit 124, no result row) records timeout with result fields null" {
  local stream="$TMP_DIR/killed.jsonl"
  write_killed_stream "$stream"
  metrics_record_run "$stream" 124
  local line
  line=$(cat "$DISINTO_LOG_DIR/metrics/agent-runs.jsonl")

  [ "$(jq -r '.outcome' <<<"$line")" = "timeout" ]
  [ "$(jq -r '.exit_code' <<<"$line")" = "124" ]
  # Still recovered from the partial stream:
  [ "$(jq -r '.session_id' <<<"$line")" = "aa11-22bb-33cc-44dd-55ee66ff7788" ]
  [ "$(jq -r '.model' <<<"$line")" = "unsloth/Qwen3.8-27B" ]
  [ "$(jq -r '.compactions' <<<"$line")" = "1" ]
  [ "$(jq -c '.compaction_pre_tokens' <<<"$line")" = "[91082]" ]
  # Every result-derived field is null:
  local k
  for k in num_turns duration_ms duration_api_ms input_tokens output_tokens \
           cache_read_input_tokens cache_creation_input_tokens output_tps \
           cost_usd context_window; do
    [ "$(jq -r --arg k "$k" '.[$k] | type' <<<"$line")" = "null" ]
  done
}

@test "no result row with a non-timeout exit code records no_result" {
  local stream="$TMP_DIR/killed.jsonl"
  write_killed_stream "$stream"
  metrics_record_run "$stream" 1
  local line
  line=$(cat "$DISINTO_LOG_DIR/metrics/agent-runs.jsonl")
  [ "$(jq -r '.outcome' <<<"$line")" = "no_result" ]
  [ "$(jq -r '.exit_code' <<<"$line")" = "1" ]
}

@test "empty stream file still yields one record (null session, zero compactions)" {
  local stream="$TMP_DIR/empty.jsonl"
  : > "$stream"
  metrics_record_run "$stream" 124
  local line
  line=$(cat "$DISINTO_LOG_DIR/metrics/agent-runs.jsonl")
  [ "$(jq -r '.session_id | type' <<<"$line")" = "null" ]
  [ "$(jq -r '.outcome' <<<"$line")" = "timeout" ]
  [ "$(jq -r '.compactions' <<<"$line")" = "0" ]
  [ "$(jq -c '.compaction_pre_tokens' <<<"$line")" = "[]" ]
}

# ── output_tps null cases ───────────────────────────────────────────────────

@test "duration_api_ms of 0 yields null output_tps" {
  local stream="$TMP_DIR/zero.jsonl"
  cat > "$stream" <<'EOF'
{"type":"result","subtype":"success","num_turns":1,"duration_ms":1000,"duration_api_ms":0,"total_cost_usd":0.01,"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}
EOF
  metrics_record_run "$stream" 0
  local line
  line=$(cat "$DISINTO_LOG_DIR/metrics/agent-runs.jsonl")
  [ "$(jq -r '.output_tokens' <<<"$line")" = "5" ]
  [ "$(jq -r '.output_tps | type' <<<"$line")" = "null" ]
}

@test "absent duration_api_ms yields null output_tps" {
  local stream="$TMP_DIR/noapi.jsonl"
  cat > "$stream" <<'EOF'
{"type":"result","subtype":"success","num_turns":1,"duration_ms":1000,"total_cost_usd":0.01,"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}
EOF
  metrics_record_run "$stream" 0
  local line
  line=$(cat "$DISINTO_LOG_DIR/metrics/agent-runs.jsonl")
  [ "$(jq -r '.output_tps | type' <<<"$line")" = "null" ]
}

@test "task_ref is empty when no third argument is given" {
  local stream="$TMP_DIR/ok.jsonl"
  write_ok_stream "$stream"
  metrics_record_run "$stream" 0
  local line
  line=$(cat "$DISINTO_LOG_DIR/metrics/agent-runs.jsonl")
  [ "$(jq -r '.task_ref' <<<"$line")" = "" ]
}

# ── Total-emitter guarantee ─────────────────────────────────────────────────

@test "unwritable metrics target: metrics_record_run returns 0 and writes nothing" {
  # chmod cannot stop root, so make the jsonl path itself a directory —
  # even root cannot append to a directory.
  mkdir -p "$DISINTO_LOG_DIR/metrics/agent-runs.jsonl"
  local stream="$TMP_DIR/ok.jsonl"
  write_ok_stream "$stream"
  metrics_record_run "$stream" 0
  [ -d "$DISINTO_LOG_DIR/metrics/agent-runs.jsonl" ]
}

# ── agent_run() wiring ──────────────────────────────────────────────────────

@test "agent_run --task records a metrics line attributed to the task" {
  local stream="$TMP_DIR/ok.jsonl"
  write_ok_stream "$stream"
  STREAM_FILE="$stream"
  # Stubs — agent_run calls these instead of the real claude/log:
  claude_run_with_watchdog() { cat "$STREAM_FILE"; return 0; }
  log() { :; }
  export LOGFILE="$TMP_DIR/agent.log"
  export SID_FILE="$TMP_DIR/session.sid"
  mkdir -p "$TMP_DIR/wt"

  agent_run --worktree "$TMP_DIR/wt" --task 1101 "do the thing"

  local line
  line=$(cat "$DISINTO_LOG_DIR/metrics/agent-runs.jsonl")
  [ "$(jq -r '.task_ref' <<<"$line")" = "1101" ]
  [ "$(jq -r '.exit_code' <<<"$line")" = "0" ]
  [ "$(jq -r '.outcome' <<<"$line")" = "success" ]
  # Existing diag behavior untouched:
  [ -s "$DISINTO_LOG_DIR/dev/agent-run-last.json" ]
}

@test "agent_run propagates the run's exit code when the metrics write fails (set -e active)" {
  local stream="$TMP_DIR/killed.jsonl"
  write_killed_stream "$stream"
  STREAM_FILE="$stream"
  claude_run_with_watchdog() { cat "$STREAM_FILE"; return 3; }
  log() { :; }
  export LOGFILE="$TMP_DIR/agent.log"
  export SID_FILE="$TMP_DIR/session.sid"
  mkdir -p "$TMP_DIR/wt"
  # Make the metrics file path a directory so the append cannot succeed.
  mkdir -p "$DISINTO_LOG_DIR/metrics/agent-runs.jsonl"

  # Command substitution inherits set -e, so an unguarded metrics failure
  # would abort agent_run and printf would never run. The stubbed run exits
  # 3 and agent_run propagates that per the documented contract.
  local out
  out=$(agent_run --worktree "$TMP_DIR/wt" "do the thing"; printf ' status=%s' "$?")
  [ "$out" = " status=3" ]
  # The run itself completed: diag output written, metrics path untouched.
  [ -s "$DISINTO_LOG_DIR/dev/agent-run-last.json" ]
  [ -d "$DISINTO_LOG_DIR/metrics/agent-runs.jsonl" ]
}

# ── Call-site attribution ───────────────────────────────────────────────────

@test "dev-agent.sh passes --task with the issue number" {
  grep -qF -- '--task "$ISSUE"' "$REPO_ROOT/dev/dev-agent.sh"
}

@test "review-pr.sh passes --task with the PR number" {
  grep -qF -- '--task "$PR_NUMBER"' "$REPO_ROOT/review/review-pr.sh"
}
