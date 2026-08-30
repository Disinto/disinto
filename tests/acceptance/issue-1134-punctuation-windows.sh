#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1134-punctuation-windows.sh
#
# Issue #1134: duplicate-detection reported blocks that consist entirely of
# shell punctuation — the closing arms of a `case` statement — as
# copy-pasted code. The default arm (`;;` / `*)` / `printf ...` / `;;` /
# `esac`) is the only way a default arm can be written, so any two files
# that stub the same API always agree on it.
#
# The detector now reports a sliding window only when it carries at least
# three non-scaffolding lines (scaffolding = ;; esac fi done } ) *) else do
# then). A window that cannot reach three real lines is punctuation, not
# duplication. Window spans and hashes are unchanged, so pre-existing
# findings keep their hashes.
#
# This test runs .woodpecker/detect-duplicates.py (informational mode) at
# the default window against fixture files written to a temp dir — no repo
# file is touched or mutated:
#   case 1: two files sharing only a `case` default arm -> not reported
#   case 2: two files sharing five lines of real logic -> reported
#   case 3: two files sharing three real lines separated by scaffolding
#           -> reported (scaffolding must not let real duplication slip
#           through)
#   case 4: two files sharing a window of two real lines plus scaffolding
#           -> not reported (cannot reach three real lines)
#
# Read-only against the repo: fixtures live in $TMP only.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd python3

DET="$REPO_ROOT/.woodpecker/detect-duplicates.py"
ac_assert_file "$DET" ".woodpecker/detect-duplicates.py must exist"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# assert_contains / assert_absent are local on purpose: the shared
# tests/lib/acceptance-helpers.sh has no substring assertions.
assert_contains() {
  if [[ "$1" != *"$2"* ]]; then
    ac_fail "$3"
  fi
}

assert_absent() {
  if [[ "$1" == *"$2"* ]]; then
    ac_fail "$3"
  fi
}

# run_detector <dir> — informational scan of a fixture tree at the
# default window (no DUP_WINDOW override, the size CI enforces).
run_detector() {
  (cd "$1" && python3 "$DET")
}

# ── Fixtures ─────────────────────────────────────────────────────────────────
mkdir -p "$TMP/t1/lib" "$TMP/t2/lib" "$TMP/t3/lib" "$TMP/t4/lib"

# case 1: only the `case` default arm is shared; every other line differs.
cat > "$TMP/t1/lib/px-case-a.sh" <<'EOF'
#!/usr/bin/env bash
alpha_setup() {
  alpha_seed=1
}
case "$alpha_mode" in
  hit)
    echo alpha_hit
    ;;
  *)
    echo px_default_arm
    ;;
esac
alpha_tail=1
EOF
cat > "$TMP/t1/lib/px-case-b.sh" <<'EOF'
#!/usr/bin/env bash
beta_setup() {
  beta_seed=2
}
case "$beta_mode" in
  hit)
    echo beta_hit
    ;;
  *)
    echo px_default_arm
    ;;
esac
beta_tail=1
EOF

# case 2: five lines of real logic, no scaffolding.
for probe in a b; do
  cat > "$TMP/t2/lib/px-logic-$probe.sh" <<EOF
#!/usr/bin/env bash
px_logic_probe_$probe=1
px_logic_1="logic-one"
px_logic_2="logic-two"
px_logic_3="logic-three"
px_logic_4="logic-four"
px_logic_5="logic-five"
px_logic_tail_$probe=1
EOF
done

# case 3: three real lines separated by scaffolding lines.
for probe in a b; do
  cat > "$TMP/t3/lib/px-punct-$probe.sh" <<EOF
#!/usr/bin/env bash
px_punct_prefix_$probe=1
echo px_punct_one
;;
echo px_punct_two
esac
echo px_punct_three
px_punct_suffix_$probe=1
EOF
done

# case 4: a window that cannot reach three real lines.
for probe in a b; do
  cat > "$TMP/t4/lib/px-thin-$probe.sh" <<EOF
#!/usr/bin/env bash
px_thin_prefix_$probe=1
echo px_thin_one
;;
esac
done
echo px_thin_two
px_thin_suffix_$probe=1
EOF
done

# ── Checks, at the default window (5) ───────────────────────────────────────
# Case 1: only the case default arm is shared -> no finding
ac_log "case 1: two files sharing only a case default arm"
out1="$(run_detector "$TMP/t1")" || ac_fail "detector exited non-zero (case 1)"
assert_absent "$out1" "Duplicate code blocks" \
  "case 1: the case default arm is still reported as a duplicate"

# Case 2: five lines of real logic -> reported
ac_log "case 2: two files sharing five lines of real logic"
out2="$(run_detector "$TMP/t2")" || ac_fail "detector exited non-zero (case 2)"
assert_contains "$out2" "px-logic-a.sh:3" \
  "case 2: shared real logic was not reported (px-logic-a.sh:3 missing)"
assert_contains "$out2" "px-logic-b.sh:3" \
  "case 2: shared real logic was not reported (px-logic-b.sh:3 missing)"

# Case 3: three real lines separated by scaffolding -> still reported
ac_log "case 3: three real lines separated by scaffolding"
out3="$(run_detector "$TMP/t3")" || ac_fail "detector exited non-zero (case 3)"
assert_contains "$out3" "px-punct-a.sh:3" \
  "case 3: real lines separated by scaffolding were not reported (px-punct-a.sh:3 missing)"
assert_contains "$out3" "px-punct-b.sh:3" \
  "case 3: real lines separated by scaffolding were not reported (px-punct-b.sh:3 missing)"

# Case 4: two real lines padded with scaffolding -> no finding
ac_log "case 4: two real lines padded with scaffolding"
out4="$(run_detector "$TMP/t4")" || ac_fail "detector exited non-zero (case 4)"
assert_absent "$out4" "Duplicate code blocks" \
  "case 4: a block that cannot reach three real lines is still reported"

ac_pass
