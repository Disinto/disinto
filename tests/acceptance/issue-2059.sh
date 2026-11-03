#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2059.sh
#
# Issue #2059: feat(tools): tape-model.sh maps each proposal to the model that
# served it
#
# The tape joins a result to a model only through the run: a run record carries
# `agent` = <harness>/<model> (the served model since #2012), an outcome
# carries `proposal_id` only, and a dev proposal carries `context.backend`
# (the served model since #2014). tools/tape-model.sh reads
# ${TAPE_DIR:-/srv/disinto/tape}/tape.jsonl and prints one JSON object keyed
# by proposal id: the model label is the agent of the LAST run in tape order
# whose agent is a string containing `/`, with everything up to and including
# the first `/` removed; else the proposal's non-empty context.backend; else
# the proposal is absent from the object. A run whose agent has no `/` (bash)
# names no model. A missing or empty tape prints {}. Malformed lines are
# skipped with one stderr note and never fail the tool. Exit 1 only when jq
# is missing.
#
# Hermetic: no network, no forge, no agents, no writes. Per-scenario tmp
# TAPE_DIR fixtures.
#
# Acceptance:
#   AC1  proposal + one run agent "dsh/unsloth/Qwen3.8-27B" -> p1 maps to
#        "unsloth/Qwen3.8-27B"
#   AC2  open run "dsh/a", its closing record "dsh/a", then a run
#        "dsh/qwen3.8-flash-next-q2_0" -> p2 maps to the last run's model
#   AC3  run agent "bash", context.backend "grok-4.7" -> p3 maps to
#        "grok-4.7"
#   AC4  p4 (no run, no backend) and p5 (run "bash", no backend) are absent;
#        the object has exactly three keys
#   AC5  a missing tape prints {} with rc 0
#   AC6  a torn last line is skipped: same object, one stderr line, rc 0
#   AC7  tools/tape-model.sh passes `bash -n` and carries the exec bit
#
# Run via: tools/run-acceptance.sh 2059
# Contract: executable bash, set -euo pipefail, exit 0, last stdout line PASS
# (or FAIL: <reason>).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq
ac_assert_file "$REPO_ROOT/tools/tape-model.sh" "tools/tape-model.sh is missing"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# run_model [tape-file] — run the tool against $1; stdout in $OUT, stderr in
# $ERR, exit code in $RC. Nothing leaks onto the test's own stdout.
run_model() {
  RC=0
  OUT=""
  OUT="$(TAPE_DIR="$1" bash "$REPO_ROOT/tools/tape-model.sh" 2>"$TMP_DIR/err")" || RC=$?
  ERR="$(cat "$TMP_DIR/err" 2>/dev/null || true)"
}

# ── AC1: the run's agent names the model ─────────────────────────────────────

ac_log "AC1: run agent dsh/unsloth/Qwen3.8-27B -> p1 == unsloth/Qwen3.8-27B"
TAPE1="$TMP_DIR/tape1"
mkdir -p "$TAPE1"
cat > "$TAPE1/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-11-01T00:00:00Z","id":"p1","loop":"dev","class":"backlog","context":{},"decision":"approved","ref":"2059-1"}
{"type":"run","t":"2026-11-01T00:10:00Z","proposal_id":"p1","organ":"dev","agent":"dsh/unsloth/Qwen3.8-27B","started":"2026-11-01T00:10:00Z","attempts":1}
EOF
run_model "$TAPE1"
ac_assert_eq "$RC" "0" "AC1: must exit 0 (rc=$RC, err: $ERR)"
ac_assert_jq '.p1 == "unsloth/Qwen3.8-27B"' "$OUT" "AC1: the agent minus the harness prefix names the model (got: $OUT)"
ac_log "AC1 OK"

# ── AC2: the last run in tape order wins ─────────────────────────────────────

