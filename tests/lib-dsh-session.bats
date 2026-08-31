#!/usr/bin/env bats
# =============================================================================
# tests/lib-dsh-session.bats — Unit tests for dsh_session_normalise (#1105)
#
# Fixture-based: no dsh install, no model. The two committed fixtures under
# tests/fixtures/dsh/ are real zstd-compressed session logs in the dsh 0.1.1-rc.2
# on-disk format (a completed session with a compaction, and an aborted one).
# Covers the line shape (init / compact_boundary / result), the mapping rules
# (step/start counting, summed usage, duration, success detection), chunk-type
# skipping, epoch- and ISO-time handling, and every error path.
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TMP_DIR="$(mktemp -d)"
  FIX="$REPO_ROOT/tests/fixtures/dsh"

  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/dsh-session.sh"
}

teardown() {
  rm -rf "$TMP_DIR"
}

# make_session <dir> <jsonl> — compress a JSONL log into dir/session.jsonl.zstd
make_session() {
  local dir="$1" jsonl="$2"
  mkdir -p "$dir"
  zstd -q -f -o "$dir/session.jsonl.zstd" "$jsonl"
}

# ── Completed fixture: shape and mapping ────────────────────────────────────

@test "init line carries session_id (dir name), model, cwd, context window" {
  local line
  line=$(dsh_session_normalise "$FIX/completed" | jq -cs '.[0]')
  [ "$(jq -r '.type' <<<"$line")" = "system" ]
  [ "$(jq -r '.subtype' <<<"$line")" = "init" ]
  [ "$(jq -r '.session_id' <<<"$line")" = "completed" ]
  [ "$(jq -r '.model' <<<"$line")" = "unsloth/Qwen3.8-27B" ]
  [ "$(jq -r '.cwd' <<<"$line")" = "/home/demo/proj" ]
  [ "$(jq -r '.context_window' <<<"$line")" = "200000" ]
}

@test "emits exactly init, compact_boundary, result — in that order" {
  local out
  out=$(dsh_session_normalise "$FIX/completed")
  [ "$(wc -l <<<"$out")" -eq 3 ]
  [ "$(jq -r '.subtype' <<<"$out" | tr '\n' ' ')" = "init compact_boundary success " ]
}

@test "compact_boundary line carries pre_tokens and trigger auto" {
  local line
  line=$(dsh_session_normalise "$FIX/completed" | jq -cs '.[1]')
  [ "$(jq -r '.type' <<<"$line")" = "system" ]
  [ "$(jq -r '.subtype' <<<"$line")" = "compact_boundary" ]
  [ "$(jq -r '.compact_metadata.pre_tokens' <<<"$line")" = "45000" ]
  [ "$(jq -r '.compact_metadata.trigger' <<<"$line")" = "auto" ]
}

@test "result line maps turns, duration, summed usage, context window" {
  local line
  line=$(dsh_session_normalise "$FIX/completed" | jq -cs '.[2]')
  [ "$(jq -r '.type' <<<"$line")" = "result" ]
  [ "$(jq -r '.subtype' <<<"$line")" = "success" ]
  [ "$(jq -r '.session_id' <<<"$line")" = "completed" ]
  # 3 step/start records (a dsh "turn" is NOT counted — it wrapped all 3)
  [ "$(jq -r '.num_turns' <<<"$line")" = "3" ]
  # first record 10:00:00.000Z → last 10:00:59.500Z
  [ "$(jq -r '.duration_ms' <<<"$line")" = "59500" ]
  # 1200+1500+900 / 340+210+150 / 0+800+1000 across the assistant messages
  [ "$(jq -r '.usage.input_tokens' <<<"$line")" = "3600" ]
  [ "$(jq -r '.usage.output_tokens' <<<"$line")" = "700" ]
  [ "$(jq -r '.usage.cache_read_input_tokens' <<<"$line")" = "1800" ]
  [ "$(jq -r '.modelUsage["unsloth/Qwen3.8-27B"].contextWindow' <<<"$line")" = "200000" ]
}

@test "result line matches the agent-sdk.sh watchdog grep pattern" {
  # lib/agent-sdk.sh greps for '"type":"result","subtype":' — pin the key order.
  local out
  out=$(dsh_session_normalise "$FIX/completed")
  grep -q '"type":"result","subtype":' <<<"$out"
}

# ── Aborted fixture: no_result path ─────────────────────────────────────────

