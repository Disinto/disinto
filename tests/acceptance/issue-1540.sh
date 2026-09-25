#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1540.sh
#
# Issue #1540: docs(edge): README is the Porter operator page
#
# tools/edge-control/README.md is the Porter operator page. It documents the
# door (not the old tunnel-registrar page and not a curl|bash install), names
# porter-install.sh, the `Match User porter` drop-in, the pinned jev-1.13.0
# model, porter-doctor.sh and the Nomad `edge` job distinction, forbids a
# global AuthorizedKeysCommand, and is capped at 80 lines.
#
# Grep-only, no network, no state mutation:
#   1. README exists and is at most 80 lines.
#   2. It carries the tokens: porter-install.sh, "Match User porter",
#      jev-1.13.0, porter-doctor.sh, Nomad.
#   3. It does NOT contain "curl | bash".
#   4. No line has AuthorizedKeysCommand as its first word (a global
#      AuthorizedKeysCommand is the anti-pattern the page must forbid).
#
# Run via: tools/run-acceptance.sh 1540
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep wc
README="$REPO_ROOT/tools/edge-control/README.md"
ac_assert_file "$README" "tools/edge-control/README.md is missing"

# ── 1. At most 80 lines ──────────────────────────────────────────────────────
LINES="$(wc -l < "$README")"
[ "$LINES" -le 80 ] || ac_fail "README is $LINES lines; the spec caps it at 80"
ac_log "README line count OK: $LINES/80"

# ── 2. Required tokens are present ───────────────────────────────────────────
for token in porter-install.sh "Match User porter" jev-1.13.0 porter-doctor.sh Nomad; do
  grep -qF -- "$token" "$README" \
    || ac_fail "README is missing the required token: $token"
done
ac_log "README carries all required tokens"

# ── 3. No curl | bash install ────────────────────────────────────────────────
if grep -qF -- "curl | bash" "$README"; then
  ac_fail "README still documents a 'curl | bash' install"
fi
ac_log "README documents no 'curl | bash' install"

# ── 4. No line whose first word is AuthorizedKeysCommand (global = forbidden)
# A forbidden line is one that begins (after any whitespace, and an optional
# opening backtick) with the literal token AuthorizedKeysCommand. The regex
# anchors at column 0 so it only flags a *line-start* (global) directive,
# never a mention mid-sentence.
if grep -qE '^[[:space:]]*[`]?AuthorizedKeysCommand' "$README"; then
  ac_fail "README has a line whose first word is AuthorizedKeysCommand (global drop-in is forbidden)"
fi
ac_log "README keeps AuthorizedKeysCommand off every line-start (drop-in only)"

ac_pass
