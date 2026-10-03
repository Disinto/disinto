#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1651.sh
#
# Issue #1651: the calibration report shows top signatures per row.
#
# tools/calibration-signatures.sh reads the finished calibration table on
# stdin and appends a `top signatures` column (table_append_column, #1650).
# Per <loop>/<class> it counts the signature of each proposal's last outcome
# in tape order, plus one `stuck` per sample of that loop and class from
# ${TAPE_STUCK_TOOL:-tools/tape-stuck.sh} run with no arguments. Up to three
# labels, `name:count`, most frequent first, ties by name. No label: the key
# is omitted and the row prints `-`. Tape only — no rubric. A failing stuck
# tool exits 1 and writes nothing.
#
# gardener/gardener-run.sh pipes the report through the tool. pipefail keeps
# the old file if either side fails.
#
# Hermetic: no network, fixture tape and table, TAPE_STUCK_TOOL is a stub.
#
# Acceptance: `bash tests/acceptance/issue-1651.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq
ac_assert_file "$REPO_ROOT/tools/calibration-signatures.sh" \
  "tools/calibration-signatures.sh is missing"
ac_assert_file "$REPO_ROOT/gardener/gardener-run.sh" "gardener/gardener-run.sh is missing"
ac_assert_file "$REPO_ROOT/gardener/AGENTS.md" "gardener/AGENTS.md is missing"

# The review (formula 3b) requires this sentence after the refresh_ops_calibration
# sentence, and after the claims-report sentence an earlier issue added there.
# Wrapping is allowed; the words must appear in this order.
# shellcheck disable=SC2016  # backticks are markdown in the required sentence
DOC_SENTENCE='The report passes through `tools/calibration-signatures.sh` (#1651), which appends a `top signatures` column.'
AGENTS_FLAT="$(tr '\n' ' ' < "$REPO_ROOT/gardener/AGENTS.md" | tr -s ' ')"
printf '%s\n' "$AGENTS_FLAT" | grep -qF "$DOC_SENTENCE" \
  || ac_fail "gardener/AGENTS.md must describe calibration-signatures.sh (#1651)"
CAL_DOC=$(grep -n 'refresh_ops_calibration`, #1454' "$REPO_ROOT/gardener/AGENTS.md" | head -n1 | cut -d: -f1)
CLAIM_DOC=$(grep -n 'tools/claims-report.sh` (#1645)' "$REPO_ROOT/gardener/AGENTS.md" | head -n1 | cut -d: -f1)
SIG_DOC=$(grep -n 'tools/calibration-signatures.sh` (#1651)' "$REPO_ROOT/gardener/AGENTS.md" | head -n1 | cut -d: -f1)
[ -n "$CAL_DOC" ] || ac_fail "gardener/AGENTS.md must still name refresh_ops_calibration (#1454)"
[ -n "$CLAIM_DOC" ] || ac_fail "gardener/AGENTS.md must still name tools/claims-report.sh (#1645)"
[ -n "$SIG_DOC" ] || ac_fail "gardener/AGENTS.md must name tools/calibration-signatures.sh (#1651)"
[ "$CAL_DOC" -lt "$SIG_DOC" ] \
  || ac_fail "signatures sentence (line $SIG_DOC) must follow refresh_ops_calibration (line $CAL_DOC)"
[ "$CLAIM_DOC" -lt "$SIG_DOC" ] \
  || ac_fail "signatures sentence (line $SIG_DOC) must follow the claims-report sentence (line $CLAIM_DOC)"
ac_log "docs OK: the report passes through calibration-signatures.sh"

GARDENER="$REPO_ROOT/gardener/gardener-run.sh"
FN_SRC="$(ac_extract_fn refresh_ops_calibration "$GARDENER")"
[ -n "$FN_SRC" ] || ac_fail "could not extract refresh_ops_calibration() from gardener-run.sh"
case "$FN_SRC" in
  # #1652 appends calibration-purpose.sh after this stage; the signatures
  # pipe itself is what this issue pins.
  *'"$FACTORY_ROOT/tools/calibration.sh" | "$FACTORY_ROOT/tools/calibration-signatures.sh"'*) ;;
  *) ac_fail "refresh_ops_calibration must pipe calibration.sh through calibration-signatures.sh" ;;
esac
ac_log "wiring OK: the report is piped through calibration-signatures.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TAPE_DIR="$TMP_DIR/tape"
mkdir -p "$TAPE_DIR"

