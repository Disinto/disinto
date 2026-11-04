#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2110.sh
#
# Issue #2110: lib/branch-rules.sh sets up the rollout branches.
#
#   branch_rule_apply REPO RULE JSON
#     GET <base>/branch_protections/RULE
#       200 -> PATCH that URL with JSON
#       404 -> POST <base>/branch_protections with JSON plus "rule_name": RULE
#     0 on a 2xx answer, 1 otherwise (one stderr line naming the HTTP code).
#   rollout_branches_setup REPO
#     GET <base>/branches/live and <base>/branches/canary; on 404 POST
#     <base>/branches with {"new_branch_name":"<b>","old_branch_name":"main"}.
#     Then the push rule on live only. 1 at the first failure.
#   Run directly: lib/branch-rules.sh rollout-branches <owner/repo>; anything
#   else prints usage and exits 2.
#
# And lib/forge-setup.sh grants supervisor-bot `write`, the permission a push
# to live or canary needs.
#
# Hermetic: a stub curl on PATH records "<METHOD> <URL> <BODY>" one call per
# line and answers by URL (the trick tests/lib-branch-protection.bats uses).
# No forge, no network.
#
# Acceptance: `bash tests/acceptance/issue-2110.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep

RULES="$REPO_ROOT/lib/branch-rules.sh"
SETUP="$REPO_ROOT/lib/forge-setup.sh"
ac_assert_file "$RULES" "lib/branch-rules.sh is missing"
ac_assert_file "$SETUP" "lib/forge-setup.sh is missing"

STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT
CALL_LOG="$STUB_DIR/calls.txt"
ERR_FILE="$STUB_DIR/stderr.txt"
: > "$CALL_LOG"
: > "$ERR_FILE"

# ── the stub curl ─────────────────────────────────────────────────────────────
cat > "$STUB_DIR/curl" <<'CURLSTUB'
#!/usr/bin/env bash
# Stub curl: record "<METHOD> <URL> <BODY>", answer with a status code picked
# from the URL and the *_CODE variables the test exports.
method="GET" url="" body="" prev=""
for arg in "$@"; do
  case "$prev" in
    -X)    method="$arg"; prev=""; continue ;;
    -d)    body="$arg";   prev=""; continue ;;
    --data) body="$arg";  prev=""; continue ;;
  esac
  case "$arg" in
    -X|-d|--data) prev="$arg" ;;
    http*)        url="$arg" ;;
  esac
done
printf '%s %s %s\n' "$method" "$url" "$body" >> "$CALL_LOG"

code=200
case "$url" in
  */branch_protections/*)
    if [ "$method" = "GET" ]; then
      code="${RULE_GET_CODE:-200}"
    else
      code="${RULE_WRITE_CODE:-200}"
    fi
    ;;
  */branch_protections)
    code="${RULE_POST_CODE:-201}"
    ;;
  */branches/live)   code="${BRANCH_LIVE_CODE:-404}" ;;
  */branches/canary) code="${BRANCH_CANARY_CODE:-404}" ;;
  */branches)        code="${BRANCH_POST_CODE:-201}" ;;
esac
printf '%s' "$code"
exit 0
CURLSTUB
chmod +x "$STUB_DIR/curl"

# ── helpers ───────────────────────────────────────────────────────────────────
BASE="https://forge.test/api/v1/repos/acme/r"

# run_branch_rules FN [ARGS...] — source lib/branch-rules.sh in a clean
# subshell whose curl is the stub. Sets RC and ERR.
run_branch_rules() {
  local fn="$1"; shift
  RC=0
  : > "$CALL_LOG"
  : > "$ERR_FILE"
  PATH="$STUB_DIR:$PATH" FORGE_URL="https://forge.test" FORGE_TOKEN="stub-admin-token" \
    CALL_LOG="$CALL_LOG" \
    bash -c 'source "$LIB"; "$0" "$@"' "$fn" "$@" >/dev/null 2>"$ERR_FILE" || RC=$?
  ERR="$(cat "$ERR_FILE")"
}

