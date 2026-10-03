#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1640.sh
#
# Issue #1640: read claim files from the ops repo.
#
# The factory's world model is claims: one TOML file per claim,
# `claims/<id>.toml`. lib/claims.sh (no callers yet) reads them. A claim's
# status (provisional, held, challenged) lives on the tape, never in the file.
#
# Functions (sourced; no callers yet):
#   claim_ids
#     -> ids in ${CLAIMS_DIR:-${OPS_REPO_ROOT}/claims}, sorted, one per line.
#        Only `*.toml` names matching ^[a-z][a-z0-9-]*$.
#   claim_field ID KEY
#     -> value of KEY via python3 tomllib. An array prints its items
#        space-separated. Missing file or key: nothing, rc 0. A file that
#        does not parse: nothing, rc 1.
#   claim_valid ID
#     -> rc 0 when statement is non-empty, class is deploy|experiment|internal,
#        check starts with probes/ and holds no `..`, sprint_expect_met 0
#        "<expect>" does not return 2, and sprint_duration_seconds "<window>"
#        prints more than 0. Otherwise one stderr line naming the first bad
#        field, rc 1.
#
# Hermetic: no network, no forge, no agent — a temp CLAIMS_DIR with fixture
# files, the lib sourced in a throwaway subshell (same pattern as
# issue-1629.sh).
#
# Acceptance: `bash tests/acceptance/issue-1640.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash python3
ac_assert_file "$REPO_ROOT/lib/claims.sh" "lib/claims.sh is missing"
ac_assert_file "$REPO_ROOT/lib/sprint-block.sh" "lib/sprint-block.sh is missing"
ac_assert_file "$REPO_ROOT/lib/AGENTS.md" "lib/AGENTS.md is missing"

# The review (formula 3b) requires the claims row in the same change.
grep -qF 'lib/claims.sh' "$REPO_ROOT/lib/AGENTS.md" \
  || ac_fail "lib/AGENTS.md must document lib/claims.sh"
grep -qF 'provisional, held, challenged' "$REPO_ROOT/lib/AGENTS.md" \
  || ac_fail "lib/AGENTS.md must say claim status lives on the tape"
grep -qF 'sprint-block.sh' "$REPO_ROOT/lib/claims.sh" \
  || ac_fail "lib/claims.sh must source lib/sprint-block.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CLAIMS_DIR="$TMP_DIR/claims"
mkdir -p "$CLAIMS_DIR"

# The example from the issue, as claims/dev-comes-back.toml.
cat >"$CLAIMS_DIR/dev-comes-back.toml" <<'EOF'
statement = "a dev proposal comes back, merged or rejected, within 48 hours"
class     = "internal"                  # deploy | experiment | internal
check     = "probes/dev-unreturned.sh"  # prints one number
expect    = "<= 0.2"                    # as a sprint block's expect
window    = "7d"                        # as a sprint block's soak
rests_on  = []                          # claim ids
EOF

# A name that does not match ^[a-z][a-z0-9-]*$ must not be listed.
cat >"$CLAIMS_DIR/Bad_Name.toml" <<'EOF'
statement = "not a claim id"
class = "internal"
check = "probes/nope.sh"
expect = "<= 0.2"
window = "7d"
rests_on = []
EOF

# run_claims <func> <args...> — source lib/claims.sh in a throwaway subshell
# with CLAIMS_DIR set and call <func>. stdout -> $OUT, stderr -> $ERR,
# exit status -> $RC.
run_claims() {
  local fn="$1"; shift
  RC=0 OUT="" ERR=""
  (
    export CLAIMS_DIR
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/claims.sh"
    "$fn" "$@"
  ) >"$TMP_DIR/out" 2>"$TMP_DIR/err" || RC=$?
  OUT="$(cat "$TMP_DIR/out" 2>/dev/null || true)"
  ERR="$(cat "$TMP_DIR/err" 2>/dev/null || true)"
}

# ── AC1: claim_ids lists the example; claim_field reads expect ───────────────
ac_log "AC1: claim_ids prints dev-comes-back; claim_field reads expect"
run_claims claim_ids
ac_assert_eq "$OUT" "dev-comes-back" \
  "claim_ids must print 'dev-comes-back' (got '$OUT') [stderr: $ERR]"
[ -z "$ERR" ] || ac_fail "claim_ids must not print stderr (got: $ERR)"
ac_assert_eq "$RC" "0" "claim_ids must return 0 (rc=$RC)"
run_claims claim_field dev-comes-back expect
ac_assert_eq "$OUT" "<= 0.2" \
  "claim_field expect must print '<= 0.2' (got '$OUT') [stderr: $ERR]"
[ -z "$ERR" ] || ac_fail "claim_field expect must not print stderr (got: $ERR)"
ac_assert_eq "$RC" "0" "claim_field expect must return 0 (rc=$RC)"

