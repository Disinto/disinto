#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2034.sh
#
# Issue #2034: fix(dispatcher): a merged vault PR passes verification without
# an admin merger. verify_admin_merged used to reject any PR not approved by
# an admin reviewer or merged by an admin — but since the gate merges vault
# PRs transparently (docs/design/proposal-loop.md §3, #2037), every medium
# and high action would be rejected. Merging IS the approval: the dispatcher
# only checks that the TOML arrived through a merged PR, never who merged it.
# Also: get_pr_merger read .merge_user?.login // .user?.login, but Forgejo's
# PR object carries merged_by (no merge_user), so the merger username must be
# .merged_by?.login // .merge_user?.login // .user?.login.
#
# Hermetic: verify_admin_merged and get_pr_merger are extracted from
# docker/edge/dispatcher.sh with ac_extract_fn and run in a throwaway
# subshell. get_pr_for_file is a stub printing 12 (or failing), log() writes
# to a temp file, and curl is the ac_write_curl_stub fake rewritten to answer
# GET .../pulls/12 with $PR_JSON while recording every URL it is called with.
# No live forge, no network.
#
# Acceptance: `bash tests/acceptance/issue-2034.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq grep awk mktemp

DISPATCHER="$REPO_ROOT/docker/edge/dispatcher.sh"
ac_assert_file "$DISPATCHER" "docker/edge/dispatcher.sh is missing"

verify_fn="$(ac_extract_fn verify_admin_merged "$DISPATCHER")"
[ -n "$verify_fn" ] \
  || ac_fail "could not extract verify_admin_merged from docker/edge/dispatcher.sh"
merger_fn="$(ac_extract_fn get_pr_merger "$DISPATCHER")"
[ -n "$merger_fn" ] \
  || ac_fail "could not extract get_pr_merger from docker/edge/dispatcher.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Fake forge: ac_write_curl_stub, rewritten to answer /pulls/12 ────────────
STUB_BIN="$TMP_DIR/stub"
mkdir -p "$STUB_BIN"
ac_write_curl_stub "$STUB_BIN"
[ -x "$STUB_BIN/curl" ] || ac_fail "ac_write_curl_stub did not write an executable curl"
cat > "$STUB_BIN/curl" <<'CURL_STUB'
#!/usr/bin/env bash
# Fake ops forge — records every URL; GET */pulls/12 answers with $PR_JSON.
# AC_STUB_FAIL=1 makes every call exit 22 (the transient-failure seam).
url="$*"
printf '%s\n' "$url" >> "${CURL_CALLS:?}"
if [ "${AC_STUB_FAIL:-0}" = 1 ]; then
  exit 22
fi
case "$url" in
  */pulls/12)
    printf '%s' "$PR_JSON"
    ;;
  *)
    exit 22
    ;;
esac
CURL_STUB
chmod +x "$STUB_BIN/curl"

CALLS="$TMP_DIR/calls.txt"
LOG="$TMP_DIR/log.txt"

# run_verify <pr_json> [get_pr_fail=0] [stub_fail=0] — run the extracted
# verify_admin_merged against the stubbed forge; returns its exit code. The
# log lands in $LOG, every curl URL in $CALLS.
run_verify() {
  local pr_json="$1" get_pr_fail="${2:-0}" stub_fail="${3:-0}"
  : > "$CALLS"
  : > "$LOG"
  PR_JSON="$pr_json" GET_PR_FAIL="$get_pr_fail" AC_STUB_FAIL="$stub_fail" \
  MERGER_FN="$merger_fn" VERIFY_FN="$verify_fn" \
  PATH="$STUB_BIN:$PATH" CURL_CALLS="$CALLS" LOG_FILE="$LOG" \
  FORGE_URL="https://forge.example" FORGE_OPS_REPO="disinto-admin/disinto-ops" \
  FORGE_TOKEN="stub-token" \
  bash -c '
    set -u
    get_pr_for_file() {
      [ "${GET_PR_FAIL:-0}" = 1 ] && return 1
      echo 12
    }
    log() { printf "%s\n" "$1" >> "$LOG_FILE"; }
    eval "$MERGER_FN"
    eval "$VERIFY_FN"
    verify_admin_merged vault/actions/act-1.toml
  '
}

