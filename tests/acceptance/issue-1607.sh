#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1607.sh
#
# Issue #1607: tape outcomes may carry a rubric signature.
#
# tape_outcome (lib/tape.sh) gains an optional 6th argument SIGNATURE:
#   - set  & matches  ^[a-z][a-z0-9-]*$  -> the record gains "signature"
#   - set  & no match -> refused (rc 1), nothing appended
#   - absent / empty  -> record byte-identical to pre-#1607 (no key)
#
# A generic, loop-agnostic reader resolves a reason to a signature in a loop
# rubric (lib/signature.sh): signature_for REASON LOOP. It reads only the
# [map] table of <rubrics>/<LOOP>.toml, and prints nothing (always rc 0) when
# the file is missing/unreadable, [map] is absent, or REASON is not a key.
# No caller is wired by this issue — this test exercises the two libs directly.
#
# The rubric is CONTENT living in disinto-ops, never in lib/. This test keeps
# the loop/sig names ONLY in a throwaway fixture under $TMP_DIR (never
# committed), so lib/ genericity is exercised against real (loop/sig) content
# without naming it in source.
#
# Acceptance (read-only — no live services, no agents started, no state
# mutation; hand-written tmp TAPE_DIR + hermetic RUBRICS_DIR fixture):
#   1. valid signature (agent-loop)   -> rc 0, record has "signature"
#   2. absent/empty signature         -> rc 0, record has NO "signature" key
#   3. invalid signature (uppercase)  -> rc 1, nothing appended
#   4. signature_for known reason     -> prints the mapped signature, rc 0
#   5. signature_for known reason 2   -> prints the other mapped signature, rc 0
#   6. signature_for unknown reason   -> empty output, rc 0
#   7. signature_for missing loop     -> empty output, rc 0
#
# Contract: executable bash, set -euo pipefail, exit 0, last stdout line PASS
# (or FAIL: <reason>). Uses tests/lib/acceptance-helpers.sh helpers.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq python3 awk grep

# ── Hermetic fixture (loop/sig names live ONLY here, never in lib/) ──────────

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# The loop rubric: [map] reason->signature (what signature_for reads) plus the
# [ <signature> ] attribution tables (metadata for the future calibration reader;
# signature_for does NOT consult them).
RUBRICS_DIR="$TMP_DIR/rubrics"
mkdir -p "$RUBRICS_DIR"
cat > "$RUBRICS_DIR/dev.toml" <<'EOF'
[map]
agent_failed = "agent-loop"
ci_exhausted_poll = "ci-timeout"

[agent-loop]
attribution = "work"

[ci-timeout]
attribution = "world"
EOF

# Canonical sha256 (of the empty string), used as the payload ref.
H="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
export REPO_ROOT="$REPO_ROOT"
# The four outcome data args, shared by every run_outcome. Exported so the
# fixed single-quoted subshell command reads them without any quote juggling.
export BITS='{"ok":true}'
export NUMS='{"sum":3}'
export CHIL='{}'
PAYLOADS="$(printf '["%s"]' "$H")"
export PAYLOADS

# run_outcome <td> <sig> — run tape_outcome in a throwaway subshell: source
# lib/tape.sh, then call tape_outcome with or without the 6th arg (empty
# <sig> = absent/empty, the no-signature path). Capture the subshell's rc in
# $rc and combined stdout in $out.
run_outcome() {
  local td="$1" sig="${2:-}"
  export SIG="$sig"
  rc=0
  out="$(
    TAPE_DIR="$td" RUBRICS_DIR="$RUBRICS_DIR" bash -c '
      source "$REPO_ROOT"/lib/tape.sh
      set +eu
      if [ -n "$SIG" ]; then
        tape_outcome p-1 "$BITS" "$NUMS" "$CHIL" "$PAYLOADS" "$SIG"
      else
        tape_outcome p-1 "$BITS" "$NUMS" "$CHIL" "$PAYLOADS"
      fi
    '
  )" || rc=$?
}

# run_sig <reason> <loop> — run signature_for in a throwaway subshell against
# the hermetic RUBRICS_DIR. Capture stdout in $sig_out and rc in $sig_rc.
# signature_for always exits 0; the subshell rc reflects that.
run_sig() {
  local reason="$1" loop="$2"
  export REASON="$reason" LOOP="$loop"
  sig_rc=0
  sig_out="$(
    RUBRICS_DIR="$RUBRICS_DIR" bash -c '
      source "$REPO_ROOT"/lib/signature.sh
      set +eu
      signature_for "$REASON" "$LOOP"
    '
  )" || sig_rc=$?
}