@test "aborted session (no completed turn/end) yields no_result with partials" {
  local out
  out=$(dsh_session_normalise "$FIX/aborted")
  # No compactions → only init and result lines
  [ "$(wc -l <<<"$out")" -eq 2 ]

  local init res
  init=$(jq -cs '.[0]' <<<"$out")
  res=$(jq -cs '.[1]' <<<"$out")
  # Model comes from request/context alone (this fixture has no request/header)
  [ "$(jq -r '.model' <<<"$init")" = "local/llama-70b" ]
  [ "$(jq -r '.session_id' <<<"$init")" = "aborted" ]
  [ "$(jq -r '.subtype' <<<"$res")" = "no_result" ]
  [ "$(jq -r '.num_turns' <<<"$res")" = "1" ]
  [ "$(jq -r '.duration_ms' <<<"$res")" = "2500" ]
  [ "$(jq -r '.usage.input_tokens' <<<"$res")" = "500" ]
  [ "$(jq -r '.usage.output_tokens' <<<"$res")" = "80" ]
  [ "$(jq -r '.usage.cache_read_input_tokens' <<<"$res")" = "0" ]
}

# ── Synthetic logs: chunk skipping, time formats, compaction order ──────────

@test "chunk record types are dropped (their timestamps cannot leak in)" {
  local log="$TMP_DIR/chunky.jsonl" dir="$TMP_DIR/chunky-sess"
  cat > "$log" <<'EOF'
{"type":"session","seq":0,"time":"2026-08-30T12:00:00.000Z","data":{"id":"chunky","cwd":"/tmp/x"}}
{"type":"reasoning-chunks","seq0":1,"time0":"2031-01-01T00:00:00Z","data":{"chunks":["a"]}}
{"type":"assistant/chunk","seq0":2,"time0":4102444800000,"data":{"text":"b"}}
{"type":"tool-call-chunks","seq0":3,"time0":"2031-01-01T00:00:00Z","data":{"chunks":["c"]}}
{"type":"text-chunks","seq0":4,"time0":"2031-01-01T00:00:00Z","data":{"chunks":["d"]}}
{"type":"step/start","seq":5,"time":"2026-08-30T12:00:00.500Z","data":{"turn":1,"step":1}}
{"type":"turn/end","seq":6,"time":"2026-08-30T12:00:01.000Z","data":{"turn":1,"reason":{"kind":"completed"}}}
EOF
  make_session "$dir" "$log"
  local res
  res=$(dsh_session_normalise "$dir" | jq -cs '.[-1]')
  # Had a chunk timestamp leaked through, duration would be ~1.5e12 ms.
  [ "$(jq -r '.duration_ms' <<<"$res")" = "1000" ]
  [ "$(jq -r '.num_turns' <<<"$res")" = "1" ]
  [ "$(jq -r '.subtype' <<<"$res")" = "success" ]
}

@test "epoch-ms times and multiple compactions in order" {
  local log="$TMP_DIR/multi.jsonl" dir="$TMP_DIR/multi-sess"
  cat > "$log" <<'EOF'
{"type":"session","seq":0,"time":1700000000000,"data":{"id":"multi","cwd":"/tmp/m"}}
{"type":"request/context","seq":1,"time":1700000000100,"data":{"model":"m/x","contextWindow":32000}}
{"type":"step/start","seq":2,"time":1700000001000,"data":{"turn":1,"step":1}}
{"type":"assistant/message","seq":3,"time":1700000002000,"data":{"text":"a","usage":{"inputTokens":100,"outputTokens":10,"cacheReadTokens":0}}}
{"type":"compaction/summary","seq":4,"time":1700000003000,"data":{"compactionId":"c-a","shadowedTokenCount":1000}}
{"type":"compaction/end","seq":5,"time":1700000003100,"data":{"compactionId":"c-a"}}
{"type":"step/start","seq":6,"time":1700000003200,"data":{"turn":1,"step":2}}
{"type":"assistant/message","seq":7,"time":1700000004000,"data":{"text":"b","usage":{"inputTokens":200,"outputTokens":20,"cacheReadTokens":50}}}
{"type":"compaction/summary","seq":8,"time":1700000004500,"data":{"compactionId":"c-b","shadowedTokenCount":2000}}
{"type":"compaction/end","seq":9,"time":1700000004600,"data":{"compactionId":"c-b"}}
{"type":"turn/end","seq":10,"time":1700000005000,"data":{"turn":1,"reason":{"kind":"completed"}}}
EOF
  make_session "$dir" "$log"
  local out
  out=$(dsh_session_normalise "$dir")
  # init + 2 boundaries + result
  [ "$(wc -l <<<"$out")" -eq 4 ]
  [ "$(jq -cs '[.[1].compact_metadata.pre_tokens, .[2].compact_metadata.pre_tokens]' <<<"$out")" = "[1000,2000]" ]
  local res
  res=$(jq -cs '.[-1]' <<<"$out")
  [ "$(jq -r '.num_turns' <<<"$res")" = "2" ]
  [ "$(jq -r '.duration_ms' <<<"$res")" = "5000" ]
  [ "$(jq -r '.usage.input_tokens' <<<"$res")" = "300" ]
  [ "$(jq -r '.usage.output_tokens' <<<"$res")" = "30" ]
  [ "$(jq -r '.usage.cache_read_input_tokens' <<<"$res")" = "50" ]
}