# ── AC1: merged PR merged by the bot gate — verified, rc 0, no reviews call ──
ac_log "AC1: {\"merged\":true,\"merged_by\":{\"login\":\"gardener-bot\"}} — rc 0, log names gardener-bot, no /reviews call"
rc=0
run_verify '{"merged":true,"merged_by":{"login":"gardener-bot"},"user":{"login":"gardener-bot"}}' || rc=$?
ac_assert_eq "$rc" "0" "a PR merged by the bot gate must verify (rc 0), got $rc"
grep -qF 'gardener-bot' "$LOG" \
  || ac_fail "the log must name the merger 'gardener-bot' (log: $(cat "$LOG"))"
grep -qF 'the gate approves transparently' "$LOG" \
  || ac_fail "the verification log must note the gate approves transparently (log: $(cat "$LOG"))"
if grep -qF '/reviews' "$CALLS"; then
  ac_fail "verify_admin_merged must not check reviews anymore (calls: $(cat "$CALLS"))"
fi
ac_log "AC1 OK"

# ── AC2: unmerged PR — terminal rejection, rc 1 ──────────────────────────────
ac_log "AC2: {\"merged\":false} — rc 1 (terminal)"
rc=0
run_verify '{"merged":false,"user":{"login":"gardener-bot"}}' || rc=$?
ac_assert_eq "$rc" "1" "an unmerged PR must be rejected terminally (rc 1), got $rc"
ac_log "AC2 OK"

# ── AC3a: the forge API is down — transient, rc 2 ────────────────────────────
ac_log "AC3a: curl stub failing — rc 2 (transient, retry next cycle)"
rc=0
run_verify '{"merged":true,"merged_by":{"login":"gardener-bot"}}' 0 1 || rc=$?
ac_assert_eq "$rc" "2" "a failed PR fetch must be transient (rc 2), got $rc"
ac_log "AC3a OK"

# ── AC3b: no PR behind the TOML (direct push) — terminal, rc 1 ────────────────
ac_log "AC3b: get_pr_for_file stub failing — rc 1 (terminal)"
rc=0
run_verify '{"merged":true,"merged_by":{"login":"gardener-bot"}}' 1 || rc=$?
ac_assert_eq "$rc" "1" "a TOML with no PR behind it must be rejected terminally (rc 1), got $rc"
ac_log "AC3b OK"

# ── AC4: get_pr_merger prefers merged_by.login over user.login ────────────────
ac_log "AC4: get_pr_merger on merged_by.login=disinto-admin, user.login=dev-bot prints disinto-admin"
username="$(PR_JSON='{"merged":true,"merged_by":{"login":"disinto-admin"},"user":{"login":"dev-bot"}}' \
  MERGER_FN="$merger_fn" \
  PATH="$STUB_BIN:$PATH" CURL_CALLS="$CALLS" \
  FORGE_URL="https://forge.example" FORGE_OPS_REPO="disinto-admin/disinto-ops" \
  FORGE_TOKEN="stub-token" \
  bash -c '
    set -u
    eval "$MERGER_FN"
    get_pr_merger 12 | jq -r .username
  ')"
ac_assert_eq "$username" "disinto-admin" "get_pr_merger must read merged_by.login (got '$username')"
ac_log "AC4 OK"

# ── AC5: the admin-merger check is gone and the dispatcher still parses ──────
ac_log "AC5: the admin-merger check is gone; bash -n passes"
# shellcheck disable=SC2016  # the $merger_username here is the literal grep target
leftover="$(grep -c 'is_allowed_admin "\$merger_username"' "$DISPATCHER" || true)"
ac_assert_eq "$leftover" "0" "verify_admin_merged must not check the merger against the admin list (found $leftover)"
bash -n "$DISPATCHER" || ac_fail "bash -n docker/edge/dispatcher.sh failed"
ac_log "AC5 OK"

# ── AC6: the docs match the new behavior ─────────────────────────────────────
ac_log "AC6: docs/VAULT.md Testing section describes merged-PR dispatch"
grep -qF 'Merged PR runs' "$REPO_ROOT/docs/VAULT.md" \
  || ac_fail "docs/VAULT.md must list the merged-PR run check (#2034)"
grep -qF 'Direct push rejected' "$REPO_ROOT/docs/VAULT.md" \
  || ac_fail "docs/VAULT.md must describe the direct-push rejection"
ac_log "AC6 OK"

ac_pass
