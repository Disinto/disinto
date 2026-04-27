#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-859.sh — verifies state.json is world-readable (0644)
#
# Issue #859: mktemp produces 0600 files; atomic mv preserves that mode,
# blocking chat-skills (uid 1000) from reading via RO mount.
#
# Checks:
#   1. All five snapshot scripts set chmod 644 on the tmpfile before mv.
#   2. On the live box, /srv/disinto/snapshot-state/state.json is mode 0644.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source "$(dirname "$0")/../lib/acceptance-helpers.sh"

ac_require_cmd jq

# ── 1. Source-code audit: every writer must chmod 644 before mv ──────────────

for script in \
  bin/snapshot-daemon.sh \
  bin/snapshot-nomad.sh \
  bin/snapshot-forge.sh \
  bin/snapshot-agents.sh \
  bin/snapshot-inbox.sh; do

  ac_log "checking $script has chmod 644 before mv"

  # Each script must contain "chmod 644" on a line before "mv -f" within the
  # same function that writes state.json. We verify the pattern exists in the
  # file: a chmod 644 line appears before an mv -f line.
  if ! awk '
    /mv -f.*\$tmpfile.*\$SNAPSHOT_PATH/ { found=1; exit 1 }
    /chmod 644.*\$tmpfile/ { found=1 }
    END { exit (found ? 0 : 1) }
  ' "$REPO_ROOT/$script"; then
    ac_fail "$script: missing 'chmod 644 \$tmpfile' before 'mv -f \$tmpfile'"
  fi
done

# ── 2. Live-box: state.json must be mode 0644 ───────────────────────────────

STATE_FILE="/srv/disinto/snapshot-state/state.json"
if [ -f "$STATE_FILE" ]; then
  ac_log "checking $STATE_FILE permissions"
  mode="$(stat -c '%a' "$STATE_FILE")"
  ac_assert_eq "$mode" "644" \
    "state.json mode is $mode, expected 644 (chat-skills need read access)"
else
  ac_warn "state.json not found at $STATE_FILE — skipping live check"
fi

echo PASS
