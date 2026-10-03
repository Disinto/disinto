#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1686.sh
#
# Issue #1686: tests/lib-agent-metrics.bats stubs the Claude path
# (claude_run_with_watchdog) and calls agent_run, but never set
# AGENT_HARNESS. Unset, agent_run takes the Claude path and hits the stub.
# AGENT_HARNESS=dsh (the dev-agent container, and CI once dsh is the default)
# runs the real dsh — real sessions, and a missing binary. setup() must pin
# AGENT_HARNESS=claude before sourcing lib/agent-sdk.sh.
#
# Acceptance (no network; a fake dsh in a temp bin dir; temp DSH_HOME):
#   1. With that fake dsh first on PATH (it creates a marker file) and
#      AGENT_HARNESS=dsh, bats tests/lib-agent-metrics.bats passes and the
#      marker does not exist.
#   2. With AGENT_HARNESS unset, bats tests/lib-agent-metrics.bats passes.
#   3. this test exits 0 and calls ac_pass.
#
# Run via: tools/run-acceptance.sh 1686
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash bats jq git

SUITE="$REPO_ROOT/tests/lib-agent-metrics.bats"
ac_assert_file "$SUITE" "tests/lib-agent-metrics.bats must exist"

# The pin lives in setup(), before agent-sdk.sh is sourced — a later export
# would still dispatch correctly, but the issue's contract is this placement.
awk '
  /^setup\(\)/ { in_setup = 1 }
  in_setup && /export AGENT_HARNESS=claude/ { pinned = 1 }
  in_setup && /source "\$REPO_ROOT\/lib\/agent-sdk.sh"/ {
    if (pinned) { found = 1; exit 0 }
    exit 1
  }
  END { if (!found) exit 1 }
' "$SUITE" \
  || ac_fail "setup() must export AGENT_HARNESS=claude before sourcing lib/agent-sdk.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

BIN_DIR="$TMP_DIR/bin"
MARKER="$TMP_DIR/dsh-invoked"
mkdir -p "$BIN_DIR" "$TMP_DIR/dsh-home"

# Any invocation means agent_run took the dsh path. The absolute marker path
# is baked in so a test that unsets the environment still leaves proof.
cat > "$BIN_DIR/dsh" <<EOF
#!/usr/bin/env bash
touch "$MARKER"
exit 0
EOF
chmod +x "$BIN_DIR/dsh"

# Inherited by both bats runs: fake dsh first, and a temp home so a missed
# pin cannot write into the agent's real DSH_HOME.
export PATH="$BIN_DIR:$PATH"
export DSH_HOME="$TMP_DIR/dsh-home"

# ── 1. AGENT_HARNESS=dsh must still hit the Claude stub, never the fake dsh ─
ac_log "AC 1: AGENT_HARNESS=dsh bats tests/lib-agent-metrics.bats passes; fake dsh is not run"
rm -f "$MARKER"
bats_rc=0
bats_out="$(AGENT_HARNESS=dsh bats "$SUITE" 2>&1)" || bats_rc=$?
ac_assert_eq "$bats_rc" "0" \
  "AGENT_HARNESS=dsh bats tests/lib-agent-metrics.bats must pass (rc=$bats_rc): $bats_out"
if [ -e "$MARKER" ]; then
  ac_fail "fake dsh was invoked under AGENT_HARNESS=dsh; the suite must pin the Claude harness"
fi
ac_log "AC 1 OK: suite passed and the dsh marker does not exist"

# ── 2. AGENT_HARNESS unset still passes (CI's environment today) ─────────────
ac_log "AC 2: AGENT_HARNESS unset, bats tests/lib-agent-metrics.bats passes"
rm -f "$MARKER"
bats_rc=0
# Command substitution is a subshell, so unset does not leak to this script.
bats_out="$(unset AGENT_HARNESS; bats "$SUITE" 2>&1)" || bats_rc=$?
ac_assert_eq "$bats_rc" "0" \
  "AGENT_HARNESS unset: bats tests/lib-agent-metrics.bats must pass (rc=$bats_rc): $bats_out"
if [ -e "$MARKER" ]; then
  ac_fail "fake dsh was invoked with AGENT_HARNESS unset"
fi
ac_log "AC 2 OK: suite passed with AGENT_HARNESS unset"

ac_pass
