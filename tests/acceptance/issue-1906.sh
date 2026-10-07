#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1906.sh
#
# Issue #1906: read and update a pitch file on its ops-repo PR branch.
#
# lib/pitch-pr.sh (sourced; does not source lib/env.sh) talks to the ops
# repo only. pitch_pr_path prints the sprints/<slug>.md a pitch PR adds.
# pitch_pr_fetch writes that file as it stands on the PR head and prints
# the branch and the blob sha. pitch_pr_put commits a new version through
# the contents API, with no author key, so the token's user is the author.
#
# The curl stub is a shell function (it takes precedence over the binary).
# It logs its arguments and answers by URL. AC_FAIL=1 makes every call
# return 22. Hermetic: no network, no live box.
#
# Docs: lib/AGENTS.md names lib/pitch-pr.sh (#1906).
#
# Acceptance: `bash tests/acceptance/issue-1906.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq base64
ac_assert_file "$REPO_ROOT/lib/pitch-pr.sh" "lib/pitch-pr.sh is missing"

if grep -v '^[[:space:]]*#' "$REPO_ROOT/lib/pitch-pr.sh" | grep -q 'env\.sh'; then
  ac_fail "lib/pitch-pr.sh must not source lib/env.sh"
fi
grep -qF '| `lib/pitch-pr.sh` | A pitch file on its ops-repo PR branch (#1906).' \
  "$REPO_ROOT/lib/AGENTS.md" \
  || ac_fail "lib/AGENTS.md must document lib/pitch-pr.sh (#1906) after gardener-pr.sh"

# The new row sits immediately after the gardener-pr.sh row.
gardener_line="$(grep -n '| `lib/gardener-pr.sh` |' "$REPO_ROOT/lib/AGENTS.md" | head -n1 | cut -d: -f1)"
pitch_line="$(grep -n '| `lib/pitch-pr.sh` |' "$REPO_ROOT/lib/AGENTS.md" | head -n1 | cut -d: -f1)"
[ -n "$gardener_line" ] || ac_fail "lib/AGENTS.md must still have the gardener-pr.sh row"
[ -n "$pitch_line" ] || ac_fail "lib/AGENTS.md must have the pitch-pr.sh row"
[ "$((pitch_line - gardener_line))" -eq 1 ] \
  || ac_fail "pitch-pr.sh row (line $pitch_line) must follow gardener-pr.sh (line $gardener_line)"

T="$(mktemp -d)"
CURL_LOG="$T/curl.jsonl"
trap 'rm -rf "$T"' EXIT

export FORGE_API_BASE="https://forge.example/api/v1"
export FORGE_OPS_REPO="o/ops"
export FORGE_TOKEN="stub"
unset AC_FAIL || true

# curl — log every argument, then answer by URL. AC_FAIL=1 returns 22.
curl() {
  jq -nc --args '$ARGS.positional' -- "$@" >>"$CURL_LOG"
  if [ "${AC_FAIL:-}" = 1 ]; then
    return 22
  fi
  local url="" arg
  for arg in "$@"; do
    case "$arg" in
      http://*|https://*) url="$arg" ;;
    esac
  done
  case "$url" in
    */pulls/5/files)
      printf '%s' '[{"filename":"probes/x.sh","status":"added"},{"filename":"sprints/demo.md","status":"added"}]'
      ;;
    */pulls/5)
      printf '%s' '{"head":{"ref":"architect/demo"}}'
      ;;
    */contents/sprints/demo.md\?ref=architect/demo)
      printf '%s' '{"content":"aGVsbG8K","sha":"abc"}'
      ;;
    *)
      local method="GET" saw_x=0 a
      for a in "$@"; do
        if [ "$saw_x" = 1 ]; then
          method="$a"
          saw_x=0
        fi
        case "$a" in
          -X|--request) saw_x=1 ;;
          -XPUT) method="PUT" ;;
        esac
      done
      if [ "$method" = "PUT" ]; then
        printf '%s' '{"commit":{"sha":"c1"}}'
        return 0
      fi
      echo "curl stub: no answer for ${url:-<no url>}" >&2
      return 22
      ;;
  esac
}

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/pitch-pr.sh"

# ── pitch_pr_path prints the added sprint file, not the probe ───────────────
ac_log "AC1: pitch_pr_path 5 prints sprints/demo.md"
rc=0
out="$(pitch_pr_path 5)" || rc=$?
ac_assert_eq "$rc" "0" "pitch_pr_path must return 0 (rc=$rc)"
ac_assert_eq "$out" "sprints/demo.md" "pitch_pr_path must print sprints/demo.md (got '$out')"