# ── AC2: missing key is quiet; an array prints space-separated ───────────────
ac_log "AC2: missing key prints nothing; rests_on array prints 'a b'"
run_claims claim_field dev-comes-back nope
ac_assert_eq "$OUT" "" \
  "missing key must print nothing (got '$OUT')"
ac_assert_eq "$RC" "0" "missing key must return 0 (rc=$RC)"
[ -z "$ERR" ] || ac_fail "missing key must not print stderr (got: $ERR)"

cat >"$CLAIMS_DIR/rests-on.toml" <<'EOF'
statement = "a claim that names what it rests on"
class = "deploy"
check = "probes/rests.sh"
expect = ">= 1"
window = "48h"
rests_on = ["a", "b"]
EOF
run_claims claim_field rests-on rests_on
ac_assert_eq "$OUT" "a b" \
  "rests_on = [\"a\", \"b\"] must print 'a b' (got '$OUT')"
ac_assert_eq "$RC" "0" "claim_field rests_on must return 0 (rc=$RC)"

# ── AC3: claim_valid accepts the example, rejects a path escape and a bad window
ac_log "AC3: claim_valid example / bad check / bad window"
run_claims claim_valid dev-comes-back
ac_assert_eq "$RC" "0" \
  "claim_valid must return 0 for the example (rc=$RC) [stderr: $ERR]"
[ -z "$OUT" ] || ac_fail "claim_valid must print nothing on success (got '$OUT')"
[ -z "$ERR" ] || ac_fail "claim_valid must not print stderr on success (got: $ERR)"

cat >"$CLAIMS_DIR/bad-check.toml" <<'EOF'
statement = "a check that escapes the probes directory"
class = "experiment"
check = "../x.sh"
expect = "<= 0.2"
window = "7d"
rests_on = []
EOF
run_claims claim_valid bad-check
ac_assert_eq "$RC" "1" \
  "claim_valid must return 1 for check = \"../x.sh\" (rc=$RC)"
ac_assert_eq "$ERR" "bad field: check" \
  "claim_valid must name the check field (got '$ERR')"

cat >"$CLAIMS_DIR/bad-window.toml" <<'EOF'
statement = "a window that is not a duration"
class = "internal"
check = "probes/dev-unreturned.sh"
expect = "<= 0.2"
window = "soon"
rests_on = []
EOF
run_claims claim_valid bad-window
ac_assert_eq "$RC" "1" \
  "claim_valid must return 1 for window = \"soon\" (rc=$RC)"
ac_assert_eq "$ERR" "bad field: window" \
  "claim_valid must name the window field (got '$ERR')"

# ── AC4: Bad_Name.toml is not listed (re-checked after later fixtures) ───────
ac_log "AC4: Bad_Name.toml is not listed"
run_claims claim_ids
case "
$OUT
" in
  *"
Bad_Name
"*) ac_fail "claim_ids must not list Bad_Name (got '$OUT')" ;;
esac
printf '%s\n' "$OUT" | grep -qx 'dev-comes-back' \
  || ac_fail "claim_ids must still list dev-comes-back (got '$OUT')"

# A file that does not parse: nothing, rc 1. A missing file: nothing, rc 0.
printf 'statement = [\n' >"$CLAIMS_DIR/broken.toml"
run_claims claim_field broken statement
ac_assert_eq "$OUT" "" "unparseable file must print nothing (got '$OUT')"
ac_assert_eq "$RC" "1" "unparseable file must return 1 (rc=$RC)"
run_claims claim_field missing-claim statement
ac_assert_eq "$OUT" "" "missing file must print nothing (got '$OUT')"
ac_assert_eq "$RC" "0" "missing file must return 0 (rc=$RC)"

# Default dir is ${OPS_REPO_ROOT}/claims when CLAIMS_DIR is unset.
OPS_ROOT="$TMP_DIR/ops"
mkdir -p "$OPS_ROOT/claims"
cp "$CLAIMS_DIR/dev-comes-back.toml" "$OPS_ROOT/claims/dev-comes-back.toml"
RC=0 OUT="" ERR=""
(
  unset CLAIMS_DIR
  export OPS_REPO_ROOT="$OPS_ROOT"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/claims.sh"
  claim_ids
) >"$TMP_DIR/out" 2>"$TMP_DIR/err" || RC=$?
OUT="$(cat "$TMP_DIR/out" 2>/dev/null || true)"
ac_assert_eq "$RC" "0" "OPS_REPO_ROOT fallback must return 0 (rc=$RC)"
ac_assert_eq "$OUT" "dev-comes-back" \
  "OPS_REPO_ROOT/claims must be the default dir (got '$OUT')"

ac_pass "issue #1640: read claim files from the ops repo"
