#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1904.sh
#
# Issue #1904: pitch-lint checks the dependency chain between a pitch's
# sub-issues. Unknown depends_on ids, cycles, and unchained same-file pairs
# are ERRORs. Exit codes and the summary line stay as #1903 defines them.
#
# Fixtures come from ac_pitch_entry / ac_pitch_file. Hermetic: a temp dir,
# no live box, no network.
#
# Acceptance: `bash tests/acceptance/issue-1904.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq awk grep

LINT="$REPO_ROOT/tools/pitch-lint.sh"
ac_assert_file "$LINT" "tools/pitch-lint.sh must exist"

# The header lists the three chain checks (#1904).
hdr="$(sed -n '1,40p' "$LINT")"
printf '%s\n' "$hdr" | grep -q 'depends_on names an unknown id' \
  || ac_fail "header must list the unknown-id check"
printf '%s\n' "$hdr" | grep -q 'depends_on cycle' \
  || ac_fail "header must list the cycle check"
printf '%s\n' "$hdr" | grep -q 'same file' \
  || ac_fail "header must list the same-file check"

# docs/AGENTS.md line from #1903 stays true.
grep -qF "pitch-lint.sh — lints a pitch's sub-issue block against notes/issue-writing.md; markdown report (#1903)" \
  "$REPO_ROOT/docs/AGENTS.md" \
  || ac_fail "docs/AGENTS.md pitch-lint line from #1903 must stay"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# lint_one SLUG — run pitch-lint on $WORK/sprints/SLUG.md.
# rc in lint_rc, report in $WORK/out.
lint_one() {
  lint_rc=0
  bash "$LINT" "$WORK/sprints/${1}.md" >"$WORK/out" 2>"$WORK/err" || lint_rc=$?
}

# ── a and b, b depends on a, both change lib/x.sh: exit 0, no ERROR ─────────
{
  ac_pitch_entry a "" lib/x.sh
  ac_pitch_entry b a lib/x.sh
} | ac_pitch_file "$WORK" chain
lint_one chain
ac_assert_eq "$lint_rc" "0" "a chained same-file pair must exit 0 (rc=$lint_rc; $(cat "$WORK/out"))"
if grep -q '^- ERROR' "$WORK/out"; then
  ac_fail "a chained same-file pair must not report an ERROR: $(cat "$WORK/out")"
fi
ac_assert_eq "$(tail -n 1 "$WORK/out")" "Errors: 0, warnings: 0" \
  "summary line must stay Errors: N, warnings: N (got: $(tail -n 1 "$WORK/out"))"
ac_log "chained pair OK"

# ── add c (lib/x.sh, no depends_on): two same-file ERRORs, both on c ────────
{
  ac_pitch_entry a "" lib/x.sh
  ac_pitch_entry b a lib/x.sh
  ac_pitch_entry c "" lib/x.sh
} | ac_pitch_file "$WORK" triple
lint_one triple
ac_assert_eq "$lint_rc" "1" "an unchained third entry must exit 1 (rc=$lint_rc)"
same_n="$(grep -c 'chain them with depends_on' "$WORK/out" || true)"
ac_assert_eq "$same_n" "2" \
  "c must draw exactly two same-file ERRORs (got $same_n): $(cat "$WORK/out")"
err_n="$(grep -c '^- ERROR ' "$WORK/out" || true)"
ac_assert_eq "$err_n" "2" \
  "the two same-file lines must be the only ERRORs (got $err_n): $(cat "$WORK/out")"
grep -qF -- '- ERROR c: changes lib/x.sh like a; chain them with depends_on' "$WORK/out" \
  || ac_fail "one same-file ERROR must name a and sit on c: $(cat "$WORK/out")"
grep -qF -- '- ERROR c: changes lib/x.sh like b; chain them with depends_on' "$WORK/out" \
  || ac_fail "one same-file ERROR must name b and sit on c: $(cat "$WORK/out")"
ac_log "unchained c OK"

# ── a depends on b and b depends on a: a cycle ERROR ────────────────────────
{
  ac_pitch_entry a b lib/a.sh
  ac_pitch_entry b a lib/b.sh
} | ac_pitch_file "$WORK" cycle
lint_one cycle
ac_assert_eq "$lint_rc" "1" "a depends_on cycle must exit 1 (rc=$lint_rc)"
grep -qF -- '- ERROR a: depends_on cycle through a' "$WORK/out" \
  || ac_fail "a must report depends_on cycle through a: $(cat "$WORK/out")"
grep -qF -- '- ERROR b: depends_on cycle through b' "$WORK/out" \
  || ac_fail "b must report depends_on cycle through b: $(cat "$WORK/out")"
ac_log "cycle OK"

# ── a depends on zz: an unknown-id ERROR naming zz ──────────────────────────
{
  ac_pitch_entry a zz lib/x.sh
} | ac_pitch_file "$WORK" missing
lint_one missing
ac_assert_eq "$lint_rc" "1" "an unknown depends_on id must exit 1 (rc=$lint_rc)"
grep -qF -- '- ERROR a: depends_on names unknown id zz' "$WORK/out" \
  || ac_fail "unknown id zz must be named on a: $(cat "$WORK/out")"
unk_n="$(grep -c '^- ERROR ' "$WORK/out" || true)"
ac_assert_eq "$unk_n" "1" \
  "the unknown-id line must be the only ERROR (got $unk_n): $(cat "$WORK/out")"
ac_log "unknown id OK"

# ── lint_affected, extracted, prints exactly lib/x.sh ────────────────────────
fn_src="$(ac_extract_fn lint_affected "$LINT")"
[ -n "$fn_src" ] || ac_fail "ac_extract_fn did not return lint_affected"
body=$'## Problem\n- `lib/before.sh`\n## Affected files\nSee `lib/prose.sh`.\n- `lib/x.sh` (new)\n- the deletions above\n- `lib/x.sh`\n## Documentation\n- `docs/nope.md`'
# shellcheck disable=SC2086
eval "$fn_src"
got="$(lint_affected "$body")"
ac_assert_eq "$got" "lib/x.sh" \
  "lint_affected must print exactly lib/x.sh (got: ${got})"
ac_log "lint_affected OK"

ac_pass
