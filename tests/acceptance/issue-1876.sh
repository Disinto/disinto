#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1876.sh
#
# Issue #1876: a claim check gives its probe the claim's window.
#
# tools/claim-checks.sh must hand each claim's `window` to its probe as
# PROBE_WINDOW_DAYS (rounded up) / PROBE_WINDOW_S (exact, in seconds). This
# test plants stub claims with stub probes that echo one of those variables and
# asserts the value that lands at the front of ${TAPE_DIR}/claims/<id>.last.
#
# AC1  window 14d, probe echoes $PROBE_WINDOW_DAYS -> .last starts with 14
# AC2  window 36h, probe echoes $PROBE_WINDOW_S    -> .last starts with 129600
# AC3  window 36h, probe echoes $PROBE_WINDOW_DAYS -> .last starts with 2
# AC4  PROBE_WINDOW_DAYS is unset in the tool-running shell after the run
#
# Hermetic: no network, no forge, no agent. Fixture probes live under a temp
# OPS_REPO_ROOT; the tape and claim files live under temp TAPE_DIR / CLAIMS_DIR.
# The tool is executed, not sourced.
#
# Acceptance: `bash tests/acceptance/issue-1876.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq flock python3 timeout date
ac_assert_file "$REPO_ROOT/tools/claim-checks.sh" "claim-checks.sh missing"
ac_assert_file "$REPO_ROOT/lib/claims.sh" "lib/claims.sh missing"

BASE_DIR="$(mktemp -d)"
trap 'rm -rf "$BASE_DIR"' EXIT
export OPS_REPO_ROOT="$BASE_DIR/ops" CLAIMS_DIR="$BASE_DIR/claims" \
  TAPE_DIR="$BASE_DIR/tape" PAYLOAD_DIR="$BASE_DIR/payloads"
mkdir -p "$OPS_REPO_ROOT/probes" "$CLAIMS_DIR" "$TAPE_DIR/claims" "$PAYLOAD_DIR"

# plant_claim ID CHECK WINDOW — a valid claim with the given window.
plant_claim() {
  local id="$1" check="$2" window="$3"
  printf '%s\n' \
    'statement = "the rate stays under the bound"' \
    'class     = "internal"' \
    "check     = \"${check}\"" \
    'expect    = "<= 129600"' \
    "window    = \"${window}\"" \
    'rests_on  = []' > "$CLAIMS_DIR/${id}.toml"
}

# plant_probe REL ECHOVAR — a non-executable probe that echoes ECHOVAR.
plant_probe() {
  local rel="$1" echovar="$2" d
  d="$OPS_REPO_ROOT/$rel"
  mkdir -p "$(dirname "$d")"
  printf '#!/usr/bin/env bash\necho "$%s"\n' "$echovar" >"$d"
  chmod a-x "$d"
}

# plant_current ID PID — the proposal this claim's checks pair with.
plant_current() {
  local id="$1" pid="$2"
  printf '%s\n' "$pid" >"$TAPE_DIR/claims/${id}.current"
}

# run_tool — execute claim-checks.sh against the fixture dirs.
# stdout -> $OUT, stderr -> $ERR, exit status -> $RC.
run_tool() {
  local errfile
  errfile="$BASE_DIR/tool.err"
  : >"$errfile"
  set +e
  OUT="$(bash "$REPO_ROOT/tools/claim-checks.sh" 2>"$errfile")"
  RC=$?
  set -e
  ERR=""
  if [ -s "$errfile" ]; then
    ERR="$(cat "$errfile")"
  fi
}

# first_word FILE — the first whitespace-delimited token of the file.
first_word() {
  head -n1 "$1" | awk '{print $1}'
}

# ── AC1: window 14d, probe echoes $PROBE_WINDOW_DAYS -> .last starts with 14 ─
ac_log "AC1: window 14d, probe echoes PROBE_WINDOW_DAYS -> .last starts with 14"
plant_claim win14 probes/win14.sh 14d
plant_probe probes/win14.sh PROBE_WINDOW_DAYS
plant_current win14 "pid-win14"
run_tool
ac_assert_eq "$RC" "0" "AC1 run must return 0 (got $RC): $OUT | $ERR"
ac_assert_eq "$(first_word "$TAPE_DIR/claims/win14.last")" "14" \
  "win14 .last must start with 14 (got '$(first_word "$TAPE_DIR/claims/win14.last")')"
ac_log "AC1 OK"

# ── AC2: window 36h, probe echoes $PROBE_WINDOW_S -> .last starts with 129600
ac_log "AC2: window 36h, probe echoes PROBE_WINDOW_S -> .last starts with 129600"
plant_claim win36s probes/win36s.sh 36h
plant_probe probes/win36s.sh PROBE_WINDOW_S
plant_current win36s "pid-win36s"
run_tool
ac_assert_eq "$RC" "0" "AC2 run must return 0 (got $RC): $OUT | $ERR"
ac_assert_eq "$(first_word "$TAPE_DIR/claims/win36s.last")" "129600" \
  "win36s .last must start with 129600 (got '$(first_word "$TAPE_DIR/claims/win36s.last")')"
ac_log "AC2 OK"

# ── AC3: window 36h, probe echoes $PROBE_WINDOW_DAYS -> .last starts with 2 ──
ac_log "AC3: window 36h, probe echoes PROBE_WINDOW_DAYS -> .last starts with 2"
plant_claim win36d probes/win36d.sh 36h
plant_probe probes/win36d.sh PROBE_WINDOW_DAYS
plant_current win36d "pid-win36d"
run_tool
ac_assert_eq "$RC" "0" "AC3 run must return 0 (got $RC): $OUT | $ERR"
ac_assert_eq "$(first_word "$TAPE_DIR/claims/win36d.last")" "2" \
  "win36d .last must start with 2 (got '$(first_word "$TAPE_DIR/claims/win36d.last")')"
ac_log "AC3 OK"

# ── AC4: PROBE_WINDOW_DAYS not set in the tool-running shell after the run ──
ac_log "AC4: PROBE_WINDOW_DAYS unset after running the tool"
[ -z "${PROBE_WINDOW_DAYS:-}" ] \
  || ac_fail "PROBE_WINDOW_DAYS must not leak into the tool-running shell (got '${PROBE_WINDOW_DAYS:-}')'"
ac_log "AC4 OK"

ac_pass
