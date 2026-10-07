#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1905.sh
#
# Issue #1905: pitch-lint warns, and does not fail, when an entry lists more
# than two code files, and when a listed path is also in an open backlog
# issue. BACKLOG_JSON is optional. A missing or non-array list is one WARN
# without an id. Warnings never change the exit code.
#
# Fixtures come from ac_pitch_entry / ac_pitch_file. Hermetic: a temp dir,
# no live box, no network.
#
# Acceptance: `bash tests/acceptance/issue-1905.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq grep

TOOL="$REPO_ROOT/tools/pitch-lint.sh"
ac_assert_file "$TOOL" "pitch-lint.sh must exist for the #1905 warnings"

# Header names both warnings and the optional second argument.
hdr="$(sed -n '1,35p' "$TOOL")"
printf '%s\n' "$hdr" | grep -q 'FILE \[BACKLOG_JSON\]' \
  || ac_fail "header usage must be pitch-lint.sh FILE [BACKLOG_JSON]"
printf '%s\n' "$hdr" | grep -q 'more than 2 code files' \
  || ac_fail "header must list the code-file warning"
printf '%s\n' "$hdr" | grep -q 'open backlog issue' \
  || ac_fail "header must list the backlog-overlap warning"

grep -qF 'markdown report; warns on overlap with a backlog list' \
  "$REPO_ROOT/docs/AGENTS.md" \
  || ac_fail "docs/AGENTS.md must say pitch-lint warns on backlog overlap"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# pitch_rc / $WORK/report — one pitch-lint invocation, args passed through.
pitch_rc=0
run_pitch() {
  pitch_rc=0
  bash "$TOOL" "$@" >"$WORK/report" 2>"$WORK/stderr" || pitch_rc=$?
}

warn_count() {
  grep -c '^- WARN' "$WORK/report" || true
}

# ── 5 affected paths, 3 of them code: one WARN, exit 0 ───────────────────────
# tests/ and *.md drop out; formulas/c.toml counts.
ac_pitch_entry wide "" \
  lib/a.sh lib/b.sh formulas/c.toml tests/acceptance/issue-1.sh x/AGENTS.md \
  | ac_pitch_file "$WORK" wide
run_pitch "$WORK/sprints/wide.md"
ac_assert_eq "$pitch_rc" "0" "three code files must not fail the lint (rc=$pitch_rc; $(cat "$WORK/report"))"
ac_assert_eq "$(warn_count)" "1" \
  "three code files must be exactly one WARN (got $(warn_count)): $(cat "$WORK/report")"
grep -qF -- '- WARN wide: 3 code files under ## Affected files (ceiling 2)' "$WORK/report" \
  || ac_fail "the code-file WARN must name 3: $(cat "$WORK/report")"
ac_assert_eq "$(tail -n 1 "$WORK/report")" "Errors: 0, warnings: 1" \
  "summary must stay Errors: N, warnings: N (got: $(tail -n 1 "$WORK/report"))"
ac_log "code-file ceiling OK"

# Two code files stay under the ceiling: no code-file WARN.
ac_pitch_entry under "" lib/a.sh formulas/c.toml | ac_pitch_file "$WORK" under
run_pitch "$WORK/sprints/under.md"
ac_assert_eq "$pitch_rc" "0" "two code files must exit 0 (rc=$pitch_rc)"
if grep -q 'code files under' "$WORK/report"; then
  ac_fail "two code files must not warn: $(cat "$WORK/report")"
fi
ac_log "ceiling holds at 2"

# ── BACKLOG_JSON shares lib/a.sh with issue 77: one WARN, exit 0 ─────────────
ac_pitch_entry share "" lib/a.sh | ac_pitch_file "$WORK" share
# Forge shape: number plus a body whose ## Affected files lists one path.
tick='`'
share_body="## Affected files

- ${tick}lib/a.sh${tick}
"
jq -n --arg body "$share_body" '[{number: 77, body: $body}]' >"$WORK/open.json"
run_pitch "$WORK/sprints/share.md" "$WORK/open.json"
ac_assert_eq "$pitch_rc" "0" "a backlog overlap must not fail the lint (rc=$pitch_rc; $(cat "$WORK/report"))"
ac_assert_eq "$(warn_count)" "1" \
  "one shared path must be exactly one WARN (got $(warn_count)): $(cat "$WORK/report")"
grep -qF -- '- WARN share: lib/a.sh is also in open issue #77' "$WORK/report" \
  || ac_fail "the overlap WARN must name lib/a.sh and #77: $(cat "$WORK/report")"
ac_log "backlog overlap OK"

# ── BACKLOG_JSON names a missing file: the unreadable WARN, exit 0 ───────────
run_pitch "$WORK/sprints/share.md" "$WORK/no-such-backlog.json"
ac_assert_eq "$pitch_rc" "0" "an unreadable backlog must not fail the lint (rc=$pitch_rc)"
grep -qF -- '- WARN: backlog list unreadable; overlap not checked' "$WORK/report" \
  || ac_fail "a missing backlog file must warn without an id: $(cat "$WORK/report")"
ac_assert_eq "$(warn_count)" "1" \
  "the unreadable line must be the only WARN (got $(warn_count)): $(cat "$WORK/report")"
ac_log "missing backlog OK"

# A file that is not a JSON array is the same unreadable WARN.
printf '%s\n' '{"number":77}' >"$WORK/object.json"
run_pitch "$WORK/sprints/share.md" "$WORK/object.json"
ac_assert_eq "$pitch_rc" "0" "a non-array backlog must not fail the lint (rc=$pitch_rc)"
grep -qF -- '- WARN: backlog list unreadable; overlap not checked' "$WORK/report" \
  || ac_fail "a non-array backlog must warn without an id: $(cat "$WORK/report")"
ac_log "non-array backlog OK"

# ── No second argument: no backlog WARN, even on the overlapping entry ───────
run_pitch "$WORK/sprints/share.md"
ac_assert_eq "$pitch_rc" "0" "omitting BACKLOG_JSON must exit 0 (rc=$pitch_rc)"
if grep -q 'backlog list\|open issue' "$WORK/report"; then
  ac_fail "omitting BACKLOG_JSON must not warn about the backlog: $(cat "$WORK/report")"
fi
ac_assert_eq "$(tail -n 1 "$WORK/report")" "Errors: 0, warnings: 0" \
  "omitting BACKLOG_JSON must not add a warning (got: $(tail -n 1 "$WORK/report"))"
ac_log "no backlog argument OK"

ac_pass
