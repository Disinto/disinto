#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1976.sh
#
# Issue #1976: open at most one planner pitch.
#
# planner/pitch-open.sh (sourced; does not source lib/env.sh) sources
# lib/pitch.sh. planner_pitch_pending lists open ops pulls and prints the
# number of planner-bot's open `architect:` PR, or nothing. planner_pitch_open
# refuses a filer block, a half-specified probe, and a second pitch, and
# otherwise creates planner/pitch-<slug>, puts sprints/<slug>.md (and an
# optional probes/<name>.sh), and posts one pull.
#
# The curl stub is a shell function (it takes precedence over the binary).
# It logs its arguments and answers by URL. Hermetic: no network, no live box.
#
# Acceptance: `bash tests/acceptance/issue-1976.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq base64 grep
ac_assert_file "$REPO_ROOT/planner/pitch-open.sh" "planner/pitch-open.sh is missing"
ac_assert_file "$REPO_ROOT/lib/pitch.sh" "lib/pitch.sh is missing"
ac_assert_file "$REPO_ROOT/planner/AGENTS.md" "planner/AGENTS.md is missing"

# ── static: bash -n, sources pitch.sh, not env.sh, docs bullet ───────────────
ac_log "static: bash -n, sources lib/pitch.sh, not lib/env.sh"
bash -n "$REPO_ROOT/planner/pitch-open.sh"
if grep -E '^[[:space:]]*(source|\.)[[:space:]]' "$REPO_ROOT/planner/pitch-open.sh" | grep -q 'env.sh'; then
  ac_fail "planner/pitch-open.sh must not source lib/env.sh"
fi
grep -q 'lib/pitch.sh' "$REPO_ROOT/planner/pitch-open.sh" \
  || ac_fail "planner/pitch-open.sh must source lib/pitch.sh"

ladder_line="$(grep -n 'planner/ladder.sh' "$REPO_ROOT/planner/AGENTS.md" | head -n 1 | cut -d: -f1)"
open_line="$(grep -n 'planner/pitch-open.sh' "$REPO_ROOT/planner/AGENTS.md" | head -n 1 | cut -d: -f1)"
prereq_line="$(grep -n 'Prerequisite tree: versioned constraint' "$REPO_ROOT/planner/AGENTS.md" | head -n 1 | cut -d: -f1)"
[ -n "$ladder_line" ] || ac_fail "planner/AGENTS.md must keep the ladder.sh bullet"
[ -n "$open_line" ] || ac_fail "planner/AGENTS.md must document planner/pitch-open.sh"
[ -n "$prereq_line" ] || ac_fail "planner/AGENTS.md must keep the prerequisites bullet"
[ "$open_line" -gt "$ladder_line" ] \
  || ac_fail "planner/pitch-open.sh bullet must follow the ladder.sh bullet"
[ "$prereq_line" -gt "$open_line" ] \
  || ac_fail "prerequisites bullet must follow the pitch-open.sh bullet"
grep -qF 'planner_pitch_open' "$REPO_ROOT/planner/AGENTS.md" \
  || ac_fail "planner/AGENTS.md must name planner_pitch_open"
grep -qF 'No caller yet.' "$REPO_ROOT/planner/AGENTS.md" \
  || ac_fail "planner/AGENTS.md must say the opener has no caller yet"

T="$(mktemp -d)"
CURL_LOG="$T/curl.jsonl"
trap 'rm -rf "$T"' EXIT

export FORGE_API_BASE="https://forge.example/api/v1"
export FORGE_OPS_REPO="o/ops"
export FORGE_TOKEN="stub"
unset PRIMARY_BRANCH PLANNER_LOGIN || true

API="${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}"
PULLS_LIST="${API}/pulls?state=open&limit=50"
BRANCHES="${API}/branches"
PULLS_POST="${API}/pulls"