ac_log "AC2: open run dsh/a, closing dsh/a, then run dsh/qwen3.8-flash-next-q2_0 -> last wins"
TAPE2="$TMP_DIR/tape2"
mkdir -p "$TAPE2"
cat > "$TAPE2/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-11-01T00:00:00Z","id":"p2","loop":"dev","class":"backlog","context":{},"decision":"approved","ref":"2059-2"}
{"type":"run","t":"2026-11-01T00:10:00Z","proposal_id":"p2","organ":"dev","agent":"dsh/a","started":"2026-11-01T00:10:00Z","attempts":1}
{"type":"run","t":"2026-11-01T00:20:00Z","proposal_id":"p2","organ":"dev","agent":"dsh/a","started":"2026-11-01T00:10:00Z","ended":"2026-11-01T00:20:00Z","attempts":1,"status":"failed"}
{"type":"run","t":"2026-11-01T00:30:00Z","proposal_id":"p2","organ":"dev","agent":"dsh/qwen3.8-flash-next-q2_0","started":"2026-11-01T00:30:00Z","attempts":2}
EOF
run_model "$TAPE2"
ac_assert_eq "$RC" "0" "AC2: must exit 0 (rc=$RC, err: $ERR)"
ac_assert_jq '.p2 == "qwen3.8-flash-next-q2_0"' "$OUT" "AC2: the last run in tape order names the model (got: $OUT)"
ac_log "AC2 OK"

# ── AC3: a run whose agent has no / names no model; backend fills in ─────────

ac_log "AC3: run agent bash, context.backend grok-4.7 -> p3 == grok-4.7"
TAPE3="$TMP_DIR/tape3"
mkdir -p "$TAPE3"
cat > "$TAPE3/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-11-01T00:00:00Z","id":"p3","loop":"dev","class":"backlog","context":{"backend":"grok-4.7"},"decision":"approved","ref":"2059-3"}
{"type":"run","t":"2026-11-01T00:10:00Z","proposal_id":"p3","organ":"dev","agent":"bash","started":"2026-11-01T00:10:00Z","attempts":1}
EOF
run_model "$TAPE3"
ac_assert_eq "$RC" "0" "AC3: must exit 0 (rc=$RC, err: $ERR)"
ac_assert_jq '.p3 == "grok-4.7"' "$OUT" "AC3: an agent with no / names no model, so context.backend wins (got: $OUT)"
ac_log "AC3 OK"

# ── AC4: proposals with no model at all are absent ───────────────────────────

ac_log "AC4: p4 (no run, no backend) and p5 (run bash, no backend) absent; 3 keys"
TAPE4="$TMP_DIR/tape4"
mkdir -p "$TAPE4"
cat > "$TAPE4/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-11-01T00:00:00Z","id":"p1","loop":"dev","class":"backlog","context":{},"decision":"approved","ref":"2059-1"}
{"type":"run","t":"2026-11-01T00:10:00Z","proposal_id":"p1","organ":"dev","agent":"dsh/unsloth/Qwen3.8-27B","started":"2026-11-01T00:10:00Z","attempts":1}
{"type":"proposal","t":"2026-11-01T00:00:00Z","id":"p2","loop":"dev","class":"backlog","context":{},"decision":"approved","ref":"2059-2"}
{"type":"run","t":"2026-11-01T00:10:00Z","proposal_id":"p2","organ":"dev","agent":"dsh/a","started":"2026-11-01T00:10:00Z","attempts":1}
{"type":"run","t":"2026-11-01T00:20:00Z","proposal_id":"p2","organ":"dev","agent":"dsh/a","started":"2026-11-01T00:10:00Z","ended":"2026-11-01T00:20:00Z","attempts":1,"status":"failed"}
{"type":"run","t":"2026-11-01T00:30:00Z","proposal_id":"p2","organ":"dev","agent":"dsh/qwen3.8-flash-next-q2_0","started":"2026-11-01T00:30:00Z","attempts":2}
{"type":"proposal","t":"2026-11-01T00:00:00Z","id":"p3","loop":"dev","class":"backlog","context":{"backend":"grok-4.7"},"decision":"approved","ref":"2059-3"}
{"type":"run","t":"2026-11-01T00:10:00Z","proposal_id":"p3","organ":"dev","agent":"bash","started":"2026-11-01T00:10:00Z","attempts":1}
{"type":"proposal","t":"2026-11-01T00:00:00Z","id":"p4","loop":"dev","class":"backlog","context":{},"decision":"approved","ref":"2059-4"}
{"type":"proposal","t":"2026-11-01T00:00:00Z","id":"p5","loop":"dev","class":"backlog","context":{},"decision":"approved","ref":"2059-5"}
{"type":"run","t":"2026-11-01T00:10:00Z","proposal_id":"p5","organ":"dev","agent":"bash","started":"2026-11-01T00:10:00Z","attempts":1}
EOF
run_model "$TAPE4"
ac_assert_eq "$RC" "0" "AC4: must exit 0 (rc=$RC, err: $ERR)"
ac_assert_jq 'has("p4") | not' "$OUT" "AC4: a proposal with no run and no backend is absent (got: $OUT)"
ac_assert_jq 'has("p5") | not' "$OUT" "AC4: a bash-only run with no backend names no model (got: $OUT)"
ac_assert_jq 'keys | length == 3' "$OUT" "AC4: exactly p1, p2, p3 are keyed (got: $OUT)"
ac_log "AC4 OK"