# last_record <td> — the final line of the tape (or "" if none).
last_record() {
  local td="$1"
  tail -n1 "$td/tape.jsonl" 2>/dev/null || true
}

# ── AC 1: valid signature -> rc 0, record carries "signature" ────────────────

ac_log "AC 1: valid signature (agent-loop) -> rc 0, record has signature"
TD="$TMP_DIR/ac1"
mkdir -p "$TD"
run_outcome "$TD" "agent-loop"
ac_assert_eq "$rc" "0" \
  "valid signature must exit 0 (rc=$rc): $out"
rec="$(last_record "$TD")"
ac_assert_jq '.type == "outcome" and .proposal_id == "p-1"' \
  "$rec" "AC1 record must be an outcome for p-1: $rec"
ac_assert_jq 'has("signature") and .signature == "agent-loop"' \
  "$rec" "valid signature must record signature agent-loop: $rec"
ac_log "AC 1 OK"

# ── AC 2: absent/empty signature -> rc 0, record has NO "signature" key ─────

ac_log "AC 2: absent/empty signature -> rc 0, no signature key"
TD="$TMP_DIR/ac2"
mkdir -p "$TD"
run_outcome "$TD" ""
ac_assert_eq "$rc" "0" \
  "absent signature must exit 0 (rc=$rc): $out"
rec="$(last_record "$TD")"
ac_assert_jq '.type == "outcome" and .proposal_id == "p-1"' \
  "$rec" "AC2 record must be an outcome for p-1: $rec"
ac_assert_jq 'has("signature") | not' \
  "$rec" "absent signature must NOT carry a signature key (pre-#1607 shape): $rec"
ac_log "AC 2 OK"

# ── AC 3: invalid signature -> rc 1, nothing appended ────────────────────────

ac_log "AC 3: invalid signature (uppercase) -> rc 1, nothing appended"
TD="$TMP_DIR/ac3"
mkdir -p "$TD"
run_outcome "$TD" "Agent-loop"
ac_assert_eq "$rc" "1" \
  "invalid signature must be refused (rc=1, got rc=$rc): $out"
if [ -f "$TD/tape.jsonl" ]; then
  ac_fail "invalid signature must append nothing, but a tape line exists: $(tail -n1 "$TD/tape.jsonl" 2>/dev/null)"
fi
ac_log "AC 3 OK"

# ── AC 4: signature_for known reason -> prints mapped signature, rc 0 ───────

ac_log "AC 4: signature_for agent_failed/dev -> agent-loop, rc 0"
run_sig "agent_failed" "dev"
ac_assert_eq "$sig_rc" "0" "signature_for must exit 0 (got $sig_rc)"
ac_assert_eq "$sig_out" "agent-loop" \
  "signature_for(agent_failed, dev) must be agent-loop, got: $sig_out"
ac_log "AC 4 OK"

# ── AC 5: signature_for second known reason -> prints its signature ─────────

ac_log "AC 5: signature_for ci_exhausted_poll/dev -> ci-timeout, rc 0"
run_sig "ci_exhausted_poll" "dev"
ac_assert_eq "$sig_rc" "0" "signature_for must exit 0 (got $sig_rc)"
ac_assert_eq "$sig_out" "ci-timeout" \
  "signature_for(ci_exhausted_poll, dev) must be ci-timeout, got: $sig_out"
ac_log "AC 5 OK"

# ── AC 6: signature_for unknown reason -> empty output, rc 0 ─────────────────

ac_log "AC 6: signature_for unknown reason -> empty, rc 0"
run_sig "not_a_key" "dev"
ac_assert_eq "$sig_rc" "0" "signature_for must exit 0 for unknown reason (got $sig_rc)"
ac_assert_eq "$sig_out" "" \
  "signature_for(unknown reason) must print nothing, got: $sig_out"
ac_log "AC 6 OK"

# ── AC 7: signature_for missing loop -> empty output, rc 0 ───────────────────

ac_log "AC 7: signature_for missing loop -> empty, rc 0"
run_sig "agent_failed" "does-not-exist"
ac_assert_eq "$sig_rc" "0" \
  "signature_for must exit 0 for missing loop (got $sig_rc)"
ac_assert_eq "$sig_out" "" \
  "signature_for(missing loop) must print nothing, got: $sig_out"
ac_log "AC 7 OK"

ac_pass