# curl — log every argument, then answer by URL.
curl() {
  jq -nc --args '$ARGS.positional' -- "$@" >>"$CURL_LOG"
  local url="" method="GET" prev="" arg
  for arg in "$@"; do
    case "$prev" in
      -X|--request) method="$arg" ;;
    esac
    case "$arg" in
      -X[A-Z]*) method="${arg#-X}" ;;
      http://*|https://*) url="$arg" ;;
    esac
    prev="$arg"
  done

  if [ "$url" = "$PULLS_LIST" ]; then
    if [ "${STUB_PULLS_FAIL:-}" = 1 ]; then
      return 22
    fi
    printf '%s' "${STUB_PULLS_BODY:-[]}"
    return 0
  fi
  if [ "$url" = "$BRANCHES" ] && [ "$method" = "POST" ]; then
    if [ "${STUB_BRANCH_FAIL:-}" = 1 ]; then
      return 22
    fi
    printf '%s' '{"name":"planner/pitch-sense"}'
    return 0
  fi
  if [ "$url" = "${BRANCHES}/planner/pitch-sense" ] && [ "$method" = "GET" ]; then
    if [ "${STUB_BRANCH_EXISTS:-}" = 1 ]; then
      printf '%s' '{"name":"planner/pitch-sense"}'
      return 0
    fi
    echo "curl stub: branch GET not configured for ${url}" >&2
    return 22
  fi
  if [ "$method" = "GET" ] && [[ "$url" == *"/contents/"* ]]; then
    if [ -n "${STUB_CONTENT_SHA:-}" ]; then
      printf '{"sha":"%s"}' "$STUB_CONTENT_SHA"
      return 0
    fi
    return 22
  fi
  if [ "$method" = "PUT" ] && [[ "$url" == *"/contents/"* ]]; then
    if [ "${STUB_PROBE_PUT_FAIL:-}" = 1 ] && [[ "$url" == *"/contents/probes/"* ]]; then
      return 22
    fi
    printf '%s' '{"commit":{"sha":"c1"}}'
    return 0
  fi
  if [ "$url" = "$PULLS_POST" ] && [ "$method" = "POST" ]; then
    printf '%s' '{"number":7}'
    return 0
  fi
  echo "curl stub: no answer for ${method} ${url:-<no url>}" >&2
  return 22
}

# shellcheck disable=SC1091
source "$REPO_ROOT/planner/pitch-open.sh"

# calls_json — one object per logged curl: method, url, data.
calls_json() {
  jq -s '
    map(
      . as $a
      | reduce range(0; ($a | length)) as $i ({method:"GET", url:"", data:""};
          if $a[$i] == "-X" or $a[$i] == "--request" then .method = $a[$i+1]
          elif ($a[$i] | test("^-X[A-Z]+$")) then .method = $a[$i][2:]
          elif $a[$i] == "-d" or $a[$i] == "--data" then .data = $a[$i+1]
          elif ($a[$i] | test("^https?://")) then .url = $a[$i]
          else . end)
    )
  ' "$CURL_LOG"
}

# reset_stub — empty the log and the per-case switches.
reset_stub() {
  : >"$CURL_LOG"
  unset STUB_PULLS_FAIL STUB_BRANCH_FAIL STUB_BRANCH_EXISTS STUB_CONTENT_SHA STUB_PROBE_PUT_FAIL || true
  STUB_PULLS_BODY='[]'
}

# run_open [args...] — planner_pitch_open; stdout -> $OUT, stderr -> $ERR, rc -> $RC.
run_open() {
  RC=0 OUT="" ERR=""
  OUT="$(planner_pitch_open "$@" 2>"$T/err")" || RC=$?
  ERR="$(cat "$T/err")"
}

# assert_no_calls REASON — the function must not have reached the forge.
assert_no_calls() {
  ac_assert_eq "$(jq -s 'length' "$CURL_LOG")" "0" "$1"
}

