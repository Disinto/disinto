#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1126-dup-header-exemption.sh
#
# Issue #1126: every new acceptance test failed duplicate-detection on the
# mandatory bootstrap header (set -euo pipefail, SCRIPT_DIR=, REPO_ROOT=,
# source acceptance-helpers). The detector now exempts a duplicate block when
# all of its files are under tests/acceptance/, the block starts within the
# first 30 lines of each file, and its non-blank lines are only those four
# bootstrap shapes.
#
# This test runs .woodpecker/detect-duplicates.py (informational mode,
# DUP_WINDOW=4 so the 4-line header is a complete window) against fixture
# files written to a temp dir — no repo file is touched or mutated:
#   case 1: two tests carrying only the standard header -> not reported
#   case 2: same header plus one line outside the four shapes -> reported,
#           while the pure-header window stays exempt
#   case 3: the same header outside tests/acceptance/ -> reported
#
# Read-only against the repo: fixtures live in $TMP only.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd python3

DETECTOR="$REPO_ROOT/.woodpecker/detect-duplicates.py"
ac_assert_file "$DETECTOR" "detector .woodpecker/detect-duplicates.py must exist"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# write_header <path> — the mandatory bootstrap header (7 lines).
write_header() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"
EOF
}

assert_contains() {
  case "$1" in
    *"$2"*) return 0 ;;
  esac
  ac_fail "$3"
}

assert_absent() {
  case "$1" in
    *"$2"*) ac_fail "$3" ;;
  esac
}

# run_detector <dir> — informational scan of a fixture tree.
run_detector() {
  (cd "$1" && DUP_WINDOW=4 python3 "$DETECTOR")
}

# ── Case 1: standard header only -> exempt ───────────────────────────────────
ac_log "case 1: two acceptance tests with only the bootstrap header"
mkdir -p "$TMP/t1/tests/acceptance"
write_header "$TMP/t1/tests/acceptance/issue-1000-a.sh"
write_header "$TMP/t1/tests/acceptance/issue-1001-b.sh"
out1="$(run_detector "$TMP/t1")" || ac_fail "detector exited non-zero (case 1)"
case "$out1" in
  *"Duplicate code blocks"*)
    ac_fail "case 1: the mandatory bootstrap header is still reported as a duplicate"
    ;;
esac

# ── Case 2: one non-bootstrap line -> reported, header stays exempt ─────────
ac_log "case 2: header plus a line outside the four bootstrap shapes"
mkdir -p "$TMP/t2/tests/acceptance"
for f in issue-1002-c.sh issue-1003-d.sh; do
  write_header "$TMP/t2/tests/acceptance/$f"
  printf 'EXTRA_SHARED="shared-body-line"\n' >> "$TMP/t2/tests/acceptance/$f"
done
out2="$(run_detector "$TMP/t2")" || ac_fail "detector exited non-zero (case 2)"
assert_contains "$out2" "issue-1002-c.sh:4" \
  "case 2: non-bootstrap line after the header was not reported (issue-1002-c.sh:4 missing)"
assert_contains "$out2" "issue-1003-d.sh:4" \
  "case 2: non-bootstrap line after the header was not reported (issue-1003-d.sh:4 missing)"
assert_absent "$out2" "issue-1002-c.sh:2" \
  "case 2: the pure bootstrap-header window must stay exempt (issue-1002-c.sh:2 reported)"

# ── Case 3: same header outside tests/acceptance/ -> reported ────────────────
ac_log "case 3: the same header under lib/ (outside tests/acceptance/)"
mkdir -p "$TMP/t3/lib"
write_header "$TMP/t3/lib/aa-header.sh"
write_header "$TMP/t3/lib/bb-header.sh"
out3="$(run_detector "$TMP/t3")" || ac_fail "detector exited non-zero (case 3)"
assert_contains "$out3" "lib/aa-header.sh:2" \
  "case 3: header outside tests/acceptance/ must still be reported (lib/aa-header.sh:2 missing)"
assert_contains "$out3" "lib/bb-header.sh:2" \
  "case 3: header outside tests/acceptance/ must still be reported (lib/bb-header.sh:2 missing)"

ac_pass
