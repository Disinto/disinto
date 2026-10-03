#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1652.sh
#
# Issue #1652: the calibration report shows a purpose column from grades.
#
# tools/calibration-purpose.sh reads the finished calibration table on stdin
# and appends a `purpose` column (table_append_column, #1650). The graded
# pack is flat `loop = <grace hours>` TOML. A graded loop's eligible
# proposals are those whose last outcome is at least that many hours before
# $CALIBRATION_NOW. Each contributes its last grade, or 0 when ungraded or
# null. The cell is `M (g/e)`. A loop not in the pack (dev) prints `-`, not
# a fake 0. Other columns are left byte-for-byte.
#
# gardener/gardener-run.sh pipes the report through the tool after
# tools/calibration-signatures.sh. pipefail keeps the old file if it fails.
#
# Hermetic: no network, fixture tape, table and graded pack, fixed
# CALIBRATION_NOW.
#
# Acceptance: `bash tests/acceptance/issue-1652.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq python3
ac_assert_file "$REPO_ROOT/tools/calibration-purpose.sh" \
  "tools/calibration-purpose.sh is missing"
ac_assert_file "$REPO_ROOT/gardener/gardener-run.sh" "gardener/gardener-run.sh is missing"
ac_assert_file "$REPO_ROOT/gardener/AGENTS.md" "gardener/AGENTS.md is missing"

# The review (formula 3b) requires this sentence after the signatures sentence
# (#1651). Wrapping is allowed; the words must appear in this order.
# shellcheck disable=SC2016  # backticks are markdown in the required sentence
DOC_SENTENCE='Then through `tools/calibration-purpose.sh` (#1652), which appends a `purpose` column from grades.'
AGENTS_FLAT="$(tr '\n' ' ' < "$REPO_ROOT/gardener/AGENTS.md" | tr -s ' ')"
printf '%s\n' "$AGENTS_FLAT" | grep -qF "$DOC_SENTENCE" \
  || ac_fail "gardener/AGENTS.md must describe calibration-purpose.sh (#1652)"
SIG_DOC=$(grep -n 'tools/calibration-signatures.sh` (#1651)' "$REPO_ROOT/gardener/AGENTS.md" | head -n1 | cut -d: -f1)
PURPOSE_DOC=$(grep -n 'tools/calibration-purpose.sh` (#1652)' "$REPO_ROOT/gardener/AGENTS.md" | head -n1 | cut -d: -f1)
[ -n "$SIG_DOC" ] || ac_fail "gardener/AGENTS.md must still name tools/calibration-signatures.sh (#1651)"
[ -n "$PURPOSE_DOC" ] || ac_fail "gardener/AGENTS.md must name tools/calibration-purpose.sh (#1652)"
[ "$SIG_DOC" -lt "$PURPOSE_DOC" ] \
  || ac_fail "purpose sentence (line $PURPOSE_DOC) must follow the signatures sentence (line $SIG_DOC)"
ac_log "docs OK: the report then passes through calibration-purpose.sh"

GARDENER="$REPO_ROOT/gardener/gardener-run.sh"
FN_SRC="$(ac_extract_fn refresh_ops_calibration "$GARDENER")"
[ -n "$FN_SRC" ] || ac_fail "could not extract refresh_ops_calibration() from gardener-run.sh"
case "$FN_SRC" in
  *'out="$( "$FACTORY_ROOT/tools/calibration.sh" | "$FACTORY_ROOT/tools/calibration-signatures.sh" | "$FACTORY_ROOT/tools/calibration-purpose.sh" )" || rc=$?'*) ;;
  *) ac_fail "refresh_ops_calibration must pipe signatures through calibration-purpose.sh" ;;
esac
ac_log "wiring OK: purpose is appended after the signatures column"

# The default pack path is the ops packs/graded.toml, same shape as the
# stuck pack. A hardcoded path would ignore CALIBRATION_GRADED_FILE.
grep -qF 'CALIBRATION_GRADED_FILE:-${OPS_REPO_ROOT:-/home/agent/repos/_factory/disinto-ops}/packs/graded.toml' \
  "$REPO_ROOT/tools/calibration-purpose.sh" \
  || ac_fail "graded pack default must be OPS_REPO_ROOT/packs/graded.toml"
grep -qF 'CALIBRATION_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)' \
  "$REPO_ROOT/tools/calibration-purpose.sh" \
  || ac_fail "clock must default to now when CALIBRATION_NOW is unset"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Clock is 2026-06-03T00:00:00Z. Grace is 48h, so an outcome is eligible at