# assert_no_put REASON — a pulls GET may have happened; a PUT must not.
assert_no_put() {
  calls_json | jq -e 'all(.[]; .method != "PUT")' >/dev/null \
    || ac_fail "$1"
}

cat >"$T/sense.md" <<'EOF'
# Sprint: Sense

<!-- sprint:begin -->
class: internal
effect: none
expect: >= 1
soak: 7d
<!-- sprint:end -->

## What this enables

The factory can sense `can-sense` without expanding $HOME.
EOF

cat >"$T/filer.md" <<'EOF'
# Sprint: Sense

<!-- sprint:begin -->
class: internal
effect: none
expect: >= 1
soak: 7d
<!-- sprint:end -->

<!-- filer:begin -->
- id: do-not-file
EOF

printf 'no sprint block\n' >"$T/nosprint.md"
printf '#!/bin/sh\necho 1\n' >"$T/can-sense.sh"
: >"$T/empty.sh"

# ── AC: an open architect PR by planner-bot is a no-op, and does not PUT ─────
ac_log "AC1: open architect: Sense by planner-bot prints nothing, returns 0, no PUT"
reset_stub
STUB_PULLS_BODY='[{"number":1,"title":"chore: other","user":{"login":"planner-bot"}},{"number":9,"title":"architect: Sense","user":{"login":"planner-bot"}}]'
run_open Sense sense "$T/sense.md"
ac_assert_eq "$RC" "0" "an open planner pitch must return 0 (rc=$RC, err=$ERR)"
ac_assert_eq "$OUT" "" "an open planner pitch must print nothing (got '$OUT')"
assert_no_put "an open planner pitch must not PUT"
calls_json | jq -e --arg url "$PULLS_LIST" '
  length == 1 and .[0].method == "GET" and .[0].url == $url
' >/dev/null || ac_fail "an open planner pitch must only GET the open pulls list"

# ── AC: empty pulls list puts the sprint file and posts the pull ─────────────
ac_log "AC2: empty pulls list PUTs sprints/sense.md and POSTs architect: Sense"
reset_stub
run_open Sense sense "$T/sense.md"
ac_assert_eq "$RC" "0" "opening a pitch must return 0 (rc=$RC, err=$ERR)"
ac_assert_eq "$OUT" "7" "opening a pitch must print the PR number (got '$OUT')"
[ -z "$ERR" ] || ac_fail "opening a pitch must not print stderr (got: $ERR)"

calls_json >"$T/calls.json"
jq -e --arg url "${API}/contents/sprints/sense.md" '
  map(select(.method == "PUT" and .url == $url)) | length == 1
' "$T/calls.json" >/dev/null \
  || ac_fail "must PUT sprints/sense.md exactly once"
put_payload="$(jq -r --arg url "${API}/contents/sprints/sense.md" '
  map(select(.method == "PUT" and .url == $url))[0].data
' "$T/calls.json")"
ac_assert_eq "$(printf '%s' "$put_payload" | jq -r '.branch')" "planner/pitch-sense" \
  "sprint PUT .branch must be planner/pitch-sense"
ac_assert_eq "$(printf '%s' "$put_payload" | jq -r '.message')" "architect: Sense" \
  "sprint PUT .message must be architect: Sense"
ac_assert_eq "$(printf '%s' "$put_payload" | jq -r '.content')" "$(base64 -w0 < "$T/sense.md")" \
  "sprint PUT .content must be the base64 of the file"
printf '%s' "$put_payload" | jq -e 'has("author") | not' >/dev/null \
  || ac_fail "sprint PUT must have no author key"
printf '%s' "$put_payload" | jq -e 'has("committer") | not' >/dev/null \
  || ac_fail "sprint PUT must have no committer key"
printf '%s' "$put_payload" | jq -e 'has("sha") | not' >/dev/null \
  || ac_fail "sprint PUT must omit sha when the contents GET returns none"

