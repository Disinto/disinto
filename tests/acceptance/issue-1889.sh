#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1889.sh
#
# Issue #1889: a merged pitch gets its sprint milestone on the project repo.
#
# A sprint is a Forgejo milestone on the project repo. lib/sprint-milestone.sh
# creates that milestone exactly once from the pitch file — title from the
# first `# ` heading (with `# ` and any leading `Sprint: ` stripped, the slug
# otherwise), description from the purpose paragraph, the sprint block and the
# marker `<!-- pitch: sprints/<slug>.md -->` — and finds it again on later
# calls by the marker. The marker is an HTML comment, so readers of the
# description (dev-poll, tools/sprint-outcomes.sh) are unaffected.
#
# Function (sourced; no callers yet — #1892 reads it):
#   sprint_milestone_ensure FILE
#     -> the id of FILE's milestone. When no listed milestone's description
#        contains the marker, the milestone is created (POST
#        ${FORGE_API}/milestones, Content-Type application/json, body built
#        with jq) and its id printed; when one does, the existing id is
#        printed and nothing is created. Returns 1, prints nothing and creates
#        nothing when FILE has no valid sprint block, a list call fails, a
#        page is not a JSON array, or the POST fails or carries no `.id`.
#
# Setup (per the issue): a stub `curl` first on PATH that logs its arguments,
# FORGE_API=https://forge.example/api/v1/repos/o/p, FORGE_FILER_TOKEN=stub,
# and a fixture sprints/demo.md whose heading is `# Sprint: Demo sprint`.
#
# Hermetic: no network, no live box.
#
# Acceptance: `bash tests/acceptance/issue-1889.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq curl grep
ac_assert_file "$REPO_ROOT/lib/sprint-milestone.sh" "lib/sprint-milestone.sh is missing"
ac_assert_file "$REPO_ROOT/lib/pitch.sh" "lib/pitch.sh is missing"

# Docs the issue requires, so a later edit cannot drop the row or the
# re-wiring of the pitch row.
AGENTS="$REPO_ROOT/lib/AGENTS.md"
# shellcheck disable=SC2016  # backticks are literal markdown in the required row
PITCH_LINE="$(grep -nF 'lib/pitch.sh` | Reads a pitch file' "$AGENTS" | head -n1 | cut -d: -f1)"
# shellcheck disable=SC2016  # backticks are literal markdown in the required row
MILESTONE_LINE="$(grep -nF 'lib/sprint-milestone.sh` | `sprint_milestone_ensure FILE' "$AGENTS" | head -n1 | cut -d: -f1)"
[ -n "$PITCH_LINE" ] || ac_fail "lib/AGENTS.md must keep the pitch.sh row (#1887)"
[ -n "$MILESTONE_LINE" ] || ac_fail "lib/AGENTS.md must add the sprint-milestone.sh row (#1889)"
[ "$MILESTONE_LINE" -eq "$((PITCH_LINE + 1))" ] \
  || ac_fail "lib/AGENTS.md: the sprint-milestone.sh row (#1889) must come right after the pitch.sh row (#1887) (got lines $PITCH_LINE/$MILESTONE_LINE)"
MILESTONE_ROW="$(sed -n "${MILESTONE_LINE}p" "$AGENTS")"
printf '%s\n' "$MILESTONE_ROW" | grep -qF '<!-- pitch: sprints/<slug>.md -->' \
  || ac_fail "lib/AGENTS.md: the sprint-milestone.sh row must name the marker line"
PITCH_ROW="$(sed -n "${PITCH_LINE}p" "$AGENTS")"
# shellcheck disable=SC2016  # backticks are literal markdown in the required row
case "$PITCH_ROW" in
  *'| `lib/sprint-milestone.sh` (#1889) |'*) ;;
  *) ac_fail "lib/AGENTS.md: the pitch.sh row must now be sourced by lib/sprint-milestone.sh (#1889)" ;;
