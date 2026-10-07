#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1893.sh
#
# Issue #1893: file_subissues writes each depends_on as a blocking
# ## Dependencies line, and files entries only after those dependencies.
# An unknown id or a cycle files nothing. A second run does not POST.
#
# Hermetic: no network, no live forge. The filing function is the copy
# ac_extract_fn returns. curl is the ac_write_curl_stub binary, rewritten
# in place so a -d payload that follows the URL is recorded.
#
# Acceptance: `bash tests/acceptance/issue-1893.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq grep
ac_assert_file "$REPO_ROOT/lib/sprint-filer.sh" "lib/sprint-filer.sh is missing"

DOC_SENTENCE='Files the entries in dependency order and writes each `depends_on` as a blocking `## Dependencies` line (`lib/parse-deps.sh`); an unknown id or a cycle files nothing.'
grep -qF "$DOC_SENTENCE" "$REPO_ROOT/lib/AGENTS.md" \
  || ac_fail "lib/AGENTS.md must describe dependency filing (#1893)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
POSTS="$WORK/posts"
SEQ="$WORK/seq"
: >"$POSTS"
printf '11' >"$SEQ"

# Shared stub first (issue-1216 shape). Its joined-argument URL cannot see
# a payload passed after the URL, so the recorder below replaces that body.
ac_write_curl_stub "$STUB_BIN"
[ -x "$STUB_BIN/curl" ] || ac_fail "ac_write_curl_stub did not write an executable curl"

cat > "$STUB_BIN/curl" <<'RECORDER'
#!/usr/bin/env bash
# Issue 1893 recorder. Numbers start at CURL_SEQ (11) and climb by one.
set -euo pipefail
method="GET"
payload=""
target=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X)
      method="${2:-GET}"
      shift 2
      ;;
    -d|--data)
      payload="${2:-}"
      shift 2
      ;;
    http://*|https://*)
      target="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done
if [ "$method" != "GET" ]; then
  printf '%s\n' "$payload" >> "${CURL_POSTS:?}"
  next="$(cat "${CURL_SEQ:?}")"
  printf '{"number":%s}' "$next"
  printf '%s' "$((next + 1))" > "${CURL_SEQ:?}"
  exit 0
fi
if [[ "$target" == */labels ]]; then
  printf '%s' '[{"id":9,"name":"backlog"}]'
  exit 0
fi
printf '%s' '[]'
RECORDER
chmod +x "$STUB_BIN/curl"

export PATH="$STUB_BIN:$PATH"
export CURL_POSTS="$POSTS"
export CURL_SEQ="$SEQ"
export FACTORY_ROOT="$REPO_ROOT"
export FORGE_FILER_TOKEN="stub-filer"
export FORGE_API="https://forge.example/api/v1/repos/o/p"
# shellcheck source=../../lib/sprint-filer.sh
source "$REPO_ROOT/lib/sprint-filer.sh"

FN_FILE="$(ac_extract_fn file_subissues "$REPO_ROOT/lib/sprint-filer.sh")"
[ -n "$FN_FILE" ] || ac_fail "ac_extract_fn did not return file_subissues"
FN_ORDER="$(ac_extract_fn order_subissue_entries "$REPO_ROOT/lib/sprint-filer.sh")"
[ -n "$FN_ORDER" ] || ac_fail "ac_extract_fn did not return order_subissue_entries"
FN_DEPS="$(ac_extract_fn subissue_dependency_block "$REPO_ROOT/lib/sprint-filer.sh")"
[ -n "$FN_DEPS" ] || ac_fail "ac_extract_fn did not return subissue_dependency_block"
# The run uses the extracted functions, not a second copy.
eval "$FN_ORDER"
eval "$FN_DEPS"
eval "$FN_FILE"

# The test owns the issue listing. Defined after the source so it replaces
# forge_api_all; sprint-filer skips env.sh when FACTORY_ROOT is set.
forge_api_all() { printf '%s' "$ISSUES_JSON"; }

ISSUES_JSON='[]'

reset_recorder() {
  : >"$POSTS"
  printf '11' >"$SEQ"
}

# Payloads are pretty-printed JSON values, so count values, not lines.
recorded() {
  jq -s 'length' "$POSTS"
}

body_of() {
  local id="$1"
  jq -sr --arg id "$id" '
    [.[] | select(.body | contains("id: " + $id + " -->"))][0].body // ""
  ' "$POSTS"
}

