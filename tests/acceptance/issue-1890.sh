#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1890.sh
#
# Issue #1890: file_subissues files a sprint's sub-issues into its milestone.
# With a milestone id, each new issue is posted into that milestone and the
# marker is <!-- decomposed-from: milestone:<id>, sprint: <slug>, id: <id> -->.
# No vision issue is read or labelled. Without a milestone, a pitch that has
# no vision issue still fails and posts nothing.
#
# Hermetic: no network, no live box. forge_api_all and curl are stubs.
#
# Acceptance: `bash tests/acceptance/issue-1890.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq grep
ac_assert_file "$REPO_ROOT/lib/sprint-filer.sh" "lib/sprint-filer.sh is missing"

# Docs the issue requires, so a later edit cannot drop the sentences.
grep -qF 'No CI pipeline runs it: #779 removed the ops-filer pipeline.' \
  "$REPO_ROOT/lib/sprint-filer.sh" \
  || ac_fail "lib/sprint-filer.sh header must say no CI pipeline runs it (#779)"
grep -qF 'sprint-filer.sh <sprint-file.md> [MILESTONE]' \
  "$REPO_ROOT/lib/sprint-filer.sh" \
  || ac_fail "lib/sprint-filer.sh usage must accept [MILESTONE]"
grep -qF 'With a milestone id (`sprint-filer.sh <file> <milestone>`, #1890), each new issue is filed into that milestone, the marker is `<!-- decomposed-from: milestone:<id>, sprint: <slug>, id: <id> -->`, and no vision issue is read or labelled.' \
  "$REPO_ROOT/lib/AGENTS.md" \
  || ac_fail "lib/AGENTS.md must describe milestone filing (#1890)"
grep -qF 'A sub-issue filed with the sprint'"'"'s milestone carries `<!-- decomposed-from: milestone:<id>, sprint: <slug>, id: <id> -->` instead, and the vision steps below do not apply to it.' \
  "$REPO_ROOT/architect/AGENTS.md" \
  || ac_fail "architect/AGENTS.md must describe the milestone marker (#1890)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
POSTS="$WORK/posts"
PAYLOAD="$WORK/payload"
: >"$POSTS"

# Answers …/labels with the backlog label, answers a POST to …/issues with
# {"number":42}, and saves the -d payload. Every POST is one line in $POSTS.
cat > "$STUB_BIN/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
method="GET"
data=""
url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X)
      shift
      method="$1"
      ;;
    -d|--data)
      shift
      data="$1"
      ;;
    -H|--header)
      shift
      ;;
    -sf|-s|-f|--silent|--fail|--show-error)
      ;;
    http://*|https://*)
      url="$1"
      ;;
    *)
      ;;
  esac
  shift
done
if [ "$method" = "POST" ]; then
  printf '%s\n' "$url" >> "${CURL_POSTS:?}"
  printf '%s' "$data" > "${CURL_PAYLOAD:?}"
  printf '%s' '{"number":42}'
  exit 0
fi
case "$url" in
  */labels)
    printf '%s' '[{"id":3,"name":"backlog"}]'
    ;;
  *)
    printf '%s' '[]'
    ;;
esac
STUB
chmod +x "$STUB_BIN/curl"

export PATH="$STUB_BIN:$PATH"
export CURL_POSTS="$POSTS"
export CURL_PAYLOAD="$PAYLOAD"
export FACTORY_ROOT="$REPO_ROOT"
export FORGE_FILER_TOKEN="stub"
export FORGE_API="https://forge.example/api/v1/repos/o/p"
# shellcheck source=../../lib/sprint-filer.sh
source "$REPO_ROOT/lib/sprint-filer.sh"

# The test owns the issue listing. Defined after the source so it replaces
# whatever env.sh would have provided; sprint-filer skips env.sh when
# FACTORY_ROOT is set, so this is the only definition.
forge_api_all() { printf '%s' "$ISSUES_JSON"; }

FIXTURE="$WORK/fixture.md"
cat > "$FIXTURE" <<'EOF'
## Sub-issues

<!-- filer:begin -->
- id: a
  title: "alpha"
  labels: [backlog]
  body: |
    A sub-issue with no vision parent.
<!-- filer:end -->
EOF

# The fixture must not contain a #N, or the no-milestone path could succeed.
if grep -qE '#[0-9]+' "$FIXTURE"; then
  ac_fail "fixture.md must contain no #N"
fi

MARKER='<!-- decomposed-from: milestone:7, sprint: fixture, id: a -->'
ISSUES_JSON='[]'

reset_stub() {
  : >"$POSTS"
  rm -f "$PAYLOAD"
}

post_count() {
  if [ ! -s "$POSTS" ]; then
    printf '0'
    return 0
  fi
  grep -c . "$POSTS"
}

ac_log "AC1: file_subissues fixture.md 7 posts one issue into milestone 7"
reset_stub
ISSUES_JSON='[]'
rc=0
file_subissues "$FIXTURE" 7 || rc=$?
ac_assert_eq "$rc" "0" "file_subissues fixture.md 7 must return 0 (got $rc)"
ac_assert_eq "$(post_count)" "1" "milestone filing must make exactly one POST"
[ -s "$PAYLOAD" ] || ac_fail "milestone filing must save the POST payload"
ac_assert_jq '.milestone == 7' "$(cat "$PAYLOAD")" "payload milestone must be 7"
ac_assert_jq '.labels == [3]' "$(cat "$PAYLOAD")" "payload labels must be [3]"
if ! jq -e --arg marker "$MARKER" '.body | contains($marker)' "$PAYLOAD" >/dev/null; then
  ac_fail "payload body must contain ${MARKER}"
fi
ac_log "AC1 OK"

ac_log "AC2: an existing milestone marker makes no POST"
reset_stub
ISSUES_JSON="$(jq -n --arg body "already filed ${MARKER}" '[{number:1, body:$body}]')"
rc=0
file_subissues "$FIXTURE" 7 || rc=$?
ac_assert_eq "$rc" "0" "idempotent milestone filing must return 0 (got $rc)"
ac_assert_eq "$(post_count)" "0" "an existing marker must make no POST"
ac_log "AC2 OK"

ac_log "AC3: no milestone and no vision issue returns 1 and posts nothing"
reset_stub
ISSUES_JSON='[]'
rc=0
file_subissues "$FIXTURE" || rc=$?
ac_assert_eq "$rc" "1" "file_subissues without a milestone must return 1 (got $rc)"
ac_assert_eq "$(post_count)" "0" "a missing vision issue must make no POST"
ac_log "AC3 OK"

ac_pass