# call_count PATTERN — number of recorded calls whose line contains PATTERN.
call_count() {
  local n
  n="$(grep -c -F -- "$1" "$CALL_LOG" || true)"
  printf '%s' "${n:-0}"
}

export LIB="$RULES"

# ── AC1: a missing rule is created with one POST naming rule_name ─────────────
ac_log "AC1: branch_rule_apply on a 404 rule POSTs once with rule_name"
RULE_GET_CODE=404 RULE_POST_CODE=201 export RULE_GET_CODE RULE_POST_CODE
run_branch_rules branch_rule_apply acme/r live '{"enable_push":true}'
ac_assert_eq "$RC" "0" "branch_rule_apply must return 0 on the created rule (rc=$RC, stderr: $ERR)"
ac_assert_eq "$(call_count "POST $BASE/branch_protections ")" "1" \
  "exactly one POST to .../branch_protections expected (calls: $(tr '\n' ';' < "$CALL_LOG"))"
ac_assert_eq "$(call_count '"rule_name":"live"')" "1" \
  "the POST body must carry \"rule_name\":\"live\" (calls: $(tr '\n' ';' < "$CALL_LOG"))"
ac_assert_eq "$(call_count "PATCH $BASE/branch_protections/live")" "0" \
  "a 404 rule must not be PATCHed"
ac_assert_eq "$(call_count "GET $BASE/branch_protections/live")" "1" \
  "branch_rule_apply must probe the rule with a GET first"

# ── AC2: an existing rule is patched, never created ───────────────────────────
ac_log "AC2: branch_rule_apply on a 200 rule PATCHs once, no POST"
RULE_GET_CODE=200 RULE_WRITE_CODE=200 export RULE_GET_CODE RULE_WRITE_CODE
run_branch_rules branch_rule_apply acme/r live '{"enable_push":true}'
ac_assert_eq "$RC" "0" "branch_rule_apply must return 0 on a patched rule (rc=$RC, stderr: $ERR)"
ac_assert_eq "$(call_count "PATCH $BASE/branch_protections/live")" "1" \
  "exactly one PATCH to .../branch_protections/live expected"
ac_assert_eq "$(call_count "POST $BASE/branch_protections ")" "0" \
  "an existing rule must not be POSTed (calls: $(tr '\n' ';' < "$CALL_LOG"))"

# ── AC3: rollout_branches_setup creates both branches and the live rule ───────
ac_log "AC3: rollout_branches_setup creates live and canary at main, rule on live"
BRANCH_LIVE_CODE=404 BRANCH_CANARY_CODE=404 BRANCH_POST_CODE=201 \
  RULE_GET_CODE=404 RULE_POST_CODE=201 \
  export BRANCH_LIVE_CODE BRANCH_CANARY_CODE BRANCH_POST_CODE RULE_GET_CODE RULE_POST_CODE
run_branch_rules rollout_branches_setup acme/r
ac_assert_eq "$RC" "0" "rollout_branches_setup must return 0 (rc=$RC, stderr: $ERR)"
ac_assert_eq "$(call_count "GET $BASE/branches/live")" "1" "live must be probed with a GET"
ac_assert_eq "$(call_count "GET $BASE/branches/canary")" "1" "canary must be probed with a GET"
ac_assert_eq "$(call_count "POST $BASE/branches ")" "2" \
  "two POSTs to .../branches expected (calls: $(tr '\n' ';' < "$CALL_LOG"))"
ac_assert_eq "$(call_count '"new_branch_name":"live","old_branch_name":"main"')" "1" \
  "the live POST must name live with old_branch_name main"
ac_assert_eq "$(call_count '"new_branch_name":"canary","old_branch_name":"main"')" "1" \
  "the canary POST must name canary with old_branch_name main"
ac_assert_eq "$(call_count "POST $BASE/branch_protections ")" "1" \
  "exactly one rule POST expected"
ac_assert_eq "$(call_count '"rule_name":"live"')" "1" "the rule must be named live"
ac_assert_eq "$(call_count '"push_whitelist_usernames":["supervisor-bot","disinto-admin"')" "1" \
  "the live rule must whitelist supervisor-bot and disinto-admin"
