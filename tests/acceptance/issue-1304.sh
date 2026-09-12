#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1304.sh
#
# Issue #1304: structured RESOURCES.md host blocks (class, ssh, cap).
# lib/resources.sh must parse `### <alias>` host blocks and expose
# resources_hosts / resources_field / resources_pick, where resources_pick
# returns the FIRST alias whose class matches and whose in-flight count is
# below cap (first fit only — no placement policy). The example file must
# contain at least one structured block with class, ssh, and cap. No SSH,
# no network, no live state.
#
# Verifies (hermetic — throwaway inventories in a mktemp dir only):
#   1. lib/resources.sh exists and defines the three public functions.
#   2. RESOURCES.example.md contains a structured host block (class/ssh/cap).
#   3. resources_hosts finds at least one structured host in the example.
#   4. First fit: both free -> first; one at cap -> next; counts align
#      with resources_hosts order across classes; all full -> fail; no
#      matching class -> fail; missing file -> fail.
#
# Run via: tools/run-acceptance.sh 1304
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash awk grep mktemp

# ── 1. The code artifacts exist ──────────────────────────────────────────────
ac_assert_file "$REPO_ROOT/lib/resources.sh" "lib/resources.sh is missing"
for fn in resources_hosts resources_field resources_pick; do
  grep -q "$fn" "$REPO_ROOT/lib/resources.sh" \
    || ac_fail "lib/resources.sh does not define $fn"
done

# ── 2. The example contains a structured host block ──────────────────────────
ac_assert_file "$REPO_ROOT/RESOURCES.example.md" "RESOURCES.example.md is missing"
grep -q '^### ' "$REPO_ROOT/RESOURCES.example.md" \
  || ac_fail "example has no ### host block"
grep -qE '^- class: ' "$REPO_ROOT/RESOURCES.example.md" \
  || ac_fail "example has no '- class:' field"
grep -qE '^- ssh: ' "$REPO_ROOT/RESOURCES.example.md" \
  || ac_fail "example has no '- ssh:' field"
grep -qE '^- cap: ' "$REPO_ROOT/RESOURCES.example.md" \
  || ac_fail "example has no '- cap:' field"

# ── 3. The library parses the example ────────────────────────────────────────
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/resources.sh"
hosts="$(resources_hosts "$REPO_ROOT/RESOURCES.example.md")" \
  || ac_fail "resources_hosts failed on RESOURCES.example.md"
[ -n "$hosts" ] || ac_fail "resources_hosts found no structured host in the example"

# ── 4. First fit on a throwaway inventory ────────────────────────────────────
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
F="$TMP_DIR/RESOURCES.md"
cat > "$F" <<'EOF'
## Compute

### box-a
- class: cpu
- ssh: dev@a.example.com
- cap: 1

### box-b
- class: cpu
- ssh: dev@b.example.com
- cap: 1

### box-g
- class: gpu
- ssh: dev@g.example.com
- cap: 1
EOF

ac_log "first fit: both cpu hosts free -> the first one"
ac_assert_eq "$(resources_pick "$F" cpu)" "box-a" \
  "resources_pick did not return the first free cpu host"

ac_log "first fit: one host at cap -> the next free host"
ac_assert_eq "$(resources_pick "$F" cpu "1 0")" "box-b" \
  "resources_pick did not skip the full host"

ac_log "counts align with resources_hosts order across classes (box-g is slot 3, not slot 1)"
ac_assert_eq "$(resources_pick "$F" gpu "0 0 0")" "box-g" \
  "resources_pick did not free-pick the gpu host from its own slot"
rc=0; resources_pick "$F" gpu "0 0 1" || rc=$?
[ "$rc" -ne 0 ] \
  || ac_fail "resources_pick read the wrong count slot for a cross-class host"

ac_log "no placement beyond first fit: all full / no class / missing file -> non-zero"
rc=0; resources_pick "$F" cpu "1 1" || rc=$?
[ "$rc" -ne 0 ] || ac_fail "pick succeeded with both cpu hosts at cap"
rc=0; resources_pick "$F" meep || rc=$?
[ "$rc" -ne 0 ] || ac_fail "pick succeeded with no matching class"
rc=0; resources_hosts "$TMP_DIR/absent.md" || rc=$?
[ "$rc" -ne 0 ] || ac_fail "resources_hosts succeeded on a missing file"

ac_pass
