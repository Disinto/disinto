#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1903.sh
#
# Issue #1903: pitch-lint checks each sub-issue entry of a pitch against
# docs/design/notes/issue-writing.md. Zero tokens, no network, no env.sh.
#
# Fixtures come from ac_pitch_entry / ac_pitch_file (#1904, #1905, #1910
# reuse those helpers). Hermetic: a temp dir, no live box.
#
# Acceptance: `bash tests/acceptance/issue-1903.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq git shellcheck grep

TOOL="$REPO_ROOT/tools/pitch-lint.sh"
ac_assert_file "$TOOL" "tools/pitch-lint.sh is missing"

# The docs line the issue names, so a later edit cannot drop the sentence.
grep -qF "pitch-lint.sh — lints a pitch's sub-issue block against notes/issue-writing.md; markdown report; warns on overlap with a backlog list (#1903)" \
  "$REPO_ROOT/docs/AGENTS.md" \
  || ac_fail "docs/AGENTS.md must name pitch-lint.sh (#1903)"

# Mode is the git index, not the working-tree bit. Staged or committed.
MODE_LINE="$(git -C "$REPO_ROOT" ls-files -s tools/pitch-lint.sh)"
case "$MODE_LINE" in
  100755*) ac_log "mode OK: tools/pitch-lint.sh is 100755" ;;
  *) ac_fail "git ls-files -s tools/pitch-lint.sh must start with 100755 (got: ${MODE_LINE:-empty})" ;;
esac

shellcheck "$TOOL" \
  || ac_fail "shellcheck tools/pitch-lint.sh must be clean"
ac_log "shellcheck OK"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# run_lint [FILE] — stdout in $WORK/lint-out, stderr in $WORK/lint-err, rc in lint_rc.
run_lint() {
  lint_rc=0
  if [ "$#" -eq 0 ]; then
    bash "$TOOL" >"$WORK/lint-out" 2>"$WORK/lint-err" || lint_rc=$?
  else
    bash "$TOOL" "$1" >"$WORK/lint-out" 2>"$WORK/lint-err" || lint_rc=$?
  fi
}

# ── A pitch with entries a and b: exit 0, no errors, no warnings ────────────
{
  ac_pitch_entry a ""
  ac_pitch_entry b a tools/pitch-lint.sh docs/AGENTS.md
} | ac_pitch_file "$WORK" pair
run_lint "$WORK/sprints/pair.md"
ac_assert_eq "$lint_rc" "0" "a valid pair must exit 0 (rc=$lint_rc; stderr: $(cat "$WORK/lint-err"))"
ac_assert_eq "$(head -n 1 "$WORK/lint-out")" "### Pitch lint: sprints/pair.md" \
  "the report must name sprints/<basename>"
ac_assert_eq "$(tail -n 1 "$WORK/lint-out")" "Errors: 0, warnings: 0" \
  "a valid pair must end with Errors: 0, warnings: 0 (got: $(tail -n 1 "$WORK/lint-out"))"
if grep -q '^- ERROR ' "$WORK/lint-out"; then
  ac_fail "a valid pair must not report an ERROR: $(cat "$WORK/lint-out")"
fi
ac_log "valid pair OK"

# The tool sets FACTORY_ROOT and must not source lib/env.sh (no network path).
bash -x "$TOOL" "$WORK/sprints/pair.md" >"$WORK/x-out" 2>"$WORK/x-err" || true
if grep -E 'source .*[/[:space:]]env\.sh' "$WORK/x-err" >/dev/null; then
  ac_fail "pitch-lint must not source lib/env.sh"
fi
ac_log "no env.sh OK"