jq -e --arg url "$BRANCHES" '
  map(select(.method == "POST" and .url == $url)) as $posts
  | ($posts | length) == 1
    and ($posts[0].data | fromjson | .new_branch_name == "planner/pitch-sense")
    and ($posts[0].data | fromjson | .old_branch_name == "main")
' "$T/calls.json" >/dev/null \
  || ac_fail "branch create must POST planner/pitch-sense from main"

jq -e --arg url "$PULLS_POST" --rawfile body "$T/sense.md" '
  map(select(.method == "POST" and .url == $url)) as $posts
  | ($posts | length) == 1
    and ($posts[0].data | fromjson | .title == "architect: Sense")
    and ($posts[0].data | fromjson | .head == "planner/pitch-sense")
    and ($posts[0].data | fromjson | .base == "main")
    and ($posts[0].data | fromjson | .body == $body)
' "$T/calls.json" >/dev/null \
  || ac_fail "pull POST must be titled architect: Sense with the file as its body"

jq -s -e --arg base "$API" --arg auth "Authorization: token ${FORGE_TOKEN}" '
  all(.[]; (index($auth) != null) and (index("-sf") != null) and any(.[]; startswith($base)))
' "$CURL_LOG" >/dev/null \
  || ac_fail "every forge call must be curl -sf with the token header under the ops repo"

# ── AC: filer:begin is refused before any forge call ─────────────────────────
ac_log "AC3: a file containing filer:begin returns 1 and makes no forge call"
reset_stub
run_open Sense sense "$T/filer.md"
ac_assert_eq "$RC" "1" "filer:begin must return 1 (rc=$RC, out='$OUT')"
ac_assert_eq "$OUT" "" "filer:begin must print nothing (got '$OUT')"
assert_no_calls "filer:begin must make no forge call"

# ── AC: a failed pulls GET returns 1 and does not PUT ────────────────────────
ac_log "AC4: a failed pulls GET returns 1 and does not PUT"
reset_stub
STUB_PULLS_FAIL=1
run_open Sense sense "$T/sense.md"
ac_assert_eq "$RC" "1" "a failed pulls GET must return 1 (rc=$RC, out='$OUT')"
ac_assert_eq "$OUT" "" "a failed pulls GET must print nothing (got '$OUT')"
assert_no_put "a failed pulls GET must not PUT"

# ── AC: probe file and dest are PUT on the pitch branch before the pull ─────
ac_log "AC5: probes/can-sense.sh is PUT on planner/pitch-sense before the pull"
reset_stub
run_open Sense sense "$T/sense.md" "$T/can-sense.sh" probes/can-sense.sh
ac_assert_eq "$RC" "0" "a probe pitch must return 0 (rc=$RC, err=$ERR)"
ac_assert_eq "$OUT" "7" "a probe pitch must print the pull number (got '$OUT')"
calls_json >"$T/calls.json"
probe_url="${API}/contents/probes/can-sense.sh"
jq -e --arg probe "$probe_url" --arg pulls "$PULLS_POST" '
  (map(.method + " " + .url) | index("PUT " + $probe)) as $put
  | (map(.method + " " + .url) | index("POST " + $pulls)) as $post
  | $put != null and $post != null and $put < $post
' "$T/calls.json" >/dev/null \
  || ac_fail "probe PUT must happen on the pitch branch before the pulls POST"
probe_payload="$(jq -r --arg url "$probe_url" '
  map(select(.method == "PUT" and .url == $url))[0].data
' "$T/calls.json")"
ac_assert_eq "$(printf '%s' "$probe_payload" | jq -r '.branch')" "planner/pitch-sense" \
  "probe PUT .branch must be planner/pitch-sense"
ac_assert_eq "$(printf '%s' "$probe_payload" | jq -r '.message')" "architect: Sense" \
  "probe PUT .message must be architect: Sense"