@test "model falls back to request/header when request/context is absent" {
  local log="$TMP_DIR/hdr.jsonl" dir="$TMP_DIR/hdr-sess"
  cat > "$log" <<'EOF'
{"type":"session","seq":0,"time":"2026-08-30T13:00:00.000Z","data":{"id":"hdr","cwd":"/tmp/h"}}
{"type":"request/header","seq":1,"time":"2026-08-30T13:00:00.100Z","data":{"header":{"config":{"model":"local/llama-70b"}}}}
{"type":"step/start","seq":2,"time":"2026-08-30T13:00:00.200Z","data":{"turn":1,"step":1}}
{"type":"turn/end","seq":3,"time":"2026-08-30T13:00:01.000Z","data":{"turn":1,"reason":{"kind":"completed"}}}
EOF
  make_session "$dir" "$log"
  local out
  out=$(dsh_session_normalise "$dir")
  local init res
  init=$(jq -cs '.[0]' <<<"$out")
  res=$(jq -cs '.[-1]' <<<"$out")
  [ "$(jq -r '.model' <<<"$init")" = "local/llama-70b" ]
  # No context window known → context_window and modelUsage are null
  [ "$(jq -r '.context_window | type' <<<"$init")" = "null" ]
  [ "$(jq -r '.modelUsage | type' <<<"$res")" = "null" ]
}

# ── Error paths ──────────────────────────────────────────────────────────────

@test "missing log: exit 1, empty stdout, clear stderr" {
  local dir="$TMP_DIR/no-log" rc=0 out err="$TMP_DIR/err.txt"
  mkdir -p "$dir"
  out=$(dsh_session_normalise "$dir" 2>"$err") || rc=$?
  [ "$rc" -eq 1 ]
  [ -z "$out" ]
  grep -q "missing" "$err"
}

@test "not a session directory: exit 1" {
  local rc=0 out err="$TMP_DIR/err.txt"
  out=$(dsh_session_normalise "$TMP_DIR/not-a-dir" 2>"$err") || rc=$?
  [ "$rc" -eq 1 ]
  [ -z "$out" ]
  grep -q "not a session directory" "$err"
}

@test "truncated log: exit 1, empty stdout (never a partial parse)" {
  local dir="$TMP_DIR/trunc" rc=0 out err="$TMP_DIR/err.txt" half
  mkdir -p "$dir"
  cp "$FIX/completed/session.jsonl.zstd" "$dir/session.jsonl.zstd"
  half=$(( $(wc -c < "$dir/session.jsonl.zstd") / 2 ))
  head -c "$half" "$dir/session.jsonl.zstd" > "$dir/partial"
  mv "$dir/partial" "$dir/session.jsonl.zstd"
  out=$(dsh_session_normalise "$dir" 2>"$err") || rc=$?
  [ "$rc" -eq 1 ]
  [ -z "$out" ]
  grep -q "truncated or corrupt" "$err"
}

@test "empty log: exit 1, 'no usable records'" {
  local dir="$TMP_DIR/empty-log" rc=0 out err="$TMP_DIR/err.txt"
  mkdir -p "$dir"
  : | zstd -q > "$dir/session.jsonl.zstd"
  out=$(dsh_session_normalise "$dir" 2>"$err") || rc=$?
  [ "$rc" -eq 1 ]
  [ -z "$out" ]
  grep -q "no usable records" "$err"
}

@test "no argument: exit 2 (usage error)" {
  local rc=0 out err="$TMP_DIR/err.txt"
  out=$(dsh_session_normalise 2>"$err") || rc=$?
  [ "$rc" -eq 2 ]
  [ -z "$out" ]
  grep -q "usage" "$err"
}
