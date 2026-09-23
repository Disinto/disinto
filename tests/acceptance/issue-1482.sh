#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1482.sh
#
# Issue #1482: fix(release): do not push release tags to codeberg.org.
#
# The old release.sh (formulas/release.sh) tagged Forgejo main in step 2,
# then in step 3 POSTed the *same* tag to the disinto-admin repo on
# codeberg.org (a wrong-host push: Forgejo is the publisher, not a mirror
# that should receive the tag). The GitHub mirror push in the same block was
# correct and must remain.
#
# Fix: delete the CODEBERG_TOKEN push block. Leave step 2 (Forgejo tag) and
# the GitHub mirror block untouched. Do not add a new remote.
#
# Acceptance (read-only — no live services, no curl; the release.sh file is
# grepped from the repo):
#   1. formulas/release.sh contains no codeberg.org URL
#   2. formulas/release.sh still POSTs the tag to
#      ${FORGE_URL}/api/v1/repos/${FORGE_REPO}/tags
#   3. The GitHub mirror block (api.github.com POST) remains
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep

RELEASE_SH="$REPO_ROOT/formulas/release.sh"

# ── 1. formulas/release.sh contains no codeberg.org URL ────────────────────

ac_assert_file "$RELEASE_SH" "formulas/release.sh must exist"
if grep -q 'codeberg\.org' "$RELEASE_SH"; then
  ac_fail "formulas/release.sh still contains a codeberg.org URL (#1482)"
fi
ac_log "AC 1 OK: formulas/release.sh has no codeberg.org URL"

# ── 2. forge tag POST to ${FORGE_URL}/api/v1/repos/${FORGE_REPO}/tags ───────

# The tag creation block is a multi-line curl: the POST verb, the URL, and the
# tag_name JSON payload are on separate lines. The URL in the file is a
# literal shell-variable reference (${FORGE_URL}/api/v1/repos/${FORGE_REPO}/tags),
# not an expanded real URL, so we grep for the literal pieces (the preflight
# GET appends /<RELEASE_VERSION>/ to the same prefix, so the bare /tags line +
# tag_name payload pin the POST, not the GET).
# shellcheck disable=SC2016  # literal shell variable references, not expansion
if ! grep -qF -- '${FORGE_URL}/api/v1/repos/${FORGE_REPO}/tags' "$RELEASE_SH"; then
  ac_fail "formulas/release.sh must still POST the tag to ${FORGE_URL}/api/v1/repos/${FORGE_REPO}/tags (#1482)"
fi
if ! grep -q 'tag_name' "$RELEASE_SH"; then
  ac_fail "formulas/release.sh must still POST tag_name in the tag-creation payload (#1482)"
fi
ac_log "AC 2 OK: tag POST to ${FORGE_URL}/api/v1/repos/${FORGE_REPO}/tags present"

# ── 3. GitHub mirror block remains ───────────────────────────────────────────

if grep -q 'api.github.com' "$RELEASE_SH"; then
  ac_log "AC 3 OK: GitHub mirror block remains"
else
  ac_fail "the GitHub mirror block (api.github.com) must remain (#1482)"
fi

ac_pass
