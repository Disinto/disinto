#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2061.sh
#
# Issue #2061: feat(tools): a stuck sample names the model that served its
# proposal
#
# tools/tape-stuck.sh (#1648) emits each stuck proposal in the sample shape
# calibration groups on, but with no model. Once calibration groups by
# (loop, class, model) (#2062), a stuck sample without one cannot join its
# model's row. Inside the tape-listing branch, tools/tape-stuck.sh now runs
# tools/tape-model.sh (#2059) once and passes its output to the listing as
# MODELS_JSON; each sample gains "model": models.get(id, "-"). If
# tape-model.sh exits non-zero or prints something that is not a JSON object,
# tape-stuck.sh exits 1 with a "tape-stuck: failed to read models" line on
# stderr and nothing on stdout. A missing or empty tape still prints []
# without running the model tool.
#
# Hermetic: no network, no forge, no agents, no writes. Per-scenario tmp
# TAPE_DIRs, fixture packs, fixed CALIBRATION_NOW.
#
# Acceptance:
#   AC1  stuck pack dev = 48, clock 72 h after the proposals: p-1 (no
#        outcome) with a run agent "dsh/qwen3.8-flash-next-q2_0" -> the
#        sample has .model == "qwen3.8-flash-next-q2_0"
#   AC2  p-2 (no outcome, no run, no backend) -> .model == "-"; p-3 (no
#        outcome, run "bash", context.backend "grok-4.7") -> .model ==
#        "grok-4.7"
#   AC3  every sample still has competence == [false], signature == "stuck",
#        duration == null, est_dvision == null, and the three samples come in
#        tape order
#   AC4  a copy of tools/ whose tape-model.sh is exit 1: tape-stuck.sh exits
#        1, prints nothing on stdout and a "tape-stuck:" line on stderr; the
#        same copy with a missing tape prints [] with rc 0
#   AC5  bash -n tools/tape-stuck.sh passes; tests/acceptance/issue-1648.sh
#        still passes unchanged
#
# Run via: tools/run-acceptance.sh 2061
# Contract: executable bash, set -euo pipefail, exit 0, last stdout line PASS
# (or FAIL: <reason>).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq python3
ac_assert_file "$REPO_ROOT/tools/tape-stuck.sh" "tools/tape-stuck.sh is missing"
ac_assert_file "$REPO_ROOT/tools/tape-model.sh" "tools/tape-model.sh is missing"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Fixture packs (hermetic, no ops repo involved) ────────────────────────────

PACKS="$TMP_DIR/packs"
mkdir -p "$PACKS"
cat > "$PACKS/loops.toml" <<'EOF'
dev = "merged"
EOF
cat > "$PACKS/stuck.toml" <<'EOF'
dev = 48
EOF

# Fixed clock: 2026-02-10 00:00:00 UTC; proposals 72 h old = 2026-02-07.
export CALIBRATION_NOW="2026-02-10T00:00:00Z"
export CALIBRATION_LOOPS_FILE="$PACKS/loops.toml"
export CALIBRATION_STUCK_FILE="$PACKS/stuck.toml"
export TAPE_DIR="$TMP_DIR/tape"
mkdir -p "$TAPE_DIR"

# run_stuck <tool> — run the given tape-stuck tool; stdout in $OUT, stderr in
# $ERR, exit code in $RC. Nothing leaks onto the test's own stdout.
run_stuck() {
  RC=0
  OUT=""
  OUT="$(bash "$1" 2>"$TMP_DIR/err")" || RC=$?
  ERR="$(cat "$TMP_DIR/err" 2>/dev/null || true)"
}

# ── AC1: the run's agent names the model ──────────────────────────────────────

ac_log "AC1: p-1 run agent dsh/qwen3.8-flash-next-q2_0 -> .model == qwen3.8-flash-next-q2_0"
cat > "$TAPE_DIR/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-07T00:00:00Z","id":"p-1","loop":"dev","class":"backlog","context":{},"forecast":{"p_success":0.7},"decision":"approved","ref":"2061-1"}
{"type":"run","t":"2026-02-07T00:10:00Z","proposal_id":"p-1","organ":"dev","agent":"dsh/qwen3.8-flash-next-q2_0","started":"2026-02-07T00:10:00Z","attempts":1}
EOF
run_stuck "$REPO_ROOT/tools/tape-stuck.sh"
ac_assert_eq "$RC" "0" "AC1: must exit 0 (rc=$RC, err: $ERR)"
ac_assert_jq 'length == 1 and .[0].model == "qwen3.8-flash-next-q2_0"' "$OUT" \
  "AC1: the sample names the model of the run that served it (got: $OUT)"
ac_log "AC1 OK"

# ── AC2: no run and no backend -> "-"; backend fills in for a bash-only run ──

