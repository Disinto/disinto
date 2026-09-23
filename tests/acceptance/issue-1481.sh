#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1481.sh
#
# Issue #1481: chore(tape): remove unread pack and rubric stubs.
#
# tape/packs/dev.toml and tape/rubrics/failure-signature.toml said "nothing
# reads them, and nothing does." No outcome carries `signature`, and
# docs/AGENTS.md still presented them as the live context pack and the live
# failure-signature rubric. They were stubs pretending to be schema:
#   - nothing in the tree reads either path
#   - no outcome record writes a `signature` field
#   - the docs presented the rubric as in force
#
# Fix: delete both files; rewrite the `tape/` entry in docs/AGENTS.md so it
# no longer claims a context pack or failure-signature rubric is in force.
# No writer is added and `signature` is not written to any outcome.
# Packs and rubrics come back when an extractor lands (#1400 deferred).
#
# Acceptance (read-only — no live services, no agents started; the two
# paths and the docs entry are checked from the repo):
#   1. tape/packs/dev.toml is absent
#   2. tape/rubrics/failure-signature.toml is absent
#   3. no *.sh or *.toml source references either path
#   4. docs/AGENTS.md does not claim a failure-signature rubric or context
#      pack is in force (and still documents the tape/ dir, #1481)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep

PACK="$REPO_ROOT/tape/packs/dev.toml"
RUBRIC="$REPO_ROOT/tape/rubrics/failure-signature.toml"
DOCS="$REPO_ROOT/docs/AGENTS.md"

# ── 1. tape/packs/dev.toml is absent ─────────────────────────────────────────

if [ -e "$PACK" ]; then
  ac_fail "tape/packs/dev.toml must be deleted (#1481)"
fi
ac_log "AC 1 OK: tape/packs/dev.toml absent"

# ── 2. tape/rubrics/failure-signature.toml is absent ─────────────────────────

if [ -e "$RUBRIC" ]; then
  ac_fail "tape/rubrics/failure-signature.toml must be deleted (#1481)"
fi
ac_log "AC 2 OK: tape/rubrics/failure-signature.toml absent"

# ── 3. no *.sh or *.toml source references either path ───────────────────────

if git -C "$REPO_ROOT" ls-files '*.sh' '*.toml' 2>/dev/null |
   xargs -r grep -lF -- 'tape/packs/dev.toml\|tape/rubrics/failure-signature.toml' "$REPO_ROOT/" 2>/dev/null | grep -q .; then
  ac_fail "a *.sh or *.toml source still references tape/packs/dev.toml or tape/rubrics/failure-signature.toml (#1481)"
fi
ac_log "AC 3 OK: no *.sh or *.toml source references either stub path"

# ── 4. docs/AGENTS.md no longer claims the rubric/pack is in force ──────────

ac_assert_file "$DOCS" "docs/AGENTS.md must exist"

# The old claims: the failure-signature rubric as the in-force rubric, and
# the context pack as the proposal context fields. Neither may remain.
if grep -qF 'failure-signature labels' "$DOCS" \
   || grep -qF 'proposal context fields' "$DOCS"; then
  ac_fail "docs/AGENTS.md still presents the failure-signature rubric or the context pack as the live schema (#1481)"
fi
if grep -qF 'documentation-by-schema, nothing reads these yet' "$DOCS"; then
  ac_fail "docs/AGENTS.md still carries the 'nothing reads these yet' stub claim (#1481)"
fi
# The tape/ entry must still exist — the dir is real; only the stub files
# are gone — and must note the removal (#1481). The entry is a top-level
# tree item: box, vertical-bar, " tape/" (no leading whitespace).
if ! grep -qF 'tape/' "$DOCS"; then
  ac_fail "docs/AGENTS.md must still document the tape/ directory (#1481)"
fi
if ! grep -qF '#1481' "$DOCS"; then
  ac_fail "docs/AGENTS.md must reference #1481 for the tape/ entry removal"
fi
ac_log "AC 4 OK: docs/AGENTS.md does not claim a failure-signature rubric is in force"

echo PASS
