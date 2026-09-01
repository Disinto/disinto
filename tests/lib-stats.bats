#!/usr/bin/env bats
# =============================================================================
# tests/lib-stats.bats — Unit tests for stats_main (#1102)
#
# Fixture-based: no live agent. Covers the per-role summary table, the totals
# row, the --since / --role / --task filters, --json output, the
# no-duration + malformed-line footnotes, and the missing/empty file message.
#
# The fixture is built with timestamps relative to "now" so the suite never
# rots. Record layout (offset, role, outcome, task, dur_ms, in, out, tps,
# cost, compactions):
#   rec1  1h   dev    success          1102  3600000  1000000  100000  10  10  2
#   rec2  2h   dev    timeout          1102  null     null     null    -   -   1
#   rec3  20h  dev    error_max_turns  1103  7200000  2000000  200000  20  20  3
#   rec4  48h  dev    no_result        1104  1800000   500000   50000   5   5  0
#   rec5  8d   dev    success          1105  3600000  1000000  100000  10  10  2  (excluded by 7d)
#   rec6  2h   review success          1102  1800000   200000   20000  15   3  0
# plus 3 malformed lines (2 terminated + 1 torn final line).
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TMP_DIR="$(mktemp -d)"
  export DISINTO_LOG_DIR="$TMP_DIR/logs"
  export AGENT_ROLES=dev
  export PROJECT_NAME=disinto

  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/stats.sh"
  METRICS="$DISINTO_LOG_DIR/metrics/agent-runs.jsonl"
  mkdir -p "$DISINTO_LOG_DIR/metrics"
}

teardown() {
  rm -rf "$TMP_DIR"
}

# mkrec <offset_s> <role> <outcome> <task> <dur|-> <in|-> <out|-> <tps|-> <cost|-> <comps> [delivered]
# delivered (11th, optional): "true" | "false" | omitted — omitted leaves the
# field out of the record entirely, like pre-#1167 records.
mkrec() {
  local off="$1" role="$2" outcome="$3" task="$4" dur="$5" in_="$6" out_="$7" tps="$8" cost="$9" comps="${10}" del="${11:-}"
  local ts durj inj outj tpsj costj delj
  ts="$(stats_epoch_to_iso $(( $(date -u +%s) - off )))"
  durj=$([ "$dur" = "-" ] && echo null || echo "$dur")
  inj=$([ "$in_" = "-" ] && echo null || echo "$in_")
  outj=$([ "$out_" = "-" ] && echo null || echo "$out_")
  tpsj=$([ "$tps" = "-" ] && echo null || echo "$tps")
  costj=$([ "$cost" = "-" ] && echo null || echo "$cost")
  delj=$([ -n "$del" ] && echo "$del" || echo null)
  jq -cn \
    --arg ts "$ts" --arg role "$role" --arg outcome "$outcome" --arg task "$task" \
    --argjson dur "$durj" --argjson in "$inj" --argjson out "$outj" \
    --argjson tps "$tpsj" --argjson cost "$costj" --argjson comps "$comps" \
    --argjson del "$delj" \
    '{ts:$ts,session_id:("s-"+$task+"-"+$role),task_ref:$task,role:$role,project:"disinto",model:"m",outcome:$outcome,exit_code:0,num_turns:5,duration_ms:$dur,duration_api_ms:$dur,input_tokens:$in,output_tokens:$out,cache_read_input_tokens:0,cache_creation_input_tokens:0,output_tps:$tps,cost_usd:$cost,context_window:200000,compactions:$comps,compaction_pre_tokens:[]} + (if $del == null then {} else {delivered: $del} end)' \
    >> "$METRICS"
}

write_fixture() {
  mkrec 3600   dev    success          1102  3600000  1000000  100000  10  10  2
  mkrec 7200   dev    timeout          1102  -      -        -       -   -   1
  mkrec 72000  dev    error_max_turns  1103  7200000  2000000  200000  20  20  3
  mkrec 172800 dev    no_result        1104  1800000   500000   50000   5   5   0
  mkrec 691200 dev    success          1105  3600000  1000000  100000  10  10  2
  mkrec 7200   review success          1102  1800000   200000   20000  15   3   0
  echo 'not json' >> "$METRICS"
  echo '{"broken":' >> "$METRICS"
  printf '%s' '{"torn": tru' >> "$METRICS"
}

