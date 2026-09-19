#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1182.sh
#
# Issue #1182: commit_result_via_git has no push credentials — rejected
# actions retry forever. The scratch clone of the ops repo was anonymous
# (public-read), so every result push got a 401; the stderr was suppressed
# (2>/dev/null) and every failure was mislogged as "Push conflict —
# rebasing", so terminally rejected actions were re-processed every 60s
# cycle forever.
#
# The fix must:
#   1. give the scratch clone push credentials — the Forge PAT from
#      $FACTORY_FORGE_PAT_FILE (default /secrets/forge-pat), or the
#      FACTORY_FORGE_PAT env var if set (dev override wins); the token is
#      handed to a one-shot credential.helper script inside the scratch
#      repo's .git/ dir — never embedded in the clone URL or a log line;
#   2. log the real push stderr on failure instead of a blanket
#      "Push conflict — rebasing";
#   3. move terminally rejected actions (move_to_rejected=yes) out of
#      vault/actions/ into vault/rejected/ in the same commit as the
#      result, so the 60s poll loop stops re-processing them.
#
# Verifies (all checks read-only — temp dirs under mktemp only, no forge,
# no real git remote: the dispatcher function is extracted and executed in
# a stubbed subshell where `git` and `log` are fake):
#   1. PAT from $FACTORY_FORGE_PAT_FILE lands in the one-shot credential
#      helper script (username=x-access-token / password=<pat>) and the
#      helper path is configured via `git config credential.helper`; the
#      clone URL carries no token and the token never appears in the log.
#   2. FACTORY_FORGE_PAT env var takes precedence over the PAT file.
#   3. No PAT available (no env, no file) → returns 1, logs "No Forge PAT",
#      and no clone/push is attempted.
#   4. A failing push logs the real git stderr verbatim in
#      "Push failed for <id> (attempt 1/3): …" — the old blanket
#      "Push conflict — rebasing" message is gone — and the retry on
#      attempt 2 succeeds.
#   5. move_to_rejected=yes issues `git mv vault/actions/<id>.toml
#      vault/rejected/<id>.toml` and the commit message carries
#      "(rejected)"; the default (no 4th arg) issues no `git mv`.
#
# Run via: tools/run-acceptance.sh 1182
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep awk mktemp jq tr cp

DISPATCHER="$REPO_ROOT/docker/edge/dispatcher.sh"
ac_assert_file "$DISPATCHER" "docker/edge/dispatcher.sh is missing"

FN=$(ac_extract_fn commit_result_via_git "$DISPATCHER")
[ -n "$FN" ] \
  || ac_fail "could not extract commit_result_via_git from docker/edge/dispatcher.sh"

# ── Static regression guard: the old blanket mis-log is gone ────────────────
# (the doc comment may reference the historical string — the log statement
# itself must be gone)
if grep -qF 'log "Push conflict' "$DISPATCHER"; then
  ac_fail "dispatcher.sh still logs the blanket 'Push conflict — rebasing' message (#1182)"
fi
ac_log "static: blanket 'Push conflict — rebasing' message removed"

# ── Stubbed subshell runner ──────────────────────────────────────────────────
# Runs the extracted commit_result_via_git in a bash -s subshell where:
#   - git is a fake: clone seeds an empty fake repo (URL + a vault/actions/
#     toml for AC_ACTION_ID), `config credential.helper` dumps the helper
#     script while the scratch dir is still alive, push fails
#     AC_PUSH_FAILS times (writing a realistic 401 stderr) then succeeds;
#   - log() appends to AC_LOG_FILE;
#   - every git invocation is recorded to AC_CALLS_FILE.
# Result artifacts are left in $WORK/run-<n>/ for the assertions.

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
RUN_N=0