ac_assert_eq "$(call_count "branch_protections/canary")" "0" \
  "no request may name a canary rule"
ac_assert_eq "$(call_count "canary")" "2" \
  "canary appears only in its probe and its creation (calls: $(tr '\n' ';' < "$CALL_LOG"))"

# ── AC4: existing branches are left where they are ────────────────────────────
ac_log "AC4: existing live and canary get no branch POST"
BRANCH_LIVE_CODE=200 BRANCH_CANARY_CODE=200 RULE_GET_CODE=200 RULE_WRITE_CODE=200 \
  export BRANCH_LIVE_CODE BRANCH_CANARY_CODE RULE_GET_CODE RULE_WRITE_CODE
run_branch_rules rollout_branches_setup acme/r
ac_assert_eq "$RC" "0" "rollout_branches_setup must return 0 (rc=$RC, stderr: $ERR)"
ac_assert_eq "$(call_count "POST $BASE/branches ")" "0" \
  "no POST to .../branches when both exist (calls: $(tr '\n' ';' < "$CALL_LOG"))"
ac_assert_eq "$(call_count "PATCH $BASE/branch_protections/live")" "1" \
  "the existing live rule must still be patched"

# ── AC5: a 500 on the rule POST is a failure, named on stderr ──────────────────
ac_log "AC5: a 500 on the rule POST returns 1 and names the code"
BRANCH_LIVE_CODE=200 BRANCH_CANARY_CODE=200 RULE_GET_CODE=404 RULE_POST_CODE=500 \
  export BRANCH_LIVE_CODE BRANCH_CANARY_CODE RULE_GET_CODE RULE_POST_CODE
run_branch_rules rollout_branches_setup acme/r
ac_assert_eq "$RC" "1" "a 500 on the rule POST must return 1 (rc=$RC)"
grep -F -q -- "500" "$ERR_FILE" \
  || ac_fail "the failure must name the HTTP code 500 on stderr (got: $ERR)"

# ── AC6: the CLI and the supervisor-bot grant ─────────────────────────────────
ac_log "AC6: lib/branch-rules.sh rollout-branches <repo>; anything else is usage"
BRANCH_LIVE_CODE=404 BRANCH_CANARY_CODE=404 BRANCH_POST_CODE=201 RULE_GET_CODE=404 RULE_POST_CODE=201 \
  export BRANCH_LIVE_CODE BRANCH_CANARY_CODE BRANCH_POST_CODE RULE_GET_CODE RULE_POST_CODE
RC=0
: > "$CALL_LOG"
PATH="$STUB_DIR:$PATH" FORGE_URL="https://forge.test" FORGE_TOKEN="stub-admin-token" \
  CALL_LOG="$CALL_LOG" bash "$RULES" rollout-branches acme/r >/dev/null 2>"$ERR_FILE" || RC=$?
ac_assert_eq "$RC" "0" "rollout-branches must run the setup (rc=$RC)"
ac_assert_eq "$(call_count "POST $BASE/branches ")" "2" "the CLI must create both branches"

RC=0
: > "$ERR_FILE"
PATH="$STUB_DIR:$PATH" FORGE_URL="https://forge.test" FORGE_TOKEN="stub-admin-token" \
  CALL_LOG="$CALL_LOG" bash "$RULES" nonsense acme/r >/dev/null 2>"$ERR_FILE" || RC=$?
ac_assert_eq "$RC" "2" "an unknown command must print usage and exit 2 (rc=$RC)"
grep -F -q -- "Usage: lib/branch-rules.sh" "$ERR_FILE" \
  || ac_fail "unknown command must print usage (got: $(cat "$ERR_FILE"))"

ac_log "AC6b: supervisor-bot is granted write in lib/forge-setup.sh"
ac_assert_eq "$(grep -c '\[supervisor-bot\]="write"' "$SETUP")" "1" \
  "lib/forge-setup.sh must grant supervisor-bot write exactly once"

ac_log "AC7: bash -n passes on both files"
bash -n "$RULES" || ac_fail "bash -n failed on lib/branch-rules.sh"
bash -n "$SETUP" || ac_fail "bash -n failed on lib/forge-setup.sh"

ac_pass