ac_log "AC1: c, b, a are filed as a then b then c, with blocking lines"
reset_recorder
ISSUES_JSON='[]'
{
  ac_pitch_entry c "a, b" lib/sprint-filer.sh
  ac_pitch_entry b a lib/sprint-filer.sh
  ac_pitch_entry a "" lib/sprint-filer.sh
} | ac_pitch_file "$WORK" chain
rc=0
file_subissues "$WORK/sprints/chain.md" 7 || rc=$?
ac_assert_eq "$rc" "0" "chained filing must return 0 (got $rc)"
ac_assert_eq "$(recorded)" "3" "chained filing must POST exactly three issues"
filed_ids="$(jq -sr 'map(.body | capture("id: (?<id>[^ ]+) -->").id) | join(" ")' "$POSTS")"
ac_assert_eq "$filed_ids" "a b c" "issues must be created in dependency order (got $filed_ids)"

a_body="$(body_of a)"
b_body="$(body_of b)"
c_body="$(body_of c)"
[ -n "$a_body" ] || ac_fail "recorded POST for a is missing"
printf '%s\n' "$b_body" | grep -qF '## Dependencies' \
  || ac_fail "b's body must contain ## Dependencies"
printf '%s\n' "$b_body" | grep -qF -- '- #11' \
  || ac_fail "b's body must contain - #11 (a's number)"
printf '%s\n' "$c_body" | grep -qF -- '- #11' \
  || ac_fail "c's body must contain - #11"
printf '%s\n' "$c_body" | grep -qF -- '- #12' \
  || ac_fail "c's body must contain - #12 (b's number)"
if printf '%s\n' "$a_body" | grep -qF '## Dependencies'; then
  ac_fail "a has no depends_on, so its body must not gain ## Dependencies"
fi

b_deps="$(printf '%s\n' "$b_body" | bash "$REPO_ROOT/lib/parse-deps.sh")"
ac_assert_eq "$b_deps" "11" "parse-deps on b must report a's number (got ${b_deps})"
c_deps="$(printf '%s\n' "$c_body" | bash "$REPO_ROOT/lib/parse-deps.sh")"
ac_assert_eq "$c_deps" $'11\n12' "parse-deps on c must report a and b (got ${c_deps})"
ac_log "AC1 OK"

ac_log "AC2: a second run, with every issue existing, makes no POST"
ISSUES_JSON="$(jq -s '
  to_entries | map({number: (11 + .key), body: .value.body})
' "$POSTS")"
reset_recorder
rc=0
file_subissues "$WORK/sprints/chain.md" 7 || rc=$?
ac_assert_eq "$rc" "0" "idempotent chain filing must return 0 (got $rc)"
ac_assert_eq "$(recorded)" "0" "a second run must make no POST"
# The issues that already exist still carry the numbers from the first filing.
printf '%s' "$ISSUES_JSON" | jq -e '
  ([.[] | select(.number == 12 and (.body | contains("- #11")))] | length) == 1
  and ([.[] | select(.number == 13 and (.body | contains("- #11")) and (.body | contains("- #12")))] | length) == 1
' >/dev/null || ac_fail "existing dependency lines must still name 11 and 12"
ac_log "AC2 OK"

ac_log "AC3: unknown depends_on id files nothing"
reset_recorder
ISSUES_JSON='[]'
ac_pitch_entry a zz lib/only-unknown.sh | ac_pitch_file "$WORK" unknown
rc=0
file_subissues "$WORK/sprints/unknown.md" 7 || rc=$?
ac_assert_eq "$rc" "1" "an unknown depends_on id must return 1 (got $rc)"
ac_assert_eq "$(recorded)" "0" "an unknown id must make no POST"
ac_log "AC3 OK"

ac_log "AC4: a cycle a → b → a files nothing"
reset_recorder
ISSUES_JSON='[]'
{
  ac_pitch_entry a b lib/cycle-left.sh
  ac_pitch_entry b a lib/cycle-right.sh
} | ac_pitch_file "$WORK" cycle
rc=0
file_subissues "$WORK/sprints/cycle.md" 7 || rc=$?
ac_assert_eq "$rc" "1" "a depends_on cycle must return 1 (got $rc)"
ac_assert_eq "$(recorded)" "0" "a cycle must make no POST"
ac_log "AC4 OK"

ac_log "AC5: a vision marker's #N is not a blocking dependency"
vision_marker='<!-- decomposed-from: #4, sprint: chain, id: b -->'
block="$(subissue_dependency_block '["a"]' '{"a":"11"}' "$vision_marker")"
vision_body="${block}

${vision_marker}"
vision_deps="$(printf '%s\n' "$vision_body" | bash "$REPO_ROOT/lib/parse-deps.sh")"
ac_assert_eq "$vision_deps" "11" "a vision marker must not add #4 as a blocking dep (got ${vision_deps})"
ac_log "AC5 OK"

ac_pass