# ── Fat entry: missing Documentation, no checkbox, 101 body lines ────────────
# Twelve structured lines, then 89 pads: the parsed body is 101 lines.
{
  printf '%s\n' '- id: fat'
  printf '%s\n' '  title: "fat entry"'
  printf '%s\n' '  labels: [backlog]'
  printf '%s\n' '  depends_on: []'
  printf '%s\n' '  body: |'
  printf '%s\n' '    ## Problem'
  printf '%s\n' '    A long body.'
  printf '%s\n' '    ## Proposed solution'
  printf '%s\n' '    Pad the body past the ceiling.'
  printf '%s\n' '    ## Affected files'
  printf '%s\n' "    - \`tools/pitch-lint.sh\`"
  printf '%s\n' '    ## Existing tests'
  printf '%s\n' '    None.'
  printf '%s\n' '    ## Acceptance criteria'
  printf '%s\n' '    criteria without a checkbox'
  printf '%s\n' '    ## Acceptance test'
  printf '%s\n' "    \`tests/acceptance/issue-fat.sh\`"
  pad_i=1
  while [ "$pad_i" -le 89 ]; do
    printf '%s\n' "    pad line ${pad_i}"
    pad_i=$((pad_i + 1))
  done
} | ac_pitch_file "$WORK" fat
run_lint "$WORK/sprints/fat.md"
ac_assert_eq "$lint_rc" "1" "the fat entry must exit 1 (rc=$lint_rc)"
fat_errors="$(grep -c '^- ERROR ' "$WORK/lint-out" || true)"
ac_assert_eq "$fat_errors" "3" \
  "the fat entry must report exactly three ERRORs (got $fat_errors): $(cat "$WORK/lint-out")"
grep -qF -- '- ERROR fat: body has 101 lines (max 100)' "$WORK/lint-out" \
  || ac_fail "fat must name id fat on the 101-line ERROR: $(cat "$WORK/lint-out")"
grep -qF -- '- ERROR fat: missing ## Documentation' "$WORK/lint-out" \
  || ac_fail "fat must name id fat on the missing Documentation ERROR: $(cat "$WORK/lint-out")"
grep -qF -- "- ERROR fat: no '- [ ]' under ## Acceptance criteria" "$WORK/lint-out" \
  || ac_fail "fat must name id fat on the missing checkbox ERROR: $(cat "$WORK/lint-out")"
ac_log "fat entry OK: three ERRORs, each naming fat"

# ── Two entries with id a: one duplicate ERROR ──────────────────────────────
{
  ac_pitch_entry a ""
  ac_pitch_entry a ""
} | ac_pitch_file "$WORK" dup
run_lint "$WORK/sprints/dup.md"
ac_assert_eq "$lint_rc" "1" "a duplicate id must exit 1 (rc=$lint_rc)"
dup_errors="$(grep -c '^- ERROR ' "$WORK/lint-out" || true)"
ac_assert_eq "$dup_errors" "1" \
  "a duplicate id must be the only ERROR (got $dup_errors): $(cat "$WORK/lint-out")"
grep -qF -- '- ERROR a: duplicate id' "$WORK/lint-out" \
  || ac_fail "duplicate id a must be reported: $(cat "$WORK/lint-out")"
ac_log "duplicate id OK"

# ── No filer markers: the no-entries ERROR ───────────────────────────────────
mkdir -p "$WORK/sprints"
printf '%s\n' '# Sprint: bare' '## What this enables' 'Nothing yet.' 'class: internal' \
  >"$WORK/sprints/bare.md"
run_lint "$WORK/sprints/bare.md"
ac_assert_eq "$lint_rc" "1" "a pitch without filer markers must exit 1 (rc=$lint_rc)"
grep -qF -- '- ERROR: no sub-issue entries (filer block missing, empty or unparseable)' \
  "$WORK/lint-out" \
  || ac_fail "a pitch without markers must report the no-entries ERROR: $(cat "$WORK/lint-out")"
bare_errors="$(grep -c '^- ERROR' "$WORK/lint-out" || true)"
ac_assert_eq "$bare_errors" "1" \
  "a pitch without markers must report only the no-entries ERROR (got $bare_errors)"
ac_assert_eq "$(tail -n 1 "$WORK/lint-out")" "Errors: 1, warnings: 0" \
  "no-entries summary must be Errors: 1, warnings: 0"
ac_log "no markers OK"

# ── Missing FILE, and no FILE: exit 2, empty stdout, a usage line ────────────
run_lint "$WORK/sprints/missing.md"
ac_assert_eq "$lint_rc" "2" "a missing FILE must exit 2 (rc=$lint_rc)"
[ ! -s "$WORK/lint-out" ] || ac_fail "a missing FILE must produce empty stdout: $(cat "$WORK/lint-out")"
ac_assert_eq "$(cat "$WORK/lint-err")" "usage: pitch-lint.sh FILE [BACKLOG_JSON]" \
  "a missing FILE must print a usage line on stderr"
run_lint
ac_assert_eq "$lint_rc" "2" "a missing argument must exit 2 (rc=$lint_rc)"
[ ! -s "$WORK/lint-out" ] || ac_fail "a missing argument must produce empty stdout"
ac_log "usage OK"

ac_pass
