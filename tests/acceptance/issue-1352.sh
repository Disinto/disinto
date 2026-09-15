#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1352.sh — oak/status.sh prints last tick and Q row
#
# Issue #1352: one command that prints the last action, the last key, r,
# and the Q row for that key, against $OPS_REPO_ROOT/oak/ (read-only —
# weights are never written, no organ is started).
#
# Verifies, against the repo checkout's oak/status.sh, running against a
# private temp ops dir (no live state is touched):
#   1. missing last.json → exit 0, stdout contains `boot`
#   2. fixture last.json + weights with a Q row for that key + one
#      transition line → stdout contains the action, the key, r, and a
#      Q_ROW= line that is the Q row as one JSON object; the weights file
#      is byte-identical afterwards (read-only)
#   3. OPS_REPO_ROOT unset → exit 2 with a one-line usage on stderr
#
# Last stdout line is PASS or FAIL: <reason>.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash
ac_require_cmd jq

STATUS="$REPO_ROOT/oak/status.sh"
ac_assert_file "$STATUS" "oak/status.sh must exist in the checkout"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
cd "$TMPD"

OPS="$TMPD/ops"
mkdir -p "$OPS/oak"

# run_status <ops-root> — run oak/status.sh; echoes stdout, returns its code.
run_status() {
  OPS_REPO_ROOT="$1" bash "$STATUS" 2>"$TMPD/status-err.log"
}

ac_log "1. missing last.json → exit 0, stdout contains boot"
if ! OUT="$(run_status "$OPS")"; then
  ac_fail "status.sh must exit 0 when last.json is missing (got non-zero)"
fi
case "$OUT" in
  *boot*) ;;
  *) ac_fail "missing last.json must print a boot message, got: $OUT" ;;
esac

ac_log "2. fixture last.json + weights Q row → action, key, r, and Q_ROW object"
cat >"$OPS/oak/last.json" <<'EOF'
{"x_key":"0|1","a":"dev-poll","x":{"here":1}}
EOF
cat >"$OPS/oak/weights.json" <<'EOF'
{"q0":1.0,"gvf":{"purpose":{"Q":{"0|1":{"dev-poll":1.5,"idle":0.9}}},"inbound":{"V":{}}}}
EOF
cat >"$OPS/oak/transitions.jsonl" <<'EOF'
{"t":"2026-01-01T00:00:00Z","x":{"here":1},"a":"dev-poll","r":2,"x2":{"here":1}}
EOF
WEIGHTS_BEFORE="$(cat "$OPS/oak/weights.json")"

if ! OUT="$(run_status "$OPS")"; then
  ac_fail "status.sh must exit 0 on a fixture ops dir (got non-zero)"
fi
case "$OUT" in
  *"dev-poll"*) ;;
  *) ac_fail "stdout must contain the last action (dev-poll), got: $OUT" ;;
esac
case "$OUT" in
  *"0|1"*) ;;
  *) ac_fail "stdout must contain the last key (0|1), got: $OUT" ;;
esac
case "$OUT" in
  *"r: 2"*) ;;
  *) ac_fail "stdout must contain r: 2 from the last transition line, got: $OUT" ;;
esac
QROW_LINE="$(grep '^Q_ROW=' <<<"$OUT" || true)"
[ -n "$QROW_LINE" ] \
  || ac_fail "stdout must contain a Q_ROW= line, got: $OUT"
QROW="$(jq -c . <<<"${QROW_LINE#Q_ROW=}" 2>/dev/null)" \
  || ac_fail "Q_ROW value must be one JSON object, got: $QROW_LINE"
[ "$QROW" = '{"dev-poll":1.5,"idle":0.9}' ] \
  || ac_fail "Q_ROW must be the purpose-Q row for the last key, got: $QROW"

WEIGHTS_AFTER="$(cat "$OPS/oak/weights.json")"
[ "$WEIGHTS_BEFORE" = "$WEIGHTS_AFTER" ] \
  || ac_fail "status.sh must not write weights.json"
[ ! -f "$OPS/oak/weights.json.tmp" ] \
  || ac_fail "status.sh must not leave a weights temp file"

ac_log "3. OPS_REPO_ROOT unset → exit 2 with one-line usage on stderr"
set +e
OUT="$(env -u OPS_REPO_ROOT bash "$STATUS" 2>"$TMPD/noenv-err.log")"
RC=$?
set -e
[ "$RC" -eq 2 ] \
  || ac_fail "OPS_REPO_ROOT unset must exit 2, got: $RC"
[ -z "$OUT" ] \
  || ac_fail "OPS_REPO_ROOT unset must print nothing on stdout, got: $OUT"
ERR="$(cat "$TMPD/noenv-err.log")"
[ -n "$ERR" ] \
  || ac_fail "OPS_REPO_ROOT unset must print a one-line usage on stderr"
[ "$(printf '%s\n' "$ERR" | grep -c .)" -eq 1 ] \
  || ac_fail "usage on stderr must be exactly one line, got: $ERR"

echo PASS