ac_log "AC2: p-2 (no run, no backend) -> \"-\"; p-3 (bash run, backend grok-4.7) -> grok-4.7"
cat > "$TAPE_DIR/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-07T00:00:00Z","id":"p-1","loop":"dev","class":"backlog","context":{},"forecast":{"p_success":0.7},"decision":"approved","ref":"2061-1"}
{"type":"run","t":"2026-02-07T00:10:00Z","proposal_id":"p-1","organ":"dev","agent":"dsh/qwen3.8-flash-next-q2_0","started":"2026-02-07T00:10:00Z","attempts":1}
{"type":"proposal","t":"2026-02-07T00:00:00Z","id":"p-2","loop":"dev","class":"review","context":{},"decision":"approved","ref":"2061-2"}
{"type":"proposal","t":"2026-02-07T00:00:00Z","id":"p-3","loop":"dev","class":"gardener","context":{"backend":"grok-4.7"},"decision":"approved","ref":"2061-3"}
{"type":"run","t":"2026-02-07T00:10:00Z","proposal_id":"p-3","organ":"dev","agent":"bash","started":"2026-02-07T00:10:00Z","attempts":1}
EOF
run_stuck "$REPO_ROOT/tools/tape-stuck.sh"
ac_assert_eq "$RC" "0" "AC2: must exit 0 (rc=$RC, err: $ERR)"
ac_assert_jq 'length == 3' "$OUT" "AC2: all three proposals are stuck (got: $OUT)"
ac_assert_jq '.[1].model == "-"' "$OUT" "AC2: a proposal with no run and no backend gets \"-\" (got: $OUT)"
ac_assert_jq '.[2].model == "grok-4.7"' "$OUT" "AC2: a bash-only run names no model, so context.backend wins (got: $OUT)"
ac_log "AC2 OK"

# ── AC3: the other seven fields unchanged, samples in tape order ──────────────

ac_log "AC3: competence [false], signature stuck, duration/est_dvision null, tape order"
ac_assert_jq 'all(.[]; .competence == [false] and .signature == "stuck"
               and .duration == null and .est_dvision == null)' "$OUT" \
  "AC3: every sample keeps the failure-sample fields (got: $OUT)"
ac_assert_jq 'map(.class) == ["backlog", "review", "gardener"]' "$OUT" \
  "AC3: samples come in tape order (got: $OUT)"
ac_log "AC3 OK"

# ── AC4: a broken tape-model.sh fails the listing; a missing tape does not ────

ac_log "AC4: a copy of tools/ with tape-model.sh exit 1 -> rc 1, empty stdout, tape-stuck: stderr"
TOOLS_COPY="$TMP_DIR/tools-copy"
mkdir -p "$TOOLS_COPY"
cp "$REPO_ROOT/tools/tape-stuck.sh" "$TOOLS_COPY/tape-stuck.sh"
cp "$REPO_ROOT/tools/tape-model.sh" "$TOOLS_COPY/tape-model.sh"
printf 'exit 1\n' > "$TOOLS_COPY/tape-model.sh"
chmod +x "$TOOLS_COPY/tape-model.sh"
run_stuck "$TOOLS_COPY/tape-stuck.sh"
ac_assert_eq "$RC" "1" "AC4: a failing tape-model.sh must exit 1 (rc=$RC)"
ac_assert_eq "$OUT" "" "AC4: nothing on stdout when the model read fails (got: $OUT)"
case "$ERR" in
  *"tape-stuck:"*) ;;
  *) ac_fail "AC4: stderr must carry a tape-stuck: line (got: $ERR)" ;;
esac

ac_log "AC4: a missing tape still prints [] with the broken copy"
EMPTY_DIR="$TMP_DIR/tape-none"
mkdir -p "$EMPTY_DIR"
TAPE_DIR="$EMPTY_DIR" run_stuck "$TOOLS_COPY/tape-stuck.sh"
ac_assert_eq "$RC" "0" "AC4: a missing tape with a broken tape-model.sh must exit 0 (rc=$RC)"
ac_assert_eq "$OUT" "[]" "AC4: a missing tape prints [] without running the model tool (got: $OUT)"

ac_log "AC4: a tape-model.sh that exits 0 but prints no JSON object also fails the listing"
printf 'printf not-a-json-object\n' > "$TOOLS_COPY/tape-model.sh"
run_stuck "$TOOLS_COPY/tape-stuck.sh"
ac_assert_eq "$RC" "1" "AC4: a non-object model map must exit 1 (rc=$RC)"
ac_assert_eq "$OUT" "" "AC4: nothing on stdout for a bad model map (got: $OUT)"
ac_log "AC4 OK"

# ── AC5: bash -n and the untouched #1648 acceptance test ──────────────────────

ac_log "AC5: bash -n tools/tape-stuck.sh"
bash -n "$REPO_ROOT/tools/tape-stuck.sh" \
  || ac_fail "AC5: tools/tape-stuck.sh must parse with bash -n"

ac_log "AC5: tests/acceptance/issue-1648.sh still passes unchanged"
RC1648=0
OUT1648="$(bash "$REPO_ROOT/tests/acceptance/issue-1648.sh" 2>&1)" || RC1648=$?
ac_assert_eq "$RC1648" "0" "AC5: issue-1648.sh must pass unchanged (rc=$RC1648): $OUT1648"
ac_log "AC5 OK"

ac_pass