# (dev, backlog): last outcomes signed agent-loop twice and needs-ops once.
# p1's earlier outcome (old-sig) must not count — only the last outcome does.
# p3 is a rejection; its signature still counts. p4's last outcome is unsigned,
# so dev/fix gets no label from the tape. A grade record is not an outcome.
cat >"$TAPE_DIR/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"p1","loop":"dev","class":"backlog","context":{},"decision":"approved","ref":"1651-1"}
{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"p1","bits":{"merged":1},"signature":"old-sig","numbers":{},"children":{},"payloads":[]}
{"type":"outcome","t":"2026-02-01T00:02:00Z","proposal_id":"p1","bits":{"merged":0},"signature":"agent-loop","numbers":{},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-01T00:03:00Z","id":"p2","loop":"dev","class":"backlog","context":{},"decision":"approved","ref":"1651-2"}
{"type":"outcome","t":"2026-02-01T00:04:00Z","proposal_id":"p2","bits":{"merged":1},"signature":"agent-loop","numbers":{},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-01T00:05:00Z","id":"p3","loop":"dev","class":"backlog","context":{},"decision":"rejected","ref":"1651-3"}
{"type":"outcome","t":"2026-02-01T00:06:00Z","proposal_id":"p3","bits":{},"signature":"needs-ops","numbers":{},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-01T00:07:00Z","id":"p4","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"1651-4"}
{"type":"outcome","t":"2026-02-01T00:08:00Z","proposal_id":"p4","bits":{"merged":0},"signature":"early","numbers":{},"children":{},"payloads":[]}
{"type":"outcome","t":"2026-02-01T00:09:00Z","proposal_id":"p4","bits":{"merged":0},"numbers":{},"children":{},"payloads":[]}
{"type":"grade","t":"2026-02-01T00:10:00Z","proposal_id":"p1","signature":"grade-sig","value":1,"when":"at_outcome","who":"human"}
EOF

# One dev/backlog sample. Its signature field is deliberately not "stuck":
# the column adds the label stuck, it does not copy the sample's signature.
# A sprint sample must not invent a row or change dev/backlog. No arguments.
STUCK="$TMP_DIR/stuck.sh"
cat >"$STUCK" <<'EOF'
#!/usr/bin/env bash
if [ "$#" -ne 0 ]; then
  echo "stuck stub: expected no arguments, got: $*" >&2
  exit 1
fi
printf '%s\n' '[{"loop":"dev","class":"backlog","signature":"not-the-label"},{"loop":"sprint","class":"experiment","signature":"other"}]'
EOF
chmod +x "$STUCK"

# The other columns are a fixture, not a live calibration.sh run: the tool
# must append and leave them byte-for-byte. No trailing newline — the
# here-string supplies the last one.
TABLE='| loop | class | n | promised | actual | error | mean duration_s | dur_promised | dur_error |
|---|---|---|---|---|---|---|---|---|
| dev | backlog | 4 | 50% | 75% | 25 | 10.0 | 12.0 | 2.0 |
| dev | fix | 1 | - | 0% | - | - | - | - |
| repair | incident | 1 | 10% | 0% | 10 | 1.0 | 2.0 | 1.0 |'
WANT='| loop | class | n | promised | actual | error | mean duration_s | dur_promised | dur_error | top signatures |
|---|---|---|---|---|---|---|---|---|---|
| dev | backlog | 4 | 50% | 75% | 25 | 10.0 | 12.0 | 2.0 | agent-loop:2, needs-ops:1, stuck:1 |
| dev | fix | 1 | - | 0% | - | - | - | - | - |
| repair | incident | 1 | 10% | 0% | 10 | 1.0 | 2.0 | 1.0 | - |'

run_sig() {
  local tape_dir="$1" stuck="$2" table="$3"
  RC=0
  OUT=""
  ERR=""
  TAPE_DIR="$tape_dir" TAPE_STUCK_TOOL="$stuck" \
    bash "$REPO_ROOT/tools/calibration-signatures.sh" <<<"$table" \
    >"$TMP_DIR/out" 2>"$TMP_DIR/err" || RC=$?
  OUT="$(cat "$TMP_DIR/out" 2>/dev/null || true)"
  ERR="$(cat "$TMP_DIR/err" 2>/dev/null || true)"
}

ac_log "AC: dev/backlog ends with agent-loop:2, needs-ops:1, stuck:1; unsigned row is -"
run_sig "$TAPE_DIR" "$STUCK" "$TABLE"
ac_assert_eq "$RC" "0" "signatures tool must exit 0 (rc=$RC) [stderr: $ERR]"
[ -z "$ERR" ] || ac_fail "a clean tape must not print stderr (got: $ERR)"
ac_assert_eq "$OUT" "$WANT" "appended table mismatch (got '$OUT')"
case "$OUT" in
  *$'| agent-loop:2, needs-ops:1, stuck:1 |'*) ;;
  *) ac_fail "dev/backlog row must end with 'agent-loop:2, needs-ops:1, stuck:1 |' (got: $OUT)" ;;
