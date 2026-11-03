#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2067.sh — a merge that changes the healer restarts
# the healer job
#
# Issue #2067: .woodpecker/acceptance-tests.yml fast-forwards /opt/disinto on
# every merge but restarts only the edge, and only when edge paths change.
# The healer is a long-lived raw_exec loop running bin/healer.sh from that
# same checkout (nomad/jobs/healer.hcl); bash loads bin/healer.sh and the
# lib/tape.sh it sources once, at start, so a merged change to either stays
# inert until the job is restarted. detect-changes now writes a
# .ci/needs-healer-restart flag when the merge touched bin/healer.sh or
# lib/tape.sh, and rebuild-and-deploy restarts the healer job under the
# deploy lock, after $OPT has advanced.
#
# Read-only: greps over the repo plus a YAML parse. No live box.
#
# Acceptance: `bash tests/acceptance/issue-2067.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep

WF=".woodpecker/acceptance-tests.yml"
DOC="docs/contributing/acceptance-tests.md"
ac_assert_file "$WF" ".woodpecker/acceptance-tests.yml must exist"
ac_assert_file "$DOC" "docs/contributing/acceptance-tests.md must exist"

# ── 1. The flag is written in detect-changes and read in rebuild-and-deploy ──
ac_log "checking needs-healer-restart appears in both steps"
detect_line="$(grep -nF 'name: detect-changes' "$WF" | head -1 | cut -d: -f1 || true)"
rebuild_line="$(grep -nF 'name: rebuild-and-deploy' "$WF" | head -1 | cut -d: -f1 || true)"
if [ -z "$detect_line" ] || [ -z "$rebuild_line" ]; then
  ac_fail "detect-changes and rebuild-and-deploy step names must exist in $WF"
fi
in_detect="$(grep -nF 'needs-healer-restart' "$WF" | cut -d: -f1 \
  | awk -v d="$detect_line" -v r="$rebuild_line" '$1 > d && $1 < r' | wc -l)"
in_rebuild="$(grep -nF 'needs-healer-restart' "$WF" | cut -d: -f1 \
  | awk -v r="$rebuild_line" '$1 > r' | wc -l)"
if [ "$in_detect" -lt 1 ] || [ "$in_rebuild" -lt 1 ]; then
  ac_fail "needs-healer-restart must appear in both the detect-changes and the rebuild-and-deploy step"
fi

ac_log "checking the healer path pattern names bin/healer.sh and lib/tape.sh"
grep -qF 'bin/healer\.sh|lib/tape\.sh' "$WF" \
  || ac_fail "detect-changes must match the healer paths bin/healer.sh|lib/tape.sh"

# ── 2. The restart line sits between the $OPT echo and the edge-redeploy gate ─
ac_log "checking the healer restart runs after the /opt/disinto fast-forward and before the edge gate"
opt_line="$(grep -nE 'rebuild-and-deploy: [$]OPT at' "$WF" | head -1 | cut -d: -f1 || true)"
restart_line="$(grep -nF 'nomad_api job restart -on-error=fail healer' "$WF" | head -1 | cut -d: -f1 || true)"
no_edge_line="$(grep -nF 'no edge restart' "$WF" | head -1 | cut -d: -f1 || true)"
if [ -z "$opt_line" ] || [ -z "$restart_line" ] || [ -z "$no_edge_line" ]; then
  ac_fail "$WF must contain the $OPT echo, the healer restart, and the no-edge-restart gate"
fi
if [ "$opt_line" -ge "$restart_line" ] || [ "$restart_line" -ge "$no_edge_line" ]; then
  ac_fail "the healer restart (line $restart_line) must come after the $OPT echo (line $opt_line) and before the no-edge-restart gate (line $no_edge_line)"
fi

# ── 3. No dollar-brace form in the healer block (Woodpecker pre-expansion) ───
ac_log "checking the healer block uses no dollar-brace references"
healer_block="$(awk '
  /^[[:space:]]*# The healer loop loads/ { in_block = 1 }
  in_block { print }
  in_block && /^[[:space:]]*fi$/ { exit }
' "$WF")"
[ -n "$healer_block" ] || ac_fail "could not locate the healer restart block in $WF"
if printf '%s\n' "$healer_block" | grep -qE '\$\{'; then
  ac_fail "the healer restart block must use plain references: Woodpecker pre-expands dollar-brace with defaults"
fi

# ── 4. The docs describe the healer restart ──────────────────────────────────
ac_log "checking docs/contributing/acceptance-tests.md names bin/healer.sh and the restart"
grep -qF 'bin/healer.sh' "$DOC" \
  || ac_fail "the docs must name bin/healer.sh in the CI pipeline integration section"
grep -qiE 'restarts the healer' "$DOC" \
  || ac_fail "the docs must describe the healer job restart"

# ── 5. The workflow YAML still parses ────────────────────────────────────────
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
  ac_log "parsing $WF with PyYAML"
  python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$WF" >/dev/null \
    || ac_fail "$WF is not valid YAML"
else
  ac_log "PyYAML or python3 not available, skipping the YAML parse"
fi

# ── 6. The existing tests that read this workflow still pass ──────────────────
ac_log "running tests/acceptance/issue-1799.sh (it greps this workflow too)"
rc=0
out="$(bash "$REPO_ROOT/tests/acceptance/issue-1799.sh" 2>&1)" || rc=$?
last="$(printf '%s\n' "$out" | tail -1)"
if [ "$rc" -ne 0 ] || [ "$last" != "PASS" ]; then
  ac_fail "issue-1799.sh must still pass (rc=$rc): $out"
fi

ac_pass