esac
ac_log "docs OK"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Stub curl: logs its arguments to $CURL_LOG, then answers the milestones API
# with $LIST_BODY (GET) or $CREATE_BODY (POST to /milestones); $FAIL_ALL=1
# exits 22 on every call. POST payloads are saved to $CURL_POST (last wins).
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
export CURL_LOG="$WORK/curl.log"
export CURL_POST="$WORK/post.json"
: >"$CURL_LOG"

cat > "$STUB_BIN/curl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${CURL_LOG:?}"
if [ -n "${FAIL_ALL:-}" ]; then
  exit 22
fi
url="" data="" method=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -d|--data) shift; data="$1" ;;
    -X) shift; method="$1" ;;
    http://*|https://*) url="$1" ;;
  esac
  shift
done
if [ "$method" = POST ]; then
  [[ $url == */milestones ]] || exit 22
  printf '%s\n' "$data" > "${CURL_POST:?}"
  if [ -n "${CREATE_BODY:-}" ]; then
    printf '%s\n' "$CREATE_BODY"
  else
    printf '%s\n' '{"id":9}'
  fi
elif [ "$method" = GET ]; then
  [[ $url == */milestones* ]] || exit 22
  printf '%s\n' "${LIST_BODY:-[]}"
else
  exit 22
fi
STUB
chmod +x "$STUB_BIN/curl"
export PATH="$STUB_BIN:$PATH"
export FORGE_API="https://forge.example/api/v1/repos/o/p"
export FORGE_FILER_TOKEN="stub"
export CREATE_BODY='{"id":9}'
export LIST_BODY='[]'
export FAIL_ALL=''

# Fixture sprints/demo.md, heading `# Sprint: Demo sprint`.
mkdir -p "$WORK/sprints"
cat > "$WORK/sprints/demo.md" <<'EOF'
# Sprint: Demo sprint

## What this enables
The demo probe runs on the live box.
It measures the smoke window.

## Sub-issues

<!-- sprint:begin -->
class: internal
effect: probes/demo.sh
expect: >= 1
soak: 14d
<!-- sprint:end -->
EOF
FIXTURE="$WORK/sprints/demo.md"

# shellcheck source=../../lib/sprint-milestone.sh
source "$REPO_ROOT/lib/sprint-milestone.sh"

# ── Helpers ──────────────────────────────────────────────────────────────────
reset_stub() {
  : >"$CURL_LOG"
  rm -f "$CURL_POST"
}

# Count of log lines containing PAT (grep -c prints 0 on a miss and exits 1;
# `|| true` keeps that harmless under set -e).
count_log() {
  grep -c -- "$1" "$CURL_LOG" || true
}

# ── AC1: empty list -> one POST to /milestones, prints 9 ────────────────────
ac_log "AC1: empty list creates the milestone (one POST, prints 9)"
reset_stub
LIST_BODY='[]'
FAIL_ALL=''
rc=0
out="$(sprint_milestone_ensure "$FIXTURE")" || rc=$?
ac_assert_eq "$rc" "0" "AC1 must return 0 when it creates the milestone (rc=$rc)"
ac_assert_eq "$out" "9" "AC1 must print the created milestone id 9 (got '$out')"
ac_assert_eq "$(count_log ' -X POST')" "1" "AC1 must make exactly one POST (got $(count_log ' -X POST'))"
ac_assert_eq "$(count_log ' -H Authorization: token')" "2" "AC1 must make one list GET and one POST (got $(count_log ' -H Authorization: token'))"
post_line="$(grep -F ' -X POST' "$CURL_LOG" | head -n1)"
printf '%s' "$post_line" | grep -qF "$FORGE_API/milestones" \
  || ac_fail "AC1 must POST to ${FORGE_API}/milestones (got: $post_line)"
printf '%s' "$post_line" | grep -qF 'Content-Type: application/json' \
  || ac_fail "AC1 must set Content-Type: application/json"
