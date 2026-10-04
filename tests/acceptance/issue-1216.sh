#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1216.sh
#
# Issue #1216: the backlog scan tests the open PR's own branch for staleness.
#
# pr_head_branch prints the head.ref the forge returns for a PR, or
# fix/issue-ISSUE when that call fails or returns nothing. Both stale-PR
# checks (in-progress and backlog) take BRANCH from it — a retry PR lives on
# fix/issue-N-<attempt>, and the first-attempt name would close the wrong ref.
#
# Acceptance (hermetic — no network, no live services):
#   1. pr_head_branch 42 7 prints the head.ref the API returns for PR 42
#   2. the same call prints fix/issue-7 when curl fails
#   3. both stale-PR checks take BRANCH from pr_head_branch, and no
#      BRANCH="fix/issue-${ISSUE_NUM}" assignment remains
#   4. this test exits 0 and calls ac_pass
#
# Run via `tools/run-acceptance.sh 1216` or `bash tests/acceptance/issue-1216.sh`.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq awk grep python3

TARGET="$REPO_ROOT/dev/dev-poll.sh"
ac_assert_file "$TARGET" "dev/dev-poll.sh must exist"

ac_log "Extracting pr_head_branch from $TARGET"
FN_SRC="$(ac_extract_fn pr_head_branch "$TARGET")"
[ -n "$FN_SRC" ] || ac_fail "could not extract pr_head_branch() from dev/dev-poll.sh"
# shellcheck disable=SC2086
eval "$FN_SRC"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Two hermetic curl stubs (ac_write_curl_stub). The shared stub exits 22 for
# GET /pulls/<n>; the success stub points that arm at a retry head.ref, and
# the failure stub is left to fail (AC_STUB_FAIL).
STUB_OK="$TMP_DIR/ok"
STUB_FAIL="$TMP_DIR/fail"
mkdir -p "$STUB_OK" "$STUB_FAIL"
ac_write_curl_stub "$STUB_OK"
ac_write_curl_stub "$STUB_FAIL"

python3 - "$STUB_OK/curl" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
old = "  *)\n    exit 22\n    ;;\n"
new = (
    "  *)\n"
    "    case \"$url\" in\n"
    "      */pulls/42|*/pulls/42*)\n"
    "        printf '%s\\n' '{\"head\":{\"ref\":\"fix/issue-9999-2\"}}'\n"
    "        ;;\n"
    "      *)\n"
    "        exit 22\n"
    "        ;;\n"
    "    esac\n"
    "    ;;\n"
)
if old not in text:
    raise SystemExit("ac_write_curl_stub catch-all not found")
path.write_text(text.replace(old, new, 1))
PY

export API="https://forge.example/api/v1"
export FORGE_TOKEN="stub-token"

# ── AC1: API returns the retry branch for PR 42 ──────────────────────────────
ac_log "AC1: pr_head_branch 42 7 prints the head.ref the API returns for PR 42"
out="$(PATH="$STUB_OK:$PATH" pr_head_branch 42 7)"
ac_assert_eq "$out" "fix/issue-9999-2" \
  "AC1: expected fix/issue-9999-2, got '${out}'"

# A call that is not for PR 42 must not be treated as that head.
out="$(PATH="$STUB_OK:$PATH" pr_head_branch 43 7)"
ac_assert_eq "$out" "fix/issue-7" \
  "AC1: a failed lookup for a different PR must fall back to fix/issue-7 (got '${out}')"
ac_log "AC1 OK"

# ── AC2: curl failure falls back to fix/issue-ISSUE ──────────────────────────
ac_log "AC2: pr_head_branch 42 7 prints fix/issue-7 when curl fails"
out="$(PATH="$STUB_FAIL:$PATH" AC_STUB_FAIL=1 pr_head_branch 42 7)"
ac_assert_eq "$out" "fix/issue-7" \
  "AC2: a failed API call must print fix/issue-7 (got '${out}')"
ac_log "AC2 OK"

# ── AC3: both stale-PR checks use the helper; the hardcoded name is gone ─────
ac_log "AC3: both stale-PR checks take BRANCH from pr_head_branch"
grep -qF 'BRANCH=$(pr_head_branch "$HAS_PR" "$ISSUE_NUM")' "$TARGET" \
  || ac_fail "in-progress stale-PR check must take BRANCH from pr_head_branch"
grep -qF 'BRANCH=$(pr_head_branch "$EXISTING_PR" "$ISSUE_NUM")' "$TARGET" \
  || ac_fail "backlog stale-PR check must take BRANCH from pr_head_branch"
if grep -qF 'BRANCH="fix/issue-${ISSUE_NUM}"' "$TARGET"; then
  ac_fail "dev/dev-poll.sh must not assign BRANCH=\"fix/issue-\${ISSUE_NUM}\""
fi
ac_log "AC3 OK"

ac_pass