run_commit() {
  # run_commit <env_pat|empty> <pat_mode:absent|content> <pat_content> <push_fails> <action_id> <exit_code> <logs> [move]
  local env_pat="$1" pat_mode="$2" pat_content="$3" push_fails="$4"
  shift 4
  RUN_N=$((RUN_N + 1))
  local dir="$WORK/run-$RUN_N"
  mkdir -p "$dir"
  local pat_file="$dir/pat"
  if [ "$pat_mode" = "content" ]; then
    printf '%s\n' "$pat_content" > "$pat_file"
  fi

  local rc=0
  FACTORY_FORGE_PAT="$env_pat" \
    FACTORY_FORGE_PAT_FILE="$pat_file" \
    FORGE_URL="https://factory.forge.example" \
    FORGE_OPS_REPO="disinto-admin/disinto-ops" \
    PRIMARY_BRANCH=main \
    AC_ACTION_ID="$1" \
    AC_PUSH_FAILS="$push_fails" \
    AC_LOG_FILE="$dir/log.txt" \
    AC_CALLS_FILE="$dir/git-calls.txt" \
    AC_HELPER_DUMP="$dir/helper.sh" \
    AC_CLONE_URL_DUMP="$dir/clone-url.txt" \
    bash -s "$FN" "$@" <<'AC_SUBSHELL' || rc=$?
set -u
: > "$AC_LOG_FILE"
: > "$AC_CALLS_FILE"
log() { printf '%s\n' "$*" >> "$AC_LOG_FILE"; }
git() {
  printf 'git %s\n' "$*" >> "$AC_CALLS_FILE"
  local sub dir
  if [ "${1:-}" = "-C" ]; then
    dir="${2:-}"; sub="${3:-}"; shift 3
  else
    dir=""; sub="${1:-}"; shift
  fi
  case "$sub" in
    clone)
      local skip=0 url="" dest="" a
      for a in "$@"; do
        if [ "$skip" -eq 1 ]; then skip=0; continue; fi
        case "$a" in
          --depth|--branch) skip=1 ;;
          -*) : ;;
          *)
            if [ -z "$url" ]; then url="$a"; else dest="$a"; fi
            ;;
        esac
      done
      mkdir -p "$dest/.git"
      printf '%s\n' "$url" > "$dest/.git/clone-url"
      [ -n "${AC_CLONE_URL_DUMP:-}" ] && cp "$dest/.git/clone-url" "$AC_CLONE_URL_DUMP"
      mkdir -p "$dest/vault/actions"
      printf 'id = "%s"\n' "${AC_ACTION_ID:-ac-test}" \
        > "$dest/vault/actions/${AC_ACTION_ID:-ac-test}.toml"
      return 0
      ;;
    config)
      if [ "${1:-}" = "credential.helper" ] && [ -n "${2:-}" ] && [ -f "$2" ]; then
        [ -n "${AC_HELPER_DUMP:-}" ] && cp "$2" "$AC_HELPER_DUMP"
      fi
      return 0
      ;;
    push)
      local cf="${AC_CALLS_FILE}.count" n=0
      [ -f "$cf" ] && n=$(cat "$cf")
      n=$((n + 1))
      printf '%s\n' "$n" > "$cf"
      if [ "$n" -le "$AC_PUSH_FAILS" ]; then
        echo "fatal: Authentication failed for 'https://factory.forge.example/disinto-admin/disinto-ops.git/'" >&2
        return 128
      fi
      return 0
      ;;
    *)
      return 0
      ;;
  esac
}
eval "$1"
shift
commit_result_via_git "$@"
exit $?
AC_SUBSHELL
  RUN_RC=$rc
}

run_dir() { echo "$WORK/run-$1"; }

# ── 1. PAT from file → one-shot credential helper, token-free clone URL ─────
run_commit "" "content" "test-pat-123" 0 "ac-happy" 0 "ok"
D="$(run_dir 1)"
ac_assert_eq "$RUN_RC" "0" "PAT-from-file run: expected rc=0, got $RUN_RC"
grep -q 'Result committed and pushed for ac-happy (attempt 1)' "$D/log.txt" \
  || ac_fail "PAT-from-file run: push did not succeed (log: $(tr '\n' ' ' < "$D/log.txt"))"
ac_assert_file "$D/helper.sh" "credential helper script was never created"
grep -q '^echo username=x-access-token$' "$D/helper.sh" \
  || ac_fail "credential helper: missing 'echo username=x-access-token' line"
grep -q '^echo password=test-pat-123$' "$D/helper.sh" \
  || ac_fail "credential helper: password line does not carry the PAT from ${FACTORY_FORGE_PAT_FILE:-/secrets/forge-pat} (content: $(tr '\n' ' ' < "$D/helper.sh"))"
grep -q 'config credential.helper' "$D/git-calls.txt" \
  || ac_fail "credential.helper was never configured on the scratch repo"
grep -q 'credential-pat.sh' "$D/git-calls.txt" \
  || ac_fail "configured credential.helper is not the one-shot .git/credential-pat.sh script"
ac_assert_eq "$(tr -d '\r' < "$D/clone-url.txt")" "https://factory.forge.example/disinto-admin/disinto-ops.git" \
  "clone URL is not the plain ops-repo URL"