# ── Missing / empty metrics file ─────────────────────────────────────────────

@test "missing metrics file prints the no-data message and exits 0" {
  local out rc
  out="$(stats_main)"; rc=$?
  [ "$rc" -eq 0 ]
  [ "$out" = "no agent runs recorded yet" ]
}

@test "empty metrics file prints the no-data message and exits 0" {
  : > "$METRICS"
  local out rc
  out="$(stats_main)"; rc=$?
  [ "$rc" -eq 0 ]
  [ "$out" = "no agent runs recorded yet" ]
}

# ── Per-role table (default 7d window) ───────────────────────────────────────

@test "table: title, per-role rows, totals and footnotes" {
  write_fixture
  local out
  out="$(stats_main)"

  # Title reflects the window and the post-filter session count (rec5 @8d out).
  [ "$(head -n1 <<<"$out")" = "Agent runs — last 7d (5 sessions)" ]
  # Column headers (other column present because totals.other == 1).
  grep -qF 'role         runs    ok timeout maxturns other   median      p90   tokens in/out        $    tps compactions/run' <<<"$out"
  # dev row: 4 runs, 1 ok, 1 timeout, 1 maxturns, 1 other.
  grep -qE '^dev +4 +1 +1 +1 +1 ' <<<"$out"
  grep -qF '1h00m' <<<"$out"
  grep -qF '2h00m' <<<"$out"
  grep -qF '3.5M / 350K' <<<"$out"
  grep -qF '35.00' <<<"$out"
  grep -qF '11.7' <<<"$out"
  grep -qF '1.5' <<<"$out"
  # review row.
  grep -qE '^review +1 +1 +0 +0 +0 ' <<<"$out"
  grep -qF '200K / 20K' <<<"$out"
  grep -qF '15.0' <<<"$out"
  # totals row: 5 runs, 2 ok, 1 timeout, 1 maxturns, 1 other; median/p90/tps blank.
  grep -qE '^totals +5 +2 +1 +1 +1 ' <<<"$out"
  grep -qF '3.7M / 370K' <<<"$out"
  grep -qF '38.00' <<<"$out"
  grep -qE '^totals +5 +2 +1 +1 +1 + + + ' <<<"$out"
  # Footnotes: one no-duration session, three malformed lines.
  grep -qF '* 1 session(s) with no duration (killed mid-run) excluded from duration and tps stats' <<<"$out"
  grep -qF 'skipped 3 malformed line(s) in' <<<"$out"
}

# ── --json: exact figures ────────────────────────────────────────────────────

