#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2147.sh
#
# Issue #2147: the oldest-judgment line counts only issues labelled judgment.
#
# supervisor/preflight.sh asks the forge for /issues?state=open&labels=judgment
# ... but Forgejo ignores a labels= filter naming a label the repo does not have
# and returns every open issue, so the vision issue #1293 was reported as the
# "oldest judgment" and the judgment-stale recipe (P3, 4 h) fired on every
# supervisor run. The fix keeps the request and re-checks the label on the
# response with jq: select(any(.labels[]?; .name == "judgment")).
#
# Verifies (hermetic — a throwaway ops root in a mktemp dir; the extracted
# __preflight_research_runs function is driven in a subshell with stubbed
# forge_api/date, so no forge and no live repo is touched):
#   1. preflight.sh still asks for labels=judgment and still re-checks the
#      label on the response, with the #2147 comment naming the cause.
#   2. A forge response carrying only an issue labelled `vision` prints
#      `Oldest judgment: none`.
#   3. Adding a `judgment`-labelled issue #7 aged 5 h prints
#      `Oldest judgment: 5h (#7)` — the unlabelled issue is ignored.
#   4. An issue with no `labels` key (and one with an empty labels array) is
#      not counted.
#   5. supervisor/AGENTS.md documents the response-side label check (#2147).
#   6. tests/acceptance/issue-1322.sh and tests/acceptance/issue-2100.sh pass.
#
# Run via: tools/run-acceptance.sh 2147
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq date df awk sed grep mktemp

PREFLIGHT="$REPO_ROOT/supervisor/preflight.sh"
AGENTS_MD="$REPO_ROOT/supervisor/AGENTS.md"
TEST_1322="$REPO_ROOT/tests/acceptance/issue-1322.sh"
TEST_2100="$REPO_ROOT/tests/acceptance/issue-2100.sh"

for f in "$PREFLIGHT" "$AGENTS_MD" "$TEST_1322" "$TEST_2100"; do
  ac_assert_file "$f" "required file is missing: ${f#"$REPO_ROOT"/}"
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── AC1: the request is kept, the label is re-checked on the response ─────────
ac_log 'AC1: preflight.sh keeps the labels= request and re-checks the label'
grep -qE 'labels=judgment&type=issues&limit=50' "$PREFLIGHT" \
  || ac_fail 'AC1: the forge request must still ask for labels=judgment'
grep -qE 'select\(any\(\.labels\[\]\?; \.name == "judgment"\)\)' "$PREFLIGHT" \
  || ac_fail 'AC1: the jq filter must keep only issues carrying the judgment label (#2147)'
grep -qF '#2147' "$PREFLIGHT" \
  || ac_fail 'AC1: preflight.sh must carry the comment naming the Forgejo behaviour and #2147'

# ── the section function, extracted (no copied harness, #1134) ───────────────
RR_FN="$(ac_extract_fn __preflight_research_runs "$PREFLIGHT")"
[ -n "$RR_FN" ] || ac_fail 'AC1: preflight.sh does not define __preflight_research_runs'

run_rr() {
  # $1 = canned forge response; the clock is fixed so the ages are deterministic
  JUDG_RESPONSE="$1" OPS_FIXTURE="$WORK/ops" FIXED_NOW=1750000000 SECTION_FN="$RR_FN" bash -c '
    set -u
    OPS_REPO_ROOT="$OPS_FIXTURE"
    eval "$SECTION_FN"
    forge_api() { printf "%s\n" "$JUDG_RESPONSE"; }
    date() {
      case "$1" in
        -d) printf "%s\n" "$(( FIXED_NOW - ${2#rel:} ))" ;;
        *)  printf "%s\n" "$FIXED_NOW" ;;
      esac
    }
    __preflight_research_runs
  ' 2>&1
}

mkdir -p "$WORK/ops/runs" "$WORK/ops/artifacts"
printf '{"id":"run-new","started":"rel:600"}\n' > "$WORK/ops/runs/run-new.json"

oldest_line() {
  printf '%s\n' "$1" | sed -n 's/^Oldest judgment: \(.*\)$/\1/p' | head -n 1
}

# ── AC2: an open issue that is not a judgment is not counted ──────────────────
ac_log 'AC2: a forge response with only a vision-labelled issue prints none'
_out="$(run_rr '[{"number":1293,"created_at":"rel:4680000","labels":[{"name":"vision"}]}]')" \
  || ac_fail 'AC2: __preflight_research_runs exited non-zero'
_ac2="$(oldest_line "$_out")"
ac_assert_eq "$_ac2" "none" "AC2: an unlabelled-for-judgment issue must not count; got: $_out"

# ── AC3: the judgment-labelled issue is the one reported ──────────────────────
ac_log 'AC3: a judgment-labelled issue is reported, the vision one ignored'
_out="$(run_rr '[{"number":1293,"created_at":"rel:4680000","labels":[{"name":"vision"}]},{"number":7,"created_at":"rel:18000","labels":[{"name":"judgment"}]}]')" \
  || ac_fail 'AC3: __preflight_research_runs exited non-zero'
_ac3="$(oldest_line "$_out")"
ac_assert_eq "$_ac3" "5h (#7)" "AC3: the oldest judgment must be #7 at 5h; got: $_out"
if printf '%s\n' "$_out" | grep -q '#1293'; then
  ac_fail 'AC3: the vision issue #1293 leaked into the judgment line'
fi

# ── AC4: no labels key, and an empty labels array, are not counted ────────────
ac_log 'AC4: an issue with no labels key (or an empty labels array) is not counted'
_out="$(run_rr '[{"number":1293,"created_at":"rel:4680000"},{"number":8,"created_at":"rel:3600","labels":[]}]')" \
  || ac_fail 'AC4: __preflight_research_runs exited non-zero'
_ac4="$(oldest_line "$_out")"
ac_assert_eq "$_ac4" "none" "AC4: issues without a judgment label must not count; got: $_out"

# The same unlabelled issues plus a judgment one: the judgment one wins even
# though it is the youngest of the three.
_out="$(run_rr '[{"number":1293,"created_at":"rel:4680000"},{"number":8,"created_at":"rel:3600","labels":[]},{"number":42,"created_at":"rel:10800","labels":[{"name":"judgment"},{"name":"bug-report"}]}]')" \
  || ac_fail 'AC4: __preflight_research_runs exited non-zero'
ac_assert_eq "$(oldest_line "$_out")" "3h (#42)" \
  "AC4: the judgment-labelled issue must be picked among unlabelled ones; got: $_out"

# ── AC5: the doc records the response-side check ──────────────────────────────
ac_log 'AC5: supervisor/AGENTS.md documents the label check on the response'
grep -qF 'the label is checked on the response' "$AGENTS_MD" \
  || ac_fail 'AC5: supervisor/AGENTS.md must say the label is checked on the response (#2147)'
grep -qF '#2147' "$AGENTS_MD" \
  || ac_fail 'AC5: supervisor/AGENTS.md must name #2147'

# ── AC6: syntax plus the neighbouring acceptance tests ────────────────────────
ac_log 'AC6: bash -n on preflight.sh; issue-1322.sh and issue-2100.sh still pass'
bash -n "$PREFLIGHT" || ac_fail 'AC6: supervisor/preflight.sh must parse with bash -n'
bash "$TEST_1322" >/dev/null || ac_fail 'AC6: tests/acceptance/issue-1322.sh must still pass'
bash "$TEST_2100" >/dev/null || ac_fail 'AC6: tests/acceptance/issue-2100.sh must still pass'

ac_pass