# ── AC5: a missing tape prints {} ────────────────────────────────────────────

ac_log "AC5: missing tape -> {} rc 0"
run_model "$TMP_DIR/does-not-exist"
ac_assert_eq "$RC" "0" "AC5: a missing tape must exit 0 (rc=$RC, err: $ERR)"
ac_assert_eq "$OUT" "{}" "AC5: a missing tape prints {} (got: $OUT)"
mkdir -p "$TMP_DIR/empty"
: > "$TMP_DIR/empty/tape.jsonl"
run_model "$TMP_DIR/empty"
ac_assert_eq "$RC" "0" "AC5: an empty tape must exit 0 (rc=$RC, err: $ERR)"
ac_assert_eq "$OUT" "{}" "AC5: an empty tape prints {} (got: $OUT)"
ac_log "AC5 OK"

# ── AC6: a torn final line is skipped, one stderr note, rc 0 ─────────────────

ac_log "AC6: torn last line -> same object, one stderr line, rc 0"
TAPE6="$TMP_DIR/tape6"
mkdir -p "$TAPE6"
cat > "$TAPE6/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-11-01T00:00:00Z","id":"p1","loop":"dev","class":"backlog","context":{},"decision":"approved","ref":"2059-1"}
{"type":"run","t":"2026-11-01T00:10:00Z","proposal_id":"p1","organ":"dev","agent":"dsh/unsloth/Qwen3.8-27B","started":"2026-11-01T00:10:00Z","attempts":1}
EOF
printf '{"type":"run","t":"2026-11-01T00:20:00Z","proposal_id":"p1","organ":"dev","age' >> "$TAPE6/tape.jsonl"
run_model "$TAPE6"
ac_assert_eq "$RC" "0" "AC6: a malformed line must not fail the tool (rc=$RC, err: $ERR)"
ac_assert_jq 'length == 1 and .p1 == "unsloth/Qwen3.8-27B"' "$OUT" "AC6: the object is unchanged by the torn line (got: $OUT)"
ERR_LINES=0
if [ -n "$ERR" ]; then
  ERR_LINES="$(printf '%s\n' "$ERR" | grep -c '' || true)"
fi
ac_assert_eq "$ERR_LINES" "1" "AC6: exactly one stderr note for the malformed line (err: $ERR)"
ac_log "AC6 OK"

# ── AC7: bash -n passes and the file is executable ───────────────────────────

ac_log "AC7: bash -n tools/tape-model.sh and the exec bit"
bash -n "$REPO_ROOT/tools/tape-model.sh" \
  || ac_fail "AC7: tools/tape-model.sh must parse with bash -n"
[ -x "$REPO_ROOT/tools/tape-model.sh" ] \
  || ac_fail "AC7: tools/tape-model.sh must be executable (exec bit)"
ac_log "AC7 OK"

ac_pass