# 2026-06-01T00:00:00Z (exactly 48h) and not at 2026-06-01T00:00:01Z or at
# 2026-06-02T00:00:00Z (24h).
NOW="2026-06-03T00:00:00Z"
PACK="$TMP_DIR/graded.toml"
printf '%s\n' 'sprint = 48' >"$PACK"

TAPE_DIR="$TMP_DIR/tape"
mkdir -p "$TAPE_DIR"
# p-graded: exactly 48h, last grade 0.8 (an earlier 1.0 must not win).
# p-ungraded: 96h, no grade — reads as 0, and does not increment g.
# p-young / p-almost / p-restated: poison grades of 1.0 that must not enter
# the mean. p-none has no outcome. p-bad-t has a non-stamp on its last
# outcome. p-null's last grade is null (an earlier 0.9 must not win), so
# the deploy cell is 0.00 (0/1). p-zero's grade is the number 0, so holdout
# is 0.00 (1/1) — a numeric zero counts, a null does not. dev is graded in
# the tape but not in the pack. A torn line must not fail the report.
cat >"$TAPE_DIR/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-05-01T00:00:00Z","id":"p-graded","loop":"sprint","class":"experiment","context":{},"decision":"approved","ref":"1652-graded"}
{"type":"grade","t":"2026-05-01T00:01:00Z","proposal_id":"p-graded","value":1.0,"when":"at_approval","who":"human"}
{"type":"outcome","t":"2026-06-01T00:00:00Z","proposal_id":"p-graded","bits":{"effect":1},"numbers":{},"children":{},"payloads":[]}
{"type":"grade","t":"2026-06-01T01:00:00Z","proposal_id":"p-graded","value":0.8,"when":"at_outcome","who":"human"}
{"type":"proposal","t":"2026-05-20T00:00:00Z","id":"p-ungraded","loop":"sprint","class":"experiment","context":{},"decision":"approved","ref":"1652-ungraded"}
{"type":"outcome","t":"2026-05-30T00:00:00Z","proposal_id":"p-ungraded","bits":{"effect":0},"numbers":{},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-06-01T00:00:00Z","id":"p-young","loop":"sprint","class":"experiment","context":{},"decision":"approved","ref":"1652-young"}
{"type":"outcome","t":"2026-06-02T00:00:00Z","proposal_id":"p-young","bits":{"effect":1},"numbers":{},"children":{},"payloads":[]}
{"type":"grade","t":"2026-06-02T01:00:00Z","proposal_id":"p-young","value":1,"when":"at_outcome","who":"human"}
{"type":"proposal","t":"2026-06-01T00:00:00Z","id":"p-almost","loop":"sprint","class":"experiment","context":{},"decision":"approved","ref":"1652-almost"}
{"type":"outcome","t":"2026-06-01T00:00:01Z","proposal_id":"p-almost","bits":{"effect":1},"numbers":{},"children":{},"payloads":[]}
{"type":"grade","t":"2026-06-01T02:00:00Z","proposal_id":"p-almost","value":1,"when":"at_outcome","who":"human"}
{"type":"proposal","t":"2026-05-01T00:00:00Z","id":"p-restated","loop":"sprint","class":"experiment","context":{},"decision":"approved","ref":"1652-restated"}
{"type":"outcome","t":"2026-05-01T00:00:00Z","proposal_id":"p-restated","bits":{"effect":1},"numbers":{},"children":{},"payloads":[]}
{"type":"outcome","t":"2026-06-02T12:00:00Z","proposal_id":"p-restated","bits":{"effect":0},"numbers":{},"children":{},"payloads":[]}
{"type":"grade","t":"2026-06-02T13:00:00Z","proposal_id":"p-restated","value":1,"when":"at_outcome","who":"human"}
{"type":"proposal","t":"2026-01-01T00:00:00Z","id":"p-none","loop":"sprint","class":"experiment","context":{},"decision":"approved","ref":"1652-none"}
{"type":"grade","t":"2026-01-02T00:00:00Z","proposal_id":"p-none","value":-1,"when":"at_approval","who":"human"}
{torn
{"type":"proposal","t":"2026-05-01T00:00:00Z","id":"p-bad-t","loop":"sprint","class":"experiment","context":{},"decision":"approved","ref":"1652-bad-t"}
{"type":"outcome","t":1717200000,"proposal_id":"p-bad-t","bits":{},"numbers":{},"children":{},"payloads":[]}
{"type":"grade","t":"2026-06-01T00:00:00Z","proposal_id":"p-bad-t","value":1,"when":"at_outcome","who":"human"}
{"type":"proposal","t":"2026-05-20T00:00:00Z","id":"p-null","loop":"sprint","class":"deploy","context":{},"decision":"approved","ref":"1652-null"}
{"type":"outcome","t":"2026-05-31T00:00:00Z","proposal_id":"p-null","bits":{"effect":1},"numbers":{},"children":{},"payloads":[]}
{"type":"grade","t":"2026-05-31T01:00:00Z","proposal_id":"p-null","value":0.9,"when":"at_outcome","who":"human"}
{"type":"grade","t":"2026-05-31T02:00:00Z","proposal_id":"p-null","value":null,"when":"at_outcome","who":"human"}
{"type":"proposal","t":"2026-05-20T00:00:00Z","id":"p-zero","loop":"sprint","class":"holdout","context":{},"decision":"approved","ref":"1652-zero"}
{"type":"outcome","t":"2026-06-01T00:00:00Z","proposal_id":"p-zero","bits":{"effect":0},"numbers":{},"children":{},"payloads":[]}
{"type":"grade","t":"2026-06-01T03:00:00Z","proposal_id":"p-zero","value":0,"when":"at_outcome","who":"human"}
{"type":"proposal","t":"2026-04-01T00:00:00Z","id":"p-dev","loop":"dev","class":"backlog","context":{},"decision":"approved","ref":"1652-dev"}
{"type":"outcome","t":"2026-05-01T00:00:00Z","proposal_id":"p-dev","bits":{"merged":1},"numbers":{},"children":{},"payloads":[]}
{"type":"grade","t":"2026-05-01T01:00:00Z","proposal_id":"p-dev","value":1,"when":"at_outcome","who":"human"}
{"type":"proposal","t":"2026-06-01T00:00:00Z","id":"p-internal","loop":"sprint","class":"internal","context":{},"decision":"approved","ref":"1652-internal"}
{"type":"outcome","t":"2026-06-02T00:00:00Z","proposal_id":"p-internal","bits":{"effect":1},"numbers":{},"children":{},"payloads":[]}
{"type":"grade","t":"2026-06-02T02:00:00Z","proposal_id":"p-internal","value":0.5,"when":"at_outcome","who":"human"}
{"type":"run","t":"2026-06-01T00:00:00Z","proposal_id":"p-graded","organ":"dev","agent":"claude","started":"2026-06-01T00:00:00Z","attempts":1,"cost":{},"status":"completed"}
EOF

# The other columns are a fixture, not a live calibration.sh run: the tool
# must append and leave them byte-for-byte.
TABLE='| loop | class | n | promised | actual | error | mean duration_s | dur_promised | dur_error | top signatures |
|---|---|---|---|---|---|---|---|---|---|
| sprint | experiment | 6 | 11% | 22% | 33 | 1.5 | 2.5 | 1.0 | stuck:1 |
| sprint | deploy | 1 | 44% | 55% | 11 | 3.0 | 4.0 | 1.0 | needs-ops:1 |
| sprint | holdout | 1 | 66% | 77% | 11 | 5.0 | 6.0 | 1.0 | - |
| sprint | internal | 1 | - | 0% | - | - | - | - | world:1 |
| dev | backlog | 4 | 40% | 50% | 10 | 8.0 | 9.0 | 1.0 | agent-loop:2 |
| repair | incident | 2 | 10% | 0% | 10 | 1.0 | 2.0 | 1.0 | - |'
WANT='| loop | class | n | promised | actual | error | mean duration_s | dur_promised | dur_error | top signatures | purpose |
|---|---|---|---|---|---|---|---|---|---|---|
| sprint | experiment | 6 | 11% | 22% | 33 | 1.5 | 2.5 | 1.0 | stuck:1 | 0.40 (1/2) |
| sprint | deploy | 1 | 44% | 55% | 11 | 3.0 | 4.0 | 1.0 | needs-ops:1 | 0.00 (0/1) |
| sprint | holdout | 1 | 66% | 77% | 11 | 5.0 | 6.0 | 1.0 | - | 0.00 (1/1) |
| sprint | internal | 1 | - | 0% | - | - | - | - | world:1 | - |
| dev | backlog | 4 | 40% | 50% | 10 | 8.0 | 9.0 | 1.0 | agent-loop:2 | - |
| repair | incident | 2 | 10% | 0% | 10 | 1.0 | 2.0 | 1.0 | - | - |'

run_purpose() {
  local pack="$1" tape_dir="$2" now="$3" table="$4"
  RC=0
  OUT=""
  ERR=""
  CALIBRATION_GRADED_FILE="$pack" TAPE_DIR="$tape_dir" CALIBRATION_NOW="$now" \
    bash "$REPO_ROOT/tools/calibration-purpose.sh" <<<"$table" \
    >"$TMP_DIR/out" 2>"$TMP_DIR/err" || RC=$?
  OUT="$(cat "$TMP_DIR/out" 2>/dev/null || true)"
  ERR="$(cat "$TMP_DIR/err" 2>/dev/null || true)"
}

ac_log "AC: two eligible sprint proposals, one graded 0.8 and one ungraded, give 0.40 (1/2)"
run_purpose "$PACK" "$TAPE_DIR" "$NOW" "$TABLE"
ac_assert_eq "$RC" "0" "purpose tool must exit 0 (rc=$RC) [stderr: $ERR]"
[ -z "$ERR" ] || ac_fail "a clean tape must not print stderr (got: $ERR)"
ac_assert_eq "$OUT" "$WANT" "appended table mismatch (got '$OUT')"
case "$OUT" in
  *$'| 0.40 (1/2) |'*) ;;
  *) ac_fail "sprint/experiment must end with '0.40 (1/2) |' (got: $OUT)" ;;