ac_assert_eq "$(printf '%s' "$probe_payload" | jq -r '.content')" "$(base64 -w0 < "$T/can-sense.sh")" \
  "probe PUT .content must be the base64 of the probe file"
printf '%s' "$probe_payload" | jq -e 'has("author") | not' >/dev/null \
  || ac_fail "probe PUT must have no author key"
printf '%s' "$probe_payload" | jq -e 'has("committer") | not' >/dev/null \
  || ac_fail "probe PUT must have no committer key"

# ── AC: a probe file and no dest is refused before any forge call ────────────
ac_log "AC6: a probe file and no dest returns 1 and makes no forge call"
reset_stub
run_open Sense sense "$T/sense.md" "$T/can-sense.sh"
ac_assert_eq "$RC" "1" "a probe without a dest must return 1 (rc=$RC, out='$OUT')"
ac_assert_eq "$OUT" "" "a probe without a dest must print nothing (got '$OUT')"
assert_no_calls "a probe without a dest must make no forge call"

# ── a full page, a non-array, and someone else's architect PR ────────────────
ac_log "a full pulls page returns 1 and does not PUT"
reset_stub
STUB_PULLS_BODY="$(jq -nc '[range(50) | {number: ., title: "chore: x", user: {login: "planner-bot"}}]')"
run_open Sense sense "$T/sense.md"
ac_assert_eq "$RC" "1" "a 50-item pulls page must return 1 (rc=$RC, out='$OUT')"
ac_assert_eq "$OUT" "" "a 50-item pulls page must print nothing"
assert_no_put "a 50-item pulls page must not PUT"

ac_log "a non-array pulls body returns 1 and does not PUT"
reset_stub
STUB_PULLS_BODY='{"message":"no"}'
run_open Sense sense "$T/sense.md"
ac_assert_eq "$RC" "1" "a non-array pulls body must return 1 (rc=$RC)"
assert_no_put "a non-array pulls body must not PUT"

ac_log "an architect PR by another login does not block the open"
reset_stub
STUB_PULLS_BODY='[{"number":3,"title":"architect: Sense","user":{"login":"architect-bot"}}]'
run_open Sense sense "$T/sense.md"
ac_assert_eq "$RC" "0" "another login's architect PR must not block (rc=$RC, err=$ERR)"
ac_assert_eq "$OUT" "7" "another login's architect PR must still open a pitch (got '$OUT')"

# ── sha is included only when the contents GET returns one ───────────────────
ac_log "a contents GET sha is sent on the PUT and omitted otherwise"
reset_stub
STUB_CONTENT_SHA="blobsha"
run_open Sense sense "$T/sense.md"
ac_assert_eq "$RC" "0" "a pitch with an existing blob must return 0 (rc=$RC, err=$ERR)"
calls_json | jq -e --arg url "${API}/contents/sprints/sense.md" '
  map(select(.method == "PUT" and .url == $url))[0].data | fromjson | .sha == "blobsha"
' >/dev/null || ac_fail "PUT must include sha when the contents GET returns one"

# ── a failed branch create is ignored only when a later GET shows it ─────────
ac_log "a failed branch create continues when a later GET shows the branch"
reset_stub
STUB_BRANCH_FAIL=1
STUB_BRANCH_EXISTS=1
run_open Sense sense "$T/sense.md"
ac_assert_eq "$RC" "0" "an existing pitch branch must still open (rc=$RC, err=$ERR)"
ac_assert_eq "$OUT" "7" "an existing pitch branch must still print the PR number (got '$OUT')"

ac_log "a failed branch create with no branch returns 1 and does not PUT"
reset_stub
STUB_BRANCH_FAIL=1
run_open Sense sense "$T/sense.md"
ac_assert_eq "$RC" "1" "a missing pitch branch must return 1 (rc=$RC, out='$OUT')"
ac_assert_eq "$OUT" "" "a missing pitch branch must print nothing"
assert_no_put "a missing pitch branch must not PUT"
calls_json | jq -e --arg url "$PULLS_POST" 'all(.[]; .url != $url)' >/dev/null \
  || ac_fail "a missing pitch branch must not POST the pull"