esac
case "$OUT" in
  *$'| - |'*) ;;
  *) ac_fail "a row with no signed or stuck proposal must end with '- |' (got: $OUT)" ;;
esac
ac_log "AC OK: top signatures appended; other columns unchanged"

# Fourth-and-beyond labels drop. Counts: agent-loop 2, then four labels at 1.
# Top three, ties by name: agent-loop, design-conflict, needs-ops. stuck and
# world lose the tie.
ac_log "top three only, ties by name"
TOP_TAPE="$TMP_DIR/tape-top"
mkdir -p "$TOP_TAPE"
cat >"$TOP_TAPE/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-02T00:00:00Z","id":"a1","loop":"dev","class":"backlog","context":{},"decision":"approved","ref":"t1"}
{"type":"outcome","t":"2026-02-02T00:01:00Z","proposal_id":"a1","bits":{},"signature":"agent-loop","numbers":{},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-02T00:02:00Z","id":"a2","loop":"dev","class":"backlog","context":{},"decision":"approved","ref":"t2"}
{"type":"outcome","t":"2026-02-02T00:03:00Z","proposal_id":"a2","bits":{},"signature":"agent-loop","numbers":{},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-02T00:04:00Z","id":"a3","loop":"dev","class":"backlog","context":{},"decision":"rejected","ref":"t3"}
{"type":"outcome","t":"2026-02-02T00:05:00Z","proposal_id":"a3","bits":{},"signature":"needs-ops","numbers":{},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-02T00:06:00Z","id":"a4","loop":"dev","class":"backlog","context":{},"decision":"rejected","ref":"t4"}
{"type":"outcome","t":"2026-02-02T00:07:00Z","proposal_id":"a4","bits":{},"signature":"design-conflict","numbers":{},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-02T00:08:00Z","id":"a5","loop":"dev","class":"backlog","context":{},"decision":"approved","ref":"t5"}
{"type":"outcome","t":"2026-02-02T00:09:00Z","proposal_id":"a5","bits":{},"signature":"world","numbers":{},"children":{},"payloads":[]}
EOF
TOP_TABLE='| loop | class | n |
|---|---|---|
| dev | backlog | 5 |'
run_sig "$TOP_TAPE" "$STUCK" "$TOP_TABLE"
ac_assert_eq "$RC" "0" "top-three run must exit 0 (rc=$RC) [stderr: $ERR]"
ac_assert_eq "$OUT" '| loop | class | n | top signatures |
|---|---|---|---|
| dev | backlog | 5 | agent-loop:2, design-conflict:1, needs-ops:1 |' \
  "only the three most frequent labels, ties by name (got '$OUT')"
ac_log "top three OK"

ac_log "a failing stuck tool exits 1 and writes nothing"
FAIL_STUCK="$TMP_DIR/stuck-fail.sh"
cat >"$FAIL_STUCK" <<'EOF'
#!/usr/bin/env bash
echo "stuck stub: forced failure" >&2
exit 4
EOF
chmod +x "$FAIL_STUCK"
run_sig "$TAPE_DIR" "$FAIL_STUCK" "$TABLE"
ac_assert_eq "$RC" "1" "a failing stuck tool must exit 1 (rc=$RC)"
ac_assert_eq "$OUT" "" "a failing stuck tool must write nothing (got '$OUT')"
printf '%s\n' "$ERR" | grep -qF 'stuck tool failed' \
  || ac_fail "stderr must name the stuck-tool failure (got: $ERR)"
ac_log "stuck-tool failure OK"

ac_pass "issue #1651: the calibration report shows top signatures per row"