if grep -qF 'test-pat-123' "$D/clone-url.txt"; then
  ac_fail "clone URL contains the Forge PAT token"
fi
if grep -qF 'test-pat-123' "$D/log.txt"; then
  ac_fail "the Forge PAT token appears in the dispatcher log"
fi
if grep -q ' mv ' "$D/git-calls.txt"; then
  ac_fail "default run (no 4th arg) must not issue git mv"
fi
ac_log "1: PAT from file → one-shot credential helper; clone URL and log carry no token; no git mv by default"

# ── 2. FACTORY_FORGE_PAT env var wins over the PAT file ─────────────────────
run_commit "env-pat-456" "content" "file-pat-789" 0 "ac-env" 0 "ok"
D="$(run_dir 2)"
ac_assert_eq "$RUN_RC" "0" "env-pat run: expected rc=0, got $RUN_RC"
grep -q '^echo password=env-pat-456$' "$D/helper.sh" \
  || ac_fail "env FACTORY_FORGE_PAT did not take precedence over the PAT file (helper: $(tr '\n' ' ' < "$D/helper.sh"))"
if grep -qF 'file-pat-789' "$D/helper.sh"; then
  ac_fail "PAT file token used although FACTORY_FORGE_PAT was set"
fi
ac_log "2: FACTORY_FORGE_PAT env var takes precedence over the PAT file"

# ── 3. No PAT available → fail fast, no clone, no push ──────────────────────
run_commit "" "absent" "" 0 "ac-nopat" 0 "ok"
D="$(run_dir 3)"
ac_assert_eq "$RUN_RC" "1" "no-PAT run: expected rc=1, got $RUN_RC"
grep -q 'No Forge PAT available for result push' "$D/log.txt" \
  || ac_fail "no-PAT run: missing 'No Forge PAT available' error (log: $(tr '\n' ' ' < "$D/log.txt"))"
if grep -q '^git clone' "$D/git-calls.txt"; then
  ac_fail "no-PAT run: an anonymous clone was attempted (guaranteed 401)"
fi
ac_log "3: no PAT → rc=1, 'No Forge PAT' logged, no clone/push attempted"

# ── 4. Real push stderr is logged; retry succeeds on attempt 2 ──────────────
run_commit "" "content" "test-pat-123" 1 "ac-pushfail" 0 "ok"
D="$(run_dir 4)"
ac_assert_eq "$RUN_RC" "0" "push-fail run: expected rc=0 (recovered on attempt 2), got $RUN_RC"
grep -q "Push failed for ac-pushfail (attempt 1/3): fatal: Authentication failed for 'https://factory.forge.example/disinto-admin/disinto-ops.git/'" \
  "$D/log.txt" \
  || ac_fail "push failure: real git stderr not logged verbatim (log: $(tr '\n' ' ' < "$D/log.txt"))"
grep -q 'Result committed and pushed for ac-pushfail (attempt 2)' "$D/log.txt" \
  || ac_fail "push failure: retry on attempt 2 did not succeed (log: $(tr '\n' ' ' < "$D/log.txt"))"
if grep -qF 'Push conflict — rebasing' "$D/log.txt"; then
  ac_fail "push failure was mislogged as 'Push conflict — rebasing'"
fi
ac_log "4: push failure logs the real stderr verbatim; retry succeeds on attempt 2"

# ── 5. move_to_rejected=yes → git mv to vault/rejected/ + '(rejected)' ──────
run_commit "" "content" "test-pat-123" 0 "ac-rej" 1 "Validation failed: see logs above" yes
D="$(run_dir 5)"
ac_assert_eq "$RUN_RC" "0" "move-to-rejected run: expected rc=0, got $RUN_RC"
grep -q 'mv vault/actions/ac-rej.toml vault/rejected/ac-rej.toml' "$D/git-calls.txt" \
  || ac_fail "move_to_rejected=yes: git mv vault/actions → vault/rejected/ not issued (calls: $(tr '\n' ' ' < "$D/git-calls.txt"))"
grep -qF 'commit -q -m vault: result for ac-rej (rejected)' "$D/git-calls.txt" \
  || ac_fail "move_to_rejected=yes: commit message missing the '(rejected)' suffix"
grep -q 'terminally rejected — moving toml to vault/rejected/' "$D/log.txt" \
  || ac_fail "move_to_rejected=yes: expected 'terminally rejected' log line missing"
ac_log "5: move_to_rejected=yes moves the toml to vault/rejected/ with the result"

ac_pass