@test "--json: records, skipped and per-role/totals figures" {
  write_fixture
  local out
  out="$(stats_main --json)"

  [ "$(jq -r '.window' <<<"$out")" = "7d" ]
  [ "$(jq -r '.role' <<<"$out")" = "null" ]
  [ "$(jq -r '.records' <<<"$out")" = "5" ]
  [ "$(jq -r '.skipped' <<<"$out")" = "3" ]
  [ "$(jq -r '.excluded_no_duration' <<<"$out")" = "1" ]

  local dev
  dev="$(jq -c '.roles[] | select(.role=="dev")' <<<"$out")"
  [ "$(jq -r '.runs' <<<"$dev")" = "4" ]
  [ "$(jq -r '.ok' <<<"$dev")" = "1" ]
  [ "$(jq -r '.timeout' <<<"$dev")" = "1" ]
  [ "$(jq -r '.maxturns' <<<"$dev")" = "1" ]
  [ "$(jq -r '.other' <<<"$dev")" = "1" ]
  [ "$(jq -r '.excluded_no_duration' <<<"$dev")" = "1" ]
  [ "$(jq -r '.median_ms' <<<"$dev")" = "3600000" ]
  [ "$(jq -r '.p90_ms' <<<"$dev")" = "7200000" ]
  [ "$(jq -r '.input_tokens' <<<"$dev")" = "3500000" ]
  [ "$(jq -r '.output_tokens' <<<"$dev")" = "350000" ]
  [ "$(jq -r '.cost_usd' <<<"$dev")" = "35" ]
  # mean of {10,20,5} (rec2 tps is null) — check to 2 decimals to dodge locale
  [ "$(jq -r '.tps' <<<"$dev" | awk '{printf "%.1f", $0}')" = "11.7" ]
  [ "$(jq -r '.compactions_per_run' <<<"$dev")" = "1.5" ]

  local rev
  rev="$(jq -c '.roles[] | select(.role=="review")' <<<"$out")"
  [ "$(jq -r '.runs' <<<"$rev")" = "1" ]
  [ "$(jq -r '.median_ms' <<<"$rev")" = "1800000" ]
  [ "$(jq -r '.input_tokens' <<<"$rev")" = "200000" ]
  [ "$(jq -r '.output_tokens' <<<"$rev")" = "20000" ]
  [ "$(jq -r '.tps' <<<"$rev")" = "15" ]

  local tot
  tot="$(jq -c '.totals' <<<"$out")"
  [ "$(jq -r '.runs' <<<"$tot")" = "5" ]
  [ "$(jq -r '.ok' <<<"$tot")" = "2" ]
  [ "$(jq -r '.timeout' <<<"$tot")" = "1" ]
  [ "$(jq -r '.maxturns' <<<"$tot")" = "1" ]
  [ "$(jq -r '.other' <<<"$tot")" = "1" ]
  [ "$(jq -r '.input_tokens' <<<"$tot")" = "3700000" ]
  [ "$(jq -r '.output_tokens' <<<"$tot")" = "370000" ]
  [ "$(jq -r '.cost_usd' <<<"$tot")" = "38" ]
  [ "$(jq -r '.compactions_per_run' <<<"$tot")" = "1.2" ]
}

# ── delivered / partial (#1167) ─────────────────────────────────────────────

@test "timeout with delivered: true counts as partial, not timeout" {
  mkrec 3600 dev timeout 1201 - - - - - 0 true
  mkrec 3600 dev timeout 1202 - - - - - 0 false
  local out
  out="$(stats_main)"

  # partial column present, other column absent.
  grep -qF 'partial' <<<"$out"
  ! grep -qF ' maxturns other' <<<"$out"
  # dev row: 2 runs, 0 ok, 1 timeout (the undelivered one), 0 maxturns, 1 partial.
  grep -qE '^dev +2 +0 +1 +0 +1 ' <<<"$out"
  grep -qE '^totals +2 +0 +1 +0 +1 ' <<<"$out"
  # Footnote explains the partial column; both runs lack a duration.
  grep -qF '* 1 run(s) exited non-success but had work pushed (delivered: true) — in partial, not in the outcome columns' <<<"$out"
  grep -qF '* 2 session(s) with no duration (killed mid-run) excluded from duration and tps stats' <<<"$out"
}

@test "error_max_turns with delivered: true counts as partial" {
  mkrec 3600 dev error_max_turns 1203 7200000 2000000 200000 20 20 3 true
  local out
  out="$(stats_main)"
  # dev row: 1 run, 0 ok, 0 timeout, 0 maxturns, 1 partial.
  grep -qE '^dev +1 +0 +0 +0 +1 ' <<<"$out"
  grep -qE '^totals +1 +0 +0 +0 +1 ' <<<"$out"
}

@test "--json: partial is reported in roles and totals" {
  mkrec 3600 dev timeout 1204 - - - - - 0 true
  mkrec 3600 dev timeout 1205 - - - - - 0
  local out
  out="$(stats_main --json)"

  local dev
  dev="$(jq -c '.roles[] | select(.role=="dev")' <<<"$out")"
  [ "$(jq -r '.partial' <<<"$dev")" = "1" ]
  [ "$(jq -r '.timeout' <<<"$dev")" = "1" ]
  [ "$(jq -r '.totals.partial' <<<"$out")" = "1" ]
  [ "$(jq -r '.totals.timeout' <<<"$out")" = "1" ]
}

