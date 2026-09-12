#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1296.sh
#
# Issue #1296: vault action fields image, host, artifacts, resource_class.
# The vault-action allowlist in action-vault/vault-env.sh must accept four
# new OPTIONAL top-level fields — image (string), host (string),
# artifacts (string or array of strings), resource_class
# (cpu|gpu|meep|voxel) — while still rejecting unknown fields and invalid
# resource_class values. SCHEMA.md must document all four fields and the
# action-vault/examples/ path.
#
# Verifies (all checks read-only — temp TOMLs in mktemp dirs only, no forge,
# no nomad, no repo mutation):
#   1. action-vault/examples/run-experiment.toml is VALID under
#      action-vault/validate.sh and carries all four new fields.
#   2. A TOML with all four new fields validates.
#   3. A TOML without any of them still validates (they are optional).
#   4. A TOML with an extra unknown field still fails.
#   5. resource_class = "banana" fails with a visible resource_class error
#      (and "banana" is not silently accepted).
#   6. SCHEMA.md lists the four fields and the action-vault/examples/ path.
#
# Run via: tools/run-acceptance.sh 1296
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep mktemp

# lib/env.sh (sourced via vault-env.sh by validate.sh) requires USER/HOME
export USER="${USER:-$(id -un)}"
export HOME="${HOME:-/root}"

VALIDATE="$REPO_ROOT/action-vault/validate.sh"
ac_assert_file "$VALIDATE" "action-vault/validate.sh is missing"

# run_validate <toml-path> — run validate.sh in the current shell, capture
# combined output in V_OUT and the exit status in V_RC without tripping
# this script's set -e.
run_validate() {
  local f="$1"
  V_RC=0
  V_OUT="$(bash "$VALIDATE" "$f" 2>&1)" || V_RC=$?
  return 0
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

BASE_TOML() { # $1 = extra-fields block (may be empty)
  cat > "$TMP_DIR/vault-action.toml" <<EOF
id = "run-experiment-1296"
formula = "release"
context = "Acceptance test for issue #1296"
secrets = []
$1
EOF
}

# ── 1. Example run-experiment.toml is VALID under validate.sh ───────────────
EXAMPLE="$REPO_ROOT/action-vault/examples/run-experiment.toml"
ac_assert_file "$EXAMPLE" "action-vault/examples/run-experiment.toml is missing"
for f in image host artifacts resource_class; do
  grep -qE "^[[:space:]]*${f}[[:space:]]*=" "$EXAMPLE" \
    || ac_fail "run-experiment.toml does not set $f"
done
run_validate "$EXAMPLE"
[ "$V_RC" -eq 0 ] \
  || ac_fail "run-experiment.toml is not VALID: ${V_OUT:0:300}"
grep -q "VALID:" <<<"$V_OUT" \
  || ac_fail "validate.sh did not report VALID for run-experiment.toml"
ac_log "example: run-experiment.toml is VALID under action-vault/validate.sh"

# ── 2. TOML with all four new fields validates ──────────────────────────────
BASE_TOML '
image = "disinto/agents"
host = "nomad-box-1"
artifacts = ["results/*.csv", "evidence/summary.md"]
resource_class = "gpu"
'
run_validate "$TMP_DIR/vault-action.toml"
[ "$V_RC" -eq 0 ] \
  || ac_fail "all four fields present: validation failed: ${V_OUT:0:300}"
ac_log "fields: all four new fields validate (array artifacts)"

# artifacts also accepts a plain string
BASE_TOML '
artifacts = "results/*.csv"
resource_class = "meep"
'
run_validate "$TMP_DIR/vault-action.toml"
[ "$V_RC" -eq 0 ] \
  || ac_fail "string artifacts: validation failed: ${V_OUT:0:300}"
ac_log "fields: string-form artifacts and resource_class=meep validate"

# ── 3. TOML without any of the new fields still validates ───────────────────
BASE_TOML ''
run_validate "$TMP_DIR/vault-action.toml"
[ "$V_RC" -eq 0 ] \
  || ac_fail "fields absent: validation failed (must stay optional): ${V_OUT:0:300}"
ac_log "optional: a TOML without the new fields still validates"

# ── 4. Unknown field still fails ────────────────────────────────────────────
BASE_TOML '
bogus_field = "x"
'
run_validate "$TMP_DIR/vault-action.toml"
[ "$V_RC" -ne 0 ] || ac_fail "unknown field: validation succeeded (must fail)"
grep -q "Unknown fields" <<<"$V_OUT" \
  || ac_fail "unknown field: validation failed without an 'Unknown fields' error (got: ${V_OUT:0:300})"
ac_log "unknown field: still rejected with an 'Unknown fields' error"

# ── 5. resource_class = "banana" fails ──────────────────────────────────────
BASE_TOML '
resource_class = "banana"
'
run_validate "$TMP_DIR/vault-action.toml"
[ "$V_RC" -ne 0 ] || ac_fail "resource_class=banana: validation succeeded (must fail)"
grep -q "resource_class" <<<"$V_OUT" \
  || ac_fail "resource_class=banana: validation failed without a visible resource_class error (got: ${V_OUT:0:300})"
ac_log "resource_class: 'banana' is rejected with a visible resource_class error"

# ── 6. SCHEMA.md documents the four fields and the examples path ────────────
SCHEMA="$REPO_ROOT/action-vault/SCHEMA.md"
ac_assert_file "$SCHEMA" "action-vault/SCHEMA.md is missing"
for f in image host artifacts resource_class; do
  grep -qE "^\|[[:space:]]*\`${f}\`[[:space:]]*\|" "$SCHEMA" \
    || ac_fail "SCHEMA.md optional-fields table does not list $f"
done
grep -q "action-vault/examples/" "$SCHEMA" \
  || ac_fail "SCHEMA.md does not reference action-vault/examples/"
grep -q 'voxel' "$SCHEMA" \
  || ac_fail "SCHEMA.md does not document resource_class values (cpu | gpu | meep | voxel)"
ac_log "SCHEMA.md: all four fields listed, action-vault/examples/ referenced"

ac_pass