esac
case "$OUT" in
  *$'| dev | backlog | 4 | 40% | 50% | 10 | 8.0 | 9.0 | 1.0 | agent-loop:2 | - |'*) ;;
  *) ac_fail "a dev row must print '-' when dev is not in the graded pack (got: $OUT)" ;;
esac
case "$OUT" in
  *$'| sprint | internal | 1 | - | 0% | - | - | - | - | world:1 | - |'*) ;;
  *) ac_fail "a 24h-old sprint outcome must not be eligible (got: $OUT)" ;;
esac
ac_log "AC OK: purpose appended; a 24h outcome is out; dev prints -; other columns unchanged"

ac_log "a missing graded pack appends the column with no values"
run_purpose "$TMP_DIR/no-such-graded.toml" "$TAPE_DIR" "$NOW" "$TABLE"
ac_assert_eq "$RC" "0" "a missing graded pack must exit 0 (rc=$RC) [stderr: $ERR]"
[ -z "$ERR" ] || ac_fail "a missing graded pack must not print stderr (got: $ERR)"
case "$OUT" in
  *$'| purpose |'*) ;;
  *) ac_fail "a missing pack must still append the purpose column (got: $OUT)" ;;
esac
case "$OUT" in
  *'0.40'*) ac_fail "a missing pack must not invent purpose values (got: $OUT)" ;;