# ── bad probe dest, empty probe, missing sprint block: no forge call ─────────
ac_log "a bad probe dest, an empty probe, and a missing sprint block make no forge call"
reset_stub
run_open Sense sense "$T/sense.md" "$T/can-sense.sh" 'probes/can..sense.sh'
ac_assert_eq "$RC" "1" "a probe dest containing .. must return 1 (rc=$RC)"
assert_no_calls "a probe dest containing .. must make no forge call"

reset_stub
run_open Sense sense "$T/sense.md" "$T/can-sense.sh" 'scripts/can-sense.sh'
ac_assert_eq "$RC" "1" "a probe dest outside probes/ must return 1 (rc=$RC)"
assert_no_calls "a probe dest outside probes/ must make no forge call"

reset_stub
run_open Sense sense "$T/sense.md" "$T/empty.sh" probes/can-sense.sh
ac_assert_eq "$RC" "1" "an empty probe file must return 1 (rc=$RC)"
assert_no_calls "an empty probe file must make no forge call"

reset_stub
run_open Sense sense "$T/nosprint.md"
ac_assert_eq "$RC" "1" "a file with no sprint block must return 1 (rc=$RC)"
assert_no_calls "a file with no sprint block must make no forge call"

reset_stub
run_open Sense sense "$T/missing.md"
ac_assert_eq "$RC" "1" "a missing file must return 1 (rc=$RC)"
assert_no_calls "a missing file must make no forge call"

# ── a failed probe PUT does not POST the pull ────────────────────────────────
ac_log "a failed probe PUT returns 1 and does not POST the pull"
reset_stub
STUB_PROBE_PUT_FAIL=1
run_open Sense sense "$T/sense.md" "$T/can-sense.sh" probes/can-sense.sh
ac_assert_eq "$RC" "1" "a failed probe PUT must return 1 (rc=$RC, out='$OUT')"
ac_assert_eq "$OUT" "" "a failed probe PUT must print nothing"
calls_json | jq -e --arg url "$PULLS_POST" 'all(.[]; .url != $url)' >/dev/null \
  || ac_fail "a failed probe PUT must not POST the pull"

# ── PRIMARY_BRANCH is the base when set ──────────────────────────────────────
ac_log "PRIMARY_BRANCH is the branch base and the pull base"
reset_stub
PRIMARY_BRANCH=trunk
run_open Sense sense "$T/sense.md"
ac_assert_eq "$RC" "0" "a custom primary branch must still open (rc=$RC, err=$ERR)"
calls_json | jq -e --arg branches "$BRANCHES" --arg pulls "$PULLS_POST" '
  (map(select(.method == "POST" and .url == $branches))[0].data | fromjson | .old_branch_name) == "trunk"
  and (map(select(.method == "POST" and .url == $pulls))[0].data | fromjson | .base) == "trunk"
' >/dev/null || ac_fail "PRIMARY_BRANCH must be the branch old name and the pull base"
unset PRIMARY_BRANCH

# ── PLANNER_LOGIN selects whose open architect PR blocks ─────────────────────
ac_log "PLANNER_LOGIN names the login whose open architect PR blocks"
reset_stub
PLANNER_LOGIN=custom-bot
STUB_PULLS_BODY='[{"number":4,"title":"architect: Sense","user":{"login":"custom-bot"}}]'
run_open Sense sense "$T/sense.md"
ac_assert_eq "$RC" "0" "PLANNER_LOGIN's open pitch must return 0 (rc=$RC)"
ac_assert_eq "$OUT" "" "PLANNER_LOGIN's open pitch must print nothing (got '$OUT')"
assert_no_put "PLANNER_LOGIN's open pitch must not PUT"
unset PLANNER_LOGIN

ac_pass
