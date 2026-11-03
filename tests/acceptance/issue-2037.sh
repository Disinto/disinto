#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2037.sh
#
# Issue #2037: vault_request merges a medium/high vault PR at once (the gate
# approves itself, docs/design/proposal-loop.md §3) instead of requesting
# merge_when_checks_succeed, and queues an owner notice via lib/notice.sh
# (#2031). A failed merge leaves the PR open and never fails the request.
#
# Hermetic: FACTORY_ROOT is a temp dir holding a stub action-vault/vault-env.sh
# (validate_vault_action -> 0) and a stub action-vault/classify.sh printing
# ${VAULT_BLAST_RADIUS_OVERRIDE:-high}; pr_find_by_branch (prints nothing) and
# pr_create (prints 7) are test-defined; curl is the ac_write_curl_stub binary
# rewritten here as a recorder that logs every call as METHOD|URL|BODY.
# NOTICES_DIR is a temp dir.
#
# Acceptance: `bash tests/acceptance/issue-2037.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq grep
ac_assert_file "$REPO_ROOT/lib/action-vault.sh" "lib/action-vault.sh is missing"
ac_assert_file "$REPO_ROOT/lib/notice.sh" "lib/notice.sh is missing (dependency #2031)"

# ── Fixture: temp FACTORY_ROOT with stub vault-env.sh and classify.sh ───────
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FACTORY="$TMP_DIR/factory"
mkdir -p "$FACTORY/action-vault"
cat > "$FACTORY/action-vault/vault-env.sh" <<'EOF'
validate_vault_action() { return 0; }
EOF
cat > "$FACTORY/action-vault/classify.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s' "${VAULT_BLAST_RADIUS_OVERRIDE:-high}"
EOF
chmod +x "$FACTORY/action-vault/classify.sh"

# ── Recorder curl: the ac_write_curl_stub shape, rewritten to log every call ─
STUB_BIN="$TMP_DIR/stub"
mkdir -p "$STUB_BIN"
ac_write_curl_stub "$STUB_BIN"
[ -x "$STUB_BIN/curl" ] || ac_fail "ac_write_curl_stub did not write an executable curl"
cat > "$STUB_BIN/curl" <<'RECORDER'
#!/usr/bin/env bash
# Fake ops forge — records every call as METHOD|URL|BODY, answers per endpoint.
# STUB_FAIL_MERGE=1 makes */pulls/*/merge exit 22 (the failed-merge seam).
set -euo pipefail
method="GET"
body=""
url=""
prev=""
for arg in "$@"; do
  case "$prev" in
    -X) method="$arg" ;;
    -d|--data) body="$arg" ;;
  esac
  prev="$arg"
  case "$arg" in
    http://*|https://*) url="$arg" ;;
  esac
done
printf '%s|%s|%s\n' "$method" "$url" "$body" >> "${CURL_RECORD:?}"
case "$url" in
  */git/branches/main)
    printf '{"commit":{"id":"stub-sha"}}'
    ;;
  */git/branches/vault/*)
    # The branch-existence probe reads -w "%{http_code}"; body "200" stands in.
    printf '200'
    ;;
  */pulls/*/merge)
    if [ "${STUB_FAIL_MERGE:-}" = "1" ]; then
      exit 22
    fi
    printf '{"Done":true}'
    ;;
  */contents/*)
    printf '{"ok":true}'
    ;;
  */labels)
    printf '[]'
    ;;
  *)
    exit 22
    ;;
esac
RECORDER
chmod +x "$STUB_BIN/curl"

RECORD="$TMP_DIR/calls.txt"
: > "$RECORD"

export PATH="$STUB_BIN:$PATH"
export CURL_RECORD="$RECORD"
export FACTORY_ROOT="$FACTORY"
export FORGE_URL="https://forge.example"
export FORGE_REPO="disinto-admin/disinto"
export FORGE_OPS_REPO="disinto-admin/disinto-ops"
export FORGE_TOKEN="stub-token"
export PRIMARY_BRANCH="main"
export NOTICES_DIR="$TMP_DIR/notices"
mkdir -p "$NOTICES_DIR"

# shellcheck source=../../lib/action-vault.sh
source "$REPO_ROOT/lib/action-vault.sh"

# The forge PR helpers the caller normally provides (lib/pr-lifecycle.sh).
pr_find_by_branch() { :; }
pr_create() { printf '7'; }

TOML='action = "stub"
blast_radius = "medium"'

# run_vault <action_id> <toml> — call vault_request in a subshell, capturing
# stdout in OUT, stderr in ERR, and the status in RC.
run_vault() {
  : > "$RECORD"
  RC=0
  OUT=""
  ERR=""
  ( vault_request "$1" "$2" ) >"$TMP_DIR/stdout" 2>"$TMP_DIR/stderr" || RC=$?
  OUT="$(cat "$TMP_DIR/stdout")"
  ERR="$(cat "$TMP_DIR/stderr")"
}