# ── pitch_pr_fetch writes the head blob and prints branch + sha ─────────────
ac_log "AC2: pitch_pr_fetch writes hello and prints architect/demo abc"
rc=0
out="$(pitch_pr_fetch 5 sprints/demo.md "$T/demo.md")" || rc=$?
ac_assert_eq "$rc" "0" "pitch_pr_fetch must return 0 (rc=$rc)"
ac_assert_eq "$out" "architect/demo abc" \
  "pitch_pr_fetch must print 'architect/demo abc' (got '$out')"
[ -f "$T/demo.md" ] || ac_fail "pitch_pr_fetch must create $T/demo.md"
ac_assert_eq "$(cat "$T/demo.md")" "hello" \
  "the fetched file must hold hello (got $(cat "$T/demo.md" | od -An -tx1))"

# ── pitch_pr_put commits that file; one payload, no author ──────────────────
ac_log "AC3: pitch_pr_put prints c1 and sends the file with no author"
rc=0
out="$(pitch_pr_put architect/demo sprints/demo.md abc "$T/demo.md" "architect: draft")" || rc=$?
ac_assert_eq "$rc" "0" "pitch_pr_put must return 0 (rc=$rc)"
ac_assert_eq "$out" "c1" "pitch_pr_put must print c1 (got '$out')"

put_count="$(jq -s '[.[] | select(index("PUT"))] | length' "$CURL_LOG")"
ac_assert_eq "$put_count" "1" "there must be exactly one PUT (got $put_count)"
payload="$(jq -s -r '[.[] | select(index("PUT"))][0] | map(select(startswith("{")))[0]' "$CURL_LOG")"
[ -n "$payload" ] && [ "$payload" != "null" ] || ac_fail "the PUT must carry a JSON body"
ac_assert_eq "$(printf '%s' "$payload" | jq -r '.branch')" "architect/demo" \
  "PUT .branch must be architect/demo"
ac_assert_eq "$(printf '%s' "$payload" | jq -r '.sha')" "abc" \
  "PUT .sha must be abc"
ac_assert_eq "$(printf '%s' "$payload" | jq -r '.message')" "architect: draft" \
  "PUT .message must be the given message"
ac_assert_eq "$(printf '%s' "$payload" | jq -r '.content')" "$(base64 -w0 < "$T/demo.md")" \
  "PUT .content must be the base64 of the file"
printf '%s' "$payload" | jq -e 'has("author") | not' >/dev/null \
  || ac_fail "PUT payload must have no author key (got $payload)"
printf '%s' "$payload" | jq -e 'has("committer") | not' >/dev/null \
  || ac_fail "PUT payload must have no committer key (got $payload)"

# Each call used the ops-repo prefix and the token header the lib promises.
call_n="$(jq -s 'length' "$CURL_LOG")"
ac_assert_eq "$call_n" "4" "happy path must make 4 forge calls (got $call_n)"
jq -s -e --arg base "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}" --arg auth "Authorization: token ${FORGE_TOKEN}" '
  all(.[]; (index($auth) != null) and (index("-sf") != null) and any(.[]; startswith($base)))
' "$CURL_LOG" >/dev/null \
  || ac_fail "every call must be curl -sf with the token header under the ops repo"

# ── AC_FAIL=1: each function returns 1; fetch creates no DEST ───────────────
ac_log "AC4: AC_FAIL=1 makes each function return 1 and creates no DEST"
fail_dest="$T/absent.md"
[ ! -e "$fail_dest" ] || ac_fail "precondition: $fail_dest must not exist"

rc=0
out="$(AC_FAIL=1 pitch_pr_path 5)" || rc=$?
ac_assert_eq "$rc" "1" "pitch_pr_path must return 1 when curl fails (rc=$rc, out='$out')"
ac_assert_eq "$out" "" "pitch_pr_path must print nothing on failure"

rc=0
out="$(AC_FAIL=1 pitch_pr_fetch 5 sprints/demo.md "$fail_dest")" || rc=$?
ac_assert_eq "$rc" "1" "pitch_pr_fetch must return 1 when curl fails (rc=$rc, out='$out')"
ac_assert_eq "$out" "" "pitch_pr_fetch must print nothing on failure"
[ ! -e "$fail_dest" ] || ac_fail "pitch_pr_fetch must create no DEST when a call fails"

rc=0
out="$(AC_FAIL=1 pitch_pr_put architect/demo sprints/demo.md abc "$T/demo.md" "architect: draft")" || rc=$?
ac_assert_eq "$rc" "1" "pitch_pr_put must return 1 when curl fails (rc=$rc, out='$out')"
ac_assert_eq "$out" "" "pitch_pr_put must print nothing on failure"

ac_pass