[ -s "$CURL_POST" ] || ac_fail "AC1 must save the POST payload"
ac_assert_eq "$(jq -r .title "$CURL_POST")" "Demo sprint" \
  "AC1 title must be 'Demo sprint' (got '$(jq -r .title "$CURL_POST")')"
desc="$(jq -r .description "$CURL_POST")"
case "$desc" in
  "The demo probe runs on the live box."*) ;;
  *) ac_fail "AC1 description must start with the purpose paragraph (got: ${desc:0:80}...)" ;;
esac
grep -qF 'class: internal' "$CURL_POST" \
  || ac_fail "AC1 description must contain 'class: internal'"
grep -qF '<!-- pitch: sprints/demo.md -->' "$CURL_POST" \
  || ac_fail "AC1 description must contain '<!-- pitch: sprints/demo.md -->'"
expected="$(printf '%s\n' \
  'The demo probe runs on the live box.' \
  'It measures the smoke window.' \
  '' \
  'class: internal' \
  'effect: probes/demo.sh' \
  'expect: >= 1' \
  'soak: 14d' \
  '' \
  '<!-- pitch: sprints/demo.md -->')"
ac_assert_eq "$desc" "$expected" "AC1 description must be purpose, blank line, block, blank line, marker"
ac_log "AC1 OK"

# ── AC2: a listed milestone carrying the marker -> print its id, no POST ───
ac_log "AC2: a matching listed milestone is returned without a POST"
reset_stub
LIST_BODY='[{"id":4,"description":"x\n<!-- pitch: sprints/demo.md -->"}]'
FAIL_ALL=''
rc=0
out="$(sprint_milestone_ensure "$FIXTURE")" || rc=$?
ac_assert_eq "$rc" "0" "AC2 must return 0 when a matching milestone exists (rc=$rc)"
ac_assert_eq "$out" "4" "AC2 must print the existing milestone id 4 (got '$out')"
ac_assert_eq "$(count_log ' -X POST')" "0" "AC2 must make no POST"
ac_log "AC2 OK"

# ── AC3: no sprint block -> rc 1, nothing printed, no curl at all ───────────
cat > "$WORK/bad.md" <<'EOF'
# Pitch: no block

## What this enables
This pitch carries no sprint block.

## Sub-issues

<!-- filer:begin -->
- id: a
  title: "alpha"
  labels: [backlog]
<!-- filer:end -->
EOF
ac_log "AC3: a fixture without a sprint block returns 1, prints nothing, no curl"
reset_stub
LIST_BODY='[]'
FAIL_ALL=''
rc=0
out="$(sprint_milestone_ensure "$WORK/bad.md")" || rc=$?
ac_assert_eq "$rc" "1" "AC3 must return 1 for a pitch with no sprint block (rc=$rc)"
[ -z "$out" ] || ac_fail "AC3 must print nothing (got '$out')"
ac_assert_eq "$(wc -l <"$CURL_LOG" || true)" "0" \
  "AC3 must make no curl call (got $(wc -l <"$CURL_LOG" || true))"
ac_log "AC3 OK"

# ── AC4: a failing list call -> rc 1, no POST ───────────────────────────────
ac_log "AC4: a failing list call returns 1 and makes no POST"
reset_stub
LIST_BODY='[]'
FAIL_ALL=1
rc=0
out="$(sprint_milestone_ensure "$FIXTURE")" || rc=$?
ac_assert_eq "$rc" "1" "AC4 must return 1 when the list call fails (rc=$rc)"
[ -z "$out" ] || ac_fail "AC4 must print nothing (got '$out')"
ac_assert_eq "$(wc -l <"$CURL_LOG" || true)" "1" \
  "AC4 must make only the failing list call (got $(wc -l <"$CURL_LOG" || true))"
ac_assert_eq "$(count_log ' -X POST')" "0" "AC4 must make no POST"
ac_log "AC4 OK"

ac_pass