# notice_matching <dir> <substring...> — 0 if some notice file in dir holds
# every substring.
notice_matching() {
  local dir="$1"; shift
  local f needle ok
  for f in "$dir"/*.txt; do
    [ -f "$f" ] || continue
    ok=1
    for needle in "$@"; do
      grep -qF -- "$needle" "$f" || { ok=0; break; }
    done
    [ "$ok" = 1 ] && return 0
  done
  return 1
}

# ── AC1: medium tier merges PR 7 at once; no auto-merge request ──────────────
ac_log "AC1: medium tier — gate POSTs /pulls/7/merge with {\"Do\":\"merge\"}, no merge_when_checks_succeed"
VAULT_BLAST_RADIUS_OVERRIDE=medium run_vault act-1 "$TOML"
ac_assert_eq "$RC" "0" "medium-tier vault_request must return 0 (got $RC): $ERR"
ac_assert_eq "$OUT" "7" "vault_request must print the PR number 7 (got '$OUT')"
merge_line="$(grep -F 'POST|https://forge.example/api/v1/repos/disinto-admin/disinto-ops/pulls/7/merge|' "$RECORD" || true)"
[ -n "$merge_line" ] || ac_fail "the gate must POST /pulls/7/merge; recorded: $(cat "$RECORD")"
ac_assert_eq "${merge_line##*|}" '{"Do":"merge"}' "the merge body must be exactly {\"Do\":\"merge\"} (got '${merge_line##*|}')"
if grep -qF 'merge_when_checks_succeed' "$RECORD"; then
  ac_fail "the auto-merge request merge_when_checks_succeed must be gone (found in $RECORD)"
fi
printf '%s' "$ERR" | grep -qF 'merged by the gate (tier medium)' \
  || ac_fail "the gate must log 'PR #7 merged by the gate (tier medium)' (stderr: $ERR)"
ac_log "AC1 OK"

# ── AC2: one notice in NOTICES_DIR holds act-1, medium and #7 ────────────────
ac_log "AC2: the owner is told: a notice contains act-1, medium and #7"
notice_matching "$NOTICES_DIR" act-1 medium '#7' \
  || ac_fail "a notice in $NOTICES_DIR must contain act-1, medium and #7 (files: $(ls "$NOTICES_DIR"))"
ac_log "AC2 OK"

# ── AC3: a failing merge call still prints 7 and returns 0 ───────────────────
ac_log "AC3: merge POST fails — the request still prints 7 and returns 0"
STUB_FAIL_MERGE=1 VAULT_BLAST_RADIUS_OVERRIDE=high run_vault act-1 "$TOML"
ac_assert_eq "$RC" "0" "a failed gate merge must not fail the request (got $RC)"
ac_assert_eq "$OUT" "7" "the function must still print the PR number 7 (got '$OUT')"
printf '%s' "$ERR" | grep -qF 'Warning: gate merge of PR #7 failed' \
  || ac_fail "the gate must log a merge-failure warning (stderr: $ERR)"
merge_line="$(grep -F 'POST|https://forge.example/api/v1/repos/disinto-admin/disinto-ops/pulls/7/merge|' "$RECORD" || true)"
[ -n "$merge_line" ] || ac_fail "the merge attempt must still have been POSTed"
ac_log "AC3 OK"

# ── AC4: low tier — no PR at all, one notice with act-2 and low ──────────────
ac_log "AC4: low tier — no /pulls call; a notice contains act-2 and low"
LOW_NOTICES="$TMP_DIR/notices-low"
NOTICES_DIR="$LOW_NOTICES" VAULT_BLAST_RADIUS_OVERRIDE=low run_vault act-2 "$TOML"
ac_assert_eq "$RC" "0" "low-tier vault_request must return 0 (got $RC): $ERR"
if grep -qF '/pulls' "$RECORD"; then
  ac_fail "the low tier must not touch /pulls (recorded: $(cat "$RECORD"))"
fi
notice_matching "$LOW_NOTICES" act-2 low \
  || ac_fail "a notice must contain act-2 and low (files: $(ls "$LOW_NOTICES"))"
ac_log "AC4 OK"

# ── AC5: lib/action-vault.sh parses cleanly ──────────────────────────────────
ac_log "AC5: bash -n lib/action-vault.sh passes"
bash -n "$REPO_ROOT/lib/action-vault.sh" \
  || ac_fail "bash -n lib/action-vault.sh failed"
ac_log "AC5 OK"

# ── AC6: the docs match the new behavior ─────────────────────────────────────
ac_log "AC6: BLAST-RADIUS.md, VAULT.md and lib/AGENTS.md describe the gate merge"
grep -qF 'PR on ops repo, merged by the gate at once; the owner is told (proposal-loop.md §3)' \
  "$REPO_ROOT/docs/BLAST-RADIUS.md" \
  || ac_fail "docs/BLAST-RADIUS.md must say medium/high are merged by the gate at once"
grep -qF 'the account that opens a vault PR merges it at once' "$REPO_ROOT/docs/VAULT.md" \
  || ac_fail "docs/VAULT.md must describe the gate self-approval paragraph"
grep -qF 'Bot accounts open and merge their own vault PRs' "$REPO_ROOT/docs/VAULT.md" \
  || ac_fail "docs/VAULT.md must replace the Bot Account Behavior section"
grep -qF 'Since #2037 it merges that PR itself (the gate) and queues a notice for the owner with ' \
  "$REPO_ROOT/lib/AGENTS.md" \
  || ac_fail "lib/AGENTS.md must note the #2037 gate merge and notice"
ac_log "AC6 OK"

ac_pass