esac
ac_log "missing pack OK"

ac_log "an unparsable graded pack exits 1 and writes nothing"
printf '%s\n' '[[[ not toml' >"$TMP_DIR/bad.toml"
run_purpose "$TMP_DIR/bad.toml" "$TAPE_DIR" "$NOW" "$TABLE"
ac_assert_eq "$RC" "1" "an unparsable pack must exit 1 (rc=$RC)"
[ ! -s "$TMP_DIR/out" ] || ac_fail "an unparsable pack must write nothing (got: $OUT)"
printf '%s\n' "$ERR" | grep -qF 'failed to parse graded pack' \
  || ac_fail "stderr must name the pack parse failure (got: $ERR)"
ac_log "unparsable pack OK"

ac_log "a graded-pack value that is not a positive integer exits 1"
printf '%s\n' 'sprint = "48"' >"$TMP_DIR/string.toml"
run_purpose "$TMP_DIR/string.toml" "$TAPE_DIR" "$NOW" "$TABLE"
ac_assert_eq "$RC" "1" "a string grace must exit 1 (rc=$RC)"
[ ! -s "$TMP_DIR/out" ] || ac_fail "a non-integer grace must write nothing (got: $OUT)"
printf '%s\n' "$ERR" | grep -qF 'not a positive integer' \
  || ac_fail "stderr must name the non-integer value (got: $ERR)"
printf '%s\n' 'sprint = 0' >"$TMP_DIR/zero.toml"
run_purpose "$TMP_DIR/zero.toml" "$TAPE_DIR" "$NOW" "$TABLE"
ac_assert_eq "$RC" "1" "a zero grace must exit 1 (rc=$RC)"
[ ! -s "$TMP_DIR/out" ] || ac_fail "a zero grace must write nothing (got: $OUT)"
ac_log "non-integer grace OK"

ac_log "an unparseable clock exits 1 and writes nothing"
run_purpose "$PACK" "$TAPE_DIR" "not-a-clock" "$TABLE"
ac_assert_eq "$RC" "1" "an unparseable clock must exit 1 (rc=$RC)"
[ ! -s "$TMP_DIR/out" ] || ac_fail "an unparseable clock must write nothing (got: $OUT)"
printf '%s\n' "$ERR" | grep -qF 'unparseable clock' \
  || ac_fail "stderr must name the clock (got: $ERR)"
ac_log "clock OK"

ac_pass "issue #1652: the calibration report shows a purpose column from grades"
