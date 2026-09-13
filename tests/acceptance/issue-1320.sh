#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1320.sh
#
# Issue #1320: llama slot lease parser in lib/resources.sh. AD-002: llama
# server concurrency is a shared KV pool (--kv-unified), so the `## llama`
# section of RESOURCES.md is the machine-readable lease of its slots:
#   - resources_llama_slots <file> — the integer slots count (rc 1 if no
#     `## llama` section)
#   - resources_llama_held <file>  — sum of the trailing holder counts
#     (0 if none)
#   - resources_llama_free <file>  — slots minus held (rc 1 if no section)
# A non-integer count is a hard error; a file without `## llama` must not
# break resources_pick. No SSH, no HTTP, no writes.
#
# Verifies (hermetic — throwaway inventories in a mktemp dir only):
#   1. lib/resources.sh exists and defines the three functions.
#   2. RESOURCES.example.md carries a `## llama` section and its
#      resources_llama_free equals slots minus held.
#   3. A fixture with no `## llama` section: resources_llama_slots exits 1
#      and resources_pick still works.
#   4. A holder line with a non-integer count is a hard error (non-zero
#      exit, no stdout) for all three functions.
#   5. tests/lib-resources.bats exists and covers the three functions.
#
# Run via: tools/run-acceptance.sh 1320
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash awk grep mktemp

# ── 1. The code artifacts exist ──────────────────────────────────────────────
ac_assert_file "$REPO_ROOT/lib/resources.sh" "lib/resources.sh is missing"
for fn in resources_llama_slots resources_llama_held resources_llama_free; do
  grep -q "$fn()" "$REPO_ROOT/lib/resources.sh" \
    || ac_fail "lib/resources.sh does not define $fn"
done

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/resources.sh"

# ── 2. The example file carries a valid lease ────────────────────────────────
ac_log "example file: free equals slots minus held"
EXAMPLE="$REPO_ROOT/RESOURCES.example.md"
ac_assert_file "$EXAMPLE" "RESOURCES.example.md is missing"
slots="$(resources_llama_slots "$EXAMPLE")" \
  || ac_fail "resources_llama_slots failed on RESOURCES.example.md"
held="$(resources_llama_held "$EXAMPLE")" \
  || ac_fail "resources_llama_held failed on RESOURCES.example.md"
free="$(resources_llama_free "$EXAMPLE")" \
  || ac_fail "resources_llama_free failed on RESOURCES.example.md"
ac_assert_eq "$free" "$((slots - held))" \
  "resources_llama_free ($free) != slots - held ($slots - $held)"
# The committed example is exactly: slots 4, nomad-box 2, selenocyte-box 1.
ac_assert_eq "$slots" "4" "example slots is not 4"
ac_assert_eq "$held" "3" "example held is not 3"
ac_assert_eq "$free" "1" "example free is not 1"

# ── 3. No `## llama` section: slots exits 1, pick still works ────────────────
ac_log "no '## llama' section: slots exits 1, pick still works"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
F="$TMP_DIR/RESOURCES.md"
cat > "$F" <<'EOF'
## Compute

### box-a
- class: cpu
- ssh: dev@a.example.com
- cap: 1
EOF
rc=0; resources_llama_slots "$F" || rc=$?
[ "$rc" -eq 1 ] || ac_fail "resources_llama_slots exited $rc (expected 1) without a '## llama' section"
rc=0; resources_llama_free "$F" || rc=$?
[ "$rc" -eq 1 ] || ac_fail "resources_llama_free exited $rc (expected 1) without a '## llama' section"
ac_assert_eq "$(resources_llama_held "$F")" "0" \
  "resources_llama_held on a file without '## llama' is not 0"
ac_assert_eq "$(resources_pick "$F" cpu)" "box-a" \
  "resources_pick broke on a file without a '## llama' section"

# ── 4. A non-integer holder count is a hard error ────────────────────────────
ac_log "non-integer holder count: hard error for all three functions"
G="$TMP_DIR/bad.md"
cat > "$G" <<'EOF'
## llama
- slots: 4
- holder: nomad-box two
EOF
for fn in resources_llama_slots resources_llama_held resources_llama_free; do
  rc=0
  out="$($fn "$G" 2>/dev/null)" || rc=$?
  [ "$rc" -ne 0 ] || ac_fail "$fn succeeded on a non-integer holder count"
  [ -z "$out" ] || ac_fail "$fn printed '$out' on a non-integer holder count"
done

# ── 5. The bats suite covers the three functions ────────────────────────────
ac_log "tests/lib-resources.bats covers the llama functions"
BATS_FILE="$REPO_ROOT/tests/lib-resources.bats"
ac_assert_file "$BATS_FILE" "tests/lib-resources.bats is missing"
for fn in resources_llama_slots resources_llama_held resources_llama_free; do
  grep -q "$fn" "$BATS_FILE" || ac_fail "tests/lib-resources.bats does not cover $fn"
done

ac_pass
