#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1294.sh
#
# Issue #1294: project TOML kind software|research. lib/load-project.sh must
# export PROJECT_KIND from a top-level `kind` key (default "software" when
# absent, "research" allowed, anything else a load error), and every
# default/example TOML must write `kind = "software"` so new projects and
# the cluster-up seed keep the current software-shaped behaviour.
#
# Verifies (all checks read-only — no forge, no nomad, no repo mutation):
#   1. projects/{disinto,harb,versi}.toml.example each contain
#      `kind = "software"`.
#   2. bin/disinto's generate_default_toml() heredoc writes
#      `kind = "software"`.
#   3. lib/init/nomad/cluster-up.sh's default-disinto.toml seed writes
#      `kind = "software"`.
#   4. Behaviour: loading a TOML with no `kind` exports PROJECT_KIND=software;
#      kind = "research" exports PROJECT_KIND=research; an unknown kind
#      fails the load (non-zero, visible "invalid kind" error) instead of
#      silently defaulting. Behaviour runs in throwaway subshells over
#      mktemp files only.
#
# Run via: tools/run-acceptance.sh 1294
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep mktemp

LIB="$REPO_ROOT/lib/load-project.sh"
ac_assert_file "$LIB" "lib/load-project.sh is missing"

KIND_RE='^[[:space:]]*kind[[:space:]]*=[[:space:]]*"software"'

# ── 1. Example TOMLs write kind = "software" ────────────────────────────────
for f in projects/disinto.toml.example projects/harb.toml.example projects/versi.toml.example; do
  ac_assert_file "$REPO_ROOT/$f" "$f is missing"
  grep -Eq "$KIND_RE" "$REPO_ROOT/$f" \
    || ac_fail "$f does not write kind = \"software\""
done
ac_log "examples: kind = \"software\" present in all three example TOMLs"

# ── 2. generate_default_toml in bin/disinto ─────────────────────────────────
DISINTO_BIN="$REPO_ROOT/bin/disinto"
ac_assert_file "$DISINTO_BIN" "bin/disinto is missing"
FN="$(ac_extract_fn generate_default_toml "$DISINTO_BIN")"
[ -n "$FN" ] || ac_fail "generate_default_toml() not found in bin/disinto"
grep -Eq "$KIND_RE" <<<"$FN" \
  || ac_fail "generate_default_toml() does not write kind = \"software\""
ac_log "bin/disinto: generate_default_toml writes kind = \"software\""

# ── 3. cluster-up.sh default disinto.toml seed ──────────────────────────────
CLUSTER_UP="$REPO_ROOT/lib/init/nomad/cluster-up.sh"
ac_assert_file "$CLUSTER_UP" "lib/init/nomad/cluster-up.sh is missing"
# Only the seeded-heredoc region can match: the seed is the sole TOML literal
# in the file, and its `name = "disinto"` + `kind` lines sit together.
awk '/^name[[:space:]]+=[[:space:]]+"disinto"/{found=1} found' "$CLUSTER_UP" \
  | grep -Eq "$KIND_RE" \
  || ac_fail "cluster-up.sh default disinto.toml seed does not write kind = \"software\""
ac_log "cluster-up.sh: default seed writes kind = \"software\""

# ── 4. Behaviour of lib/load-project.sh ─────────────────────────────────────
TMP_TOML="$(mktemp)"
trap 'rm -f "$TMP_TOML"' EXIT

# run_load — load $TMP_TOML via lib/load-project.sh in a throwaway subshell.
# Captures combined output in LOAD_OUT and the subshell's exit status in
# LOAD_RC without tripping this script's set -e.
run_load() {
  LOAD_RC=0
  LOAD_OUT="$(
    bash -c '
      set -euo pipefail
      unset PROJECT_KIND
      # shellcheck disable=SC1091
      source "$1" "$2"
      printf "KIND=%s" "${PROJECT_KIND:-UNSET}"
    ' _ "$LIB" "$TMP_TOML" 2>&1
  )" || LOAD_RC=$?
  return 0
}

cat > "$TMP_TOML" <<EOF
name      = "accept"
repo      = "owner/accept"
forge_url = "http://localhost:3000"
EOF

run_load
[ "$LOAD_RC" -eq 0 ] \
  || ac_fail "kind absent: load failed (rc=$LOAD_RC): ${LOAD_OUT:0:200}"
ac_assert_eq "$LOAD_OUT" "KIND=software" "kind absent: expected PROJECT_KIND=software, got ${LOAD_OUT}"
ac_log "behaviour: absent kind defaults to software"

cat > "$TMP_TOML" <<EOF
name      = "accept"
repo      = "owner/accept"
forge_url = "http://localhost:3000"
kind      = "research"
EOF

run_load
[ "$LOAD_RC" -eq 0 ] \
  || ac_fail "kind research: load failed (rc=$LOAD_RC): ${LOAD_OUT:0:200}"
ac_assert_eq "$LOAD_OUT" "KIND=research" "kind research: expected PROJECT_KIND=research, got ${LOAD_OUT}"
ac_log "behaviour: kind research exports PROJECT_KIND=research"

cat > "$TMP_TOML" <<EOF
name      = "accept"
repo      = "owner/accept"
forge_url = "http://localhost:3000"
kind      = "resarch"
EOF

run_load
[ "$LOAD_RC" -ne 0 ] \
  || ac_fail "unknown kind: load succeeded (must fail instead of defaulting to software)"
grep -q "invalid kind" <<<"$LOAD_OUT" \
  || ac_fail "unknown kind: load failed without a visible 'invalid kind' error (got: ${LOAD_OUT:0:200})"
ac_log "behaviour: unknown kind fails the load with a visible error"

ac_pass