@test "records without a delivered field stay in the outcome columns, unchanged" {
  mkrec 3600 dev timeout 1206 - - - - - 0
  local out
  out="$(stats_main)"
  # No partial column: rendering is identical to pre-#1167 output.
  ! grep -qF 'partial' <<<"$out"
  grep -qE '^dev +1 +0 +1 ' <<<"$out"
  grep -qE '^totals +1 +0 +1 ' <<<"$out"
}

# ── --since filtering ────────────────────────────────────────────────────────

@test "--since 24h: drops the 48h and 8d records, hides the other column" {
  write_fixture
  local out
  out="$(stats_main --since 24h)"
  [ "$(head -n1 <<<"$out")" = "Agent runs — last 24h (4 sessions)" ]
  # No "other" column now (only success/timeout/maxturns in window).
  ! grep -qF 'maxturns other' <<<"$out"
  grep -qE '^dev +3 +1 +1 +1 ' <<<"$out"
  # dev durations {3600000,7200000} -> median 5400000 (1h30m), p90 7200000 (2h00m)
  grep -qF '1h30m' <<<"$out"
  grep -qF '2h00m' <<<"$out"
  grep -qF '3.0M / 300K' <<<"$out"
  grep -qF '30.00' <<<"$out"
}

@test "--since 12h: three sessions (dev x2, review x1)" {
  write_fixture
  local out
  out="$(stats_main --since 12h)"
  [ "$(head -n1 <<<"$out")" = "Agent runs — last 12h (3 sessions)" ]
  grep -qE '^dev +2 +1 +1 ' <<<"$out"
  grep -qE '^review +1 +1 ' <<<"$out"
}

@test "invalid --since is rejected with a non-zero exit" {
  write_fixture
  local out rc=0
  out="$(stats_main --since 5w 2>&1)" || rc=$?
  [ "$rc" -eq 1 ]
  grep -qi 'since' <<<"$out"
}

# ── --role filtering ─────────────────────────────────────────────────────────

@test "--role review: only the review sessions" {
  write_fixture
  local out
  out="$(stats_main --role review)"
  [ "$(head -n1 <<<"$out")" = "Agent runs — last 7d, role review (1 sessions)" ]
  grep -qE '^review +1 +1 ' <<<"$out"
  ! grep -qE '^dev ' <<<"$out"
  [ "$(jq -r '.role' <<<"$(stats_main --role review --json)")" = "review" ]
}

# ── --task attribution ───────────────────────────────────────────────────────

@test "--task 1102 lists every record attributed to the task" {
  write_fixture
  local out n
  out="$(stats_main --task 1102)"
  n="$(grep -c '' <<<"$out")"
  [ "$n" -eq 3 ]
  # Each line is a parseable record with task_ref 1102.
  while IFS= read -r line; do
    [ "$(jq -r '.task_ref' <<<"$line")" = "1102" ]
  done <<<"$out"
}

@test "--task accepts a leading # and matches the same records" {
  write_fixture
  local n
  n="$(stats_main --task '#1102' | grep -c '')"
  [ "$n" -eq 3 ]
}

@test "--task with no records prints a message and exits 0" {
  write_fixture
  local out rc
  out="$(stats_main --task 9999)"; rc=$?
  [ "$rc" -eq 0 ]
  [ "$out" = "no runs recorded for task 9999" ]
}

# ── epoch -> ISO helper ──────────────────────────────────────────────────────

@test "stats_epoch_to_iso converts known epochs correctly" {
  [ "$(stats_epoch_to_iso 0)" = "1970-01-01T00:00:00Z" ]
  [ "$(stats_epoch_to_iso 86399)" = "1970-01-01T23:59:59Z" ]
  [ "$(stats_epoch_to_iso 86400)" = "1970-01-02T00:00:00Z" ]
  [ "$(stats_epoch_to_iso 1000000000)" = "2001-09-09T01:46:40Z" ]
}
