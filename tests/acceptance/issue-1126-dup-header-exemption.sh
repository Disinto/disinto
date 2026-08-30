#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1126-dup-header-exemption.sh
#
# Issue #1126: every new acceptance test failed duplicate-detection on the
# mandatory bootstrap header (set -euo pipefail, SCRIPT_DIR=, REPO_ROOT=,
# source acceptance-helpers). The detector now masks the bootstrap header
# lines out of tests/acceptance/*.sh *before* sliding-window hashing, so the
# header never participates in any window, at any window size — including
# the default WINDOW=5 that CI's duplicate-detection job enforces (it runs
# .woodpecker/detect-duplicates.py with no DUP_WINDOW override).
#
# This test runs .woodpecker/detect-duplicates.py (informational mode) at
# window sizes 4 and 5 against fixture files written to a temp dir — no repo
# file is touched or mutated:
#   case 1: two tests carrying only the standard (current-style) header
#           -> not reported
#   case 2: same header plus shared body lines -> the body is reported,
#           while no window starting inside the header is
#   case 3: the same header outside tests/acceptance/ -> reported
#   case 4: two tests carrying only the legacy header (with
#           cd "$REPO_ROOT") -> not reported
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

# write_header <path> — the mandatory standard bootstrap header (4
# meaningful lines; the shebang and shellcheck directives are comments).
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

# write_legacy_header <path> — the legacy bootstrap header (5 meaningful
# lines: adds cd "$REPO_ROOT" before a differently-rooted source line).
write_legacy_header() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"
source "$(dirname "$0")/../lib/acceptance-helpers.sh"
EOF
}

# assert_contains / assert_absent are local on purpose: the shared
# tests/lib/acceptance-helpers.sh has no substring assertions.
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

# run_detector <dir> <window> — informational scan of a fixture tree.
run_detector() {
  (cd "$1" && DUP_WINDOW="$2" python3 "$DETECTOR")
}

# ── Fixtures ─────────────────────────────────────────────────────────────────
mkdir -p "$TMP/t1/tests/acceptance" "$TMP/t2/tests/acceptance" \
  "$TMP/t3/lib" "$TMP/t4/tests/acceptance"

# case 1: standard header only
write_header "$TMP/t1/tests/acceptance/issue-1000-a.sh"
write_header "$TMP/t1/tests/acceptance/issue-1001-b.sh"

# case 2: standard header + 5 shared body lines
for f in issue-1002-c.sh issue-1003-d.sh; do
  write_header "$TMP/t2/tests/acceptance/$f"
  cat >> "$TMP/t2/tests/acceptance/$f" <<'EOF'
BODY_LINE_1="shared-body-1"
BODY_LINE_2="shared-body-2"
BODY_LINE_3="shared-body-3"
BODY_LINE_4="shared-body-4"
BODY_LINE_5="shared-body-5"
EOF
done

# case 3: legacy header outside tests/acceptance/
write_legacy_header "$TMP/t3/lib/aa-header.sh"
write_legacy_header "$TMP/t3/lib/bb-header.sh"

# case 4: legacy header only, inside tests/acceptance/
write_legacy_header "$TMP/t4/tests/acceptance/issue-1004-e.sh"
write_legacy_header "$TMP/t4/tests/acceptance/issue-1005-f.sh"

# ── Checks, at each window size CI may enforce (default is 5) ───────────────
for W in 4 5; do
  # Case 1: standard header only -> exempt
  ac_log "window=$W case 1: two acceptance tests with only the bootstrap header"
  out1="$(run_detector "$TMP/t1" "$W")" || ac_fail "detector exited non-zero (case 1)"
  case "$out1" in
    *"Duplicate code blocks"*)
      ac_fail "case 1: the mandatory bootstrap header is still reported as a duplicate"
      ;;
  esac

  # Case 2: header plus shared body -> body reported, header never involved
  ac_log "window=$W case 2: header plus shared body lines"
  out2="$(run_detector "$TMP/t2" "$W")" || ac_fail "detector exited non-zero (case 2)"
  assert_contains "$out2" "issue-1002-c.sh:8" \
    "case 2: shared body after the header was not reported (issue-1002-c.sh:8 missing)"
  assert_contains "$out2" "issue-1003-d.sh:8" \
    "case 2: shared body after the header was not reported (issue-1003-d.sh:8 missing)"
  for ln in 2 4 5 7; do
    assert_absent "$out2" "issue-1002-c.sh:$ln" \
      "case 2: the bootstrap header still participates in a window (issue-1002-c.sh:$ln reported)"
  done

  # Case 3: same header outside tests/acceptance/ -> reported
  ac_log "window=$W case 3: the same header under lib/ (outside tests/acceptance/)"
  out3="$(run_detector "$TMP/t3" "$W")" || ac_fail "detector exited non-zero (case 3)"
  assert_contains "$out3" "lib/aa-header.sh:2" \
    "case 3: header outside tests/acceptance/ must still be reported (lib/aa-header.sh:2 missing)"
  assert_contains "$out3" "lib/bb-header.sh:2" \
    "case 3: header outside tests/acceptance/ must still be reported (lib/bb-header.sh:2 missing)"

  # Case 4: legacy header only, inside tests/acceptance/ -> exempt
  ac_log "window=$W case 4: two acceptance tests with only the legacy bootstrap header"
  out4="$(run_detector "$TMP/t4" "$W")" || ac_fail "detector exited non-zero (case 4)"
  case "$out4" in
    *"Duplicate code blocks"*)
      ac_fail "case 4: the legacy bootstrap header is still reported as a duplicate"
      ;;
  esac
done

ac_pass
