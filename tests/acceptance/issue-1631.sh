#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1631.sh
#
# Issue #1631: feat(gardener): rejected issues reach the tape.
#
# tools/tape-rejections.sh lists closed issues labelled `rejected`, then those
# labelled `prediction/dismissed`
# (forge_api GET "/issues?state=closed&type=issues&labels=<label>&limit=50",
# every page). An issue is skipped when ${TAPE_DIR}/rejected/issue-<N> exists
# or the tape already holds a proposal whose ref is <N> (any loop). Otherwise
# it appends
#   tape_proposal "$id" dev "$class" "" "" '{}' "" rejected "<N>"
# and touches the marker. class is the milestone's class line, unclassed when
# that line is absent, backlog when there is no milestone.
#
# gardener/gardener-run.sh calls the tool right after tools/sprint-outcomes.sh
# (#1676). A non-zero exit only logs a warning.
#
# Hermetic: no network, stubbed forge_api, temp TAPE_DIR with a fixture tape.
#
# Acceptance: `bash tests/acceptance/issue-1631.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq flock grep mktemp touch
ac_assert_file "$REPO_ROOT/tools/tape-rejections.sh" "tools/tape-rejections.sh is missing"
ac_assert_file "$REPO_ROOT/lib/tape.sh" "lib/tape.sh is missing"
ac_assert_file "$REPO_ROOT/lib/sprint-block.sh" "lib/sprint-block.sh is missing"
ac_assert_file "$REPO_ROOT/gardener/gardener-run.sh" "gardener/gardener-run.sh is missing"
ac_assert_file "$REPO_ROOT/gardener/AGENTS.md" "gardener/AGENTS.md is missing"

# The review (formula 3b) requires this sentence after refresh_ops_calibration.
# #1885 places it in the script's tool order: after sprint-outcomes.sh and
# before claim-proposals.sh. Wrapping is allowed.
# shellcheck disable=SC2016  # backticks are markdown in the required sentence
DOC_SENTENCE='Then `tools/tape-rejections.sh` (#1631) records each closed `rejected` or `prediction/dismissed` issue the tape does not hold yet as a rejected dev proposal. A failure only logs a warning.'
AGENTS_FLAT="$(tr '\n' ' ' < "$REPO_ROOT/gardener/AGENTS.md" | tr -s ' ')"
printf '%s\n' "$AGENTS_FLAT" | grep -qF "$DOC_SENTENCE" \
  || ac_fail "gardener/AGENTS.md must describe tape-rejections.sh (#1631)"
CAL_DOC=$(grep -n 'refresh_ops_calibration`, #1454' "$REPO_ROOT/gardener/AGENTS.md" | head -n1 | cut -d: -f1)
SO_DOC=$(grep -n 'tools/sprint-outcomes.sh` (#1676)' "$REPO_ROOT/gardener/AGENTS.md" | head -n1 | cut -d: -f1)
REJ_DOC=$(grep -n 'tools/tape-rejections.sh` (#1631)' "$REPO_ROOT/gardener/AGENTS.md" | head -n1 | cut -d: -f1)
CLAIM_DOC=$(grep -n 'tools/claim-proposals.sh` (#1641)' "$REPO_ROOT/gardener/AGENTS.md" | head -n1 | cut -d: -f1)
[ -n "$CAL_DOC" ] || ac_fail "gardener/AGENTS.md must still name refresh_ops_calibration (#1454)"
[ -n "$SO_DOC" ] || ac_fail "gardener/AGENTS.md must still name tools/sprint-outcomes.sh (#1676)"
[ -n "$REJ_DOC" ] || ac_fail "gardener/AGENTS.md must name tools/tape-rejections.sh (#1631)"
[ -n "$CLAIM_DOC" ] || ac_fail "gardener/AGENTS.md must still name tools/claim-proposals.sh (#1641)"
[ "$CAL_DOC" -lt "$REJ_DOC" ] \
  || ac_fail "tape-rejections sentence (line $REJ_DOC) must follow refresh_ops_calibration (line $CAL_DOC)"
[ "$SO_DOC" -lt "$REJ_DOC" ] \
  || ac_fail "tape-rejections sentence (line $REJ_DOC) must follow sprint-outcomes.sh (line $SO_DOC)"
[ "$REJ_DOC" -lt "$CLAIM_DOC" ] \
  || ac_fail "tape-rejections sentence (line $REJ_DOC) must precede claim-proposals.sh (line $CLAIM_DOC)"
ac_log "docs OK: tape-rejections.sh follows sprint-outcomes.sh"

# Wiring: the call sits after sprint-outcomes.sh (#1676) and before
# claim-proposals.sh, and a non-zero exit is a warning, not fatal under set -e.
GARDENER="$REPO_ROOT/gardener/gardener-run.sh"
SO_LINE=$(grep -n 'tools/sprint-outcomes.sh' "$GARDENER" | grep '||' | head -n1 | cut -d: -f1)
TR_LINE=$(grep -n 'tools/tape-rejections.sh' "$GARDENER" | grep '||' | head -n1 | cut -d: -f1)
CLAIM_LINE=$(grep -n 'tools/claim-proposals.sh' "$GARDENER" | grep '||' | head -n1 | cut -d: -f1)
[ -n "$SO_LINE" ] || ac_fail "gardener-run.sh must call tools/sprint-outcomes.sh"
[ -n "$TR_LINE" ] || ac_fail "gardener-run.sh must call tools/tape-rejections.sh"
[ -n "$CLAIM_LINE" ] || ac_fail "gardener-run.sh must call tools/claim-proposals.sh"
[ "$SO_LINE" -lt "$TR_LINE" ] \
  || ac_fail "tape-rejections.sh (line $TR_LINE) must follow sprint-outcomes.sh (line $SO_LINE)"
[ "$TR_LINE" -lt "$CLAIM_LINE" ] \
  || ac_fail "tape-rejections.sh (line $TR_LINE) must precede claim-proposals.sh (line $CLAIM_LINE)"
grep -F 'tools/tape-rejections.sh' "$GARDENER" | grep -q '||' \
  || ac_fail "tape-rejections.sh must be guarded so a non-zero exit does not abort"
grep -qF 'tape-rejections.sh failed' "$GARDENER" \
  || ac_fail "a non-zero tape-rejections.sh must log a warning"
ac_log "wiring OK: tape-rejections.sh follows sprint-outcomes.sh and a failure only warns"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

STUB_BIN="$TMP_DIR/bin"
mkdir -p "$STUB_BIN"
CALLS="$TMP_DIR/calls"
: >"$CALLS"

# forge_api stub: closed issues by label and page. Page 1 of `rejected` is a
# full page (50) of issue 6, which the tape already holds, so page 2 must be
# fetched. prediction/dismissed is a separate listing.
cat >"$STUB_BIN/forge_api" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Record the call, then accept only the documented list path.
printf '%s\n' "$*" >> "${FORGE_CALLS:?}"
got_method="${1:-}"
got_path="${2:-}"
if [ "$got_method" != "GET" ]; then
  echo "stub: refused method ${got_method}" >&2
  exit 1
fi
# Path shape from the issue: labels=<label>&limit=50, plus &page=N.
prefix="/issues?state=closed&type=issues&labels="
rest="${got_path#"$prefix"}"
if [ "$rest" = "$got_path" ] || [[ "$rest" != *'&limit=50&page='* ]]; then
  echo "stub: unexpected path ${got_path}" >&2
  exit 1
fi
label="${rest%%&limit=50&page=*}"
page="${rest#*&limit=50&page=}"
if [ "$label" = "rejected" ] && [ "$page" = "1" ]; then
  jq -n '[range(50) | {number:6, state:"closed"}]'
  exit 0
fi
if [ "$label" = "rejected" ] && [ "$page" = "2" ]; then
  jq -n '[
    {number:5, state:"closed"},
    {number:11, state:"closed", milestone:{id:2, description:"soak: 7d\n"}}
  ]'
  exit 0
fi
if [ "$label" = "prediction/dismissed" ] && [ "$page" = "1" ]; then
  jq -n '[
    {number:9, state:"closed", milestone:{id:4, description:"class: deploy\neffect: none\nsoak: 7d\n"}},
    {number:12, state:"closed"}
  ]'
  exit 0
fi
if [ "$page" = "3" ] || { [ "$label" = "prediction/dismissed" ] && [ "$page" = "2" ]; }; then
  printf '%s\n' '[]'
  exit 0
fi
echo "stub: unhandled label=${label} page=${page}" >&2
exit 1
EOF
chmod +x "$STUB_BIN/forge_api"

TAPE_DIR="$TMP_DIR/tape"
mkdir -p "$TAPE_DIR/rejected"
# Issue 6 already has a proposal (any loop — here repair, not dev). Issue 12
# is skipped by the marker alone, with no proposal on the tape.
jq -cn \
  '{type:"proposal",t:"2026-01-01T00:00:00Z",id:"pre-6",loop:"repair",
    class:"internal",context:{},decision:"approved",ref:"6"}' \
  >"$TAPE_DIR/tape.jsonl"
touch "$TAPE_DIR/rejected/issue-12"

# run — execute the tool. RC is the exit code.
run() {
  RC=0
  env -u FORGE_API -u FORGE_TOKEN \
    TAPE_DIR="$TAPE_DIR" \
    PATH="$STUB_BIN:${PATH}" \
    FORGE_CALLS="$CALLS" \
    bash "$REPO_ROOT/tools/tape-rejections.sh" \
    >"$TMP_DIR/out" 2>"$TMP_DIR/err" || RC=$?
}

# prop_of REF — the proposal record whose ref is REF (empty when absent).
prop_of() {
  jq -c --arg ref "$1" 'select(.type == "proposal" and .ref == $ref)' \
    "$TAPE_DIR/tape.jsonl" 2>/dev/null | tail -n 1
}

# count_ref REF — how many proposal records name REF.
count_ref() {
  jq -c --arg ref "$1" 'select(.type == "proposal" and .ref == $ref)' \
    "$TAPE_DIR/tape.jsonl" 2>/dev/null | grep -c . || true
}

# ── AC1–AC3: one run covers the fixture cases ───────────────────────────────
ac_log "AC1: closed rejected issue 5, no proposal for ref 5, class backlog"
run
ac_assert_eq "$RC" "0" "tool must exit 0 (rc=$RC): $(cat "$TMP_DIR/err" 2>/dev/null || true)"

# Every page: a full first page must be followed by page 2, and rejected
# listings come before prediction/dismissed.
grep -qF 'labels=rejected&limit=50&page=1' "$CALLS" \
  || ac_fail "must list closed rejected issues (page 1, limit 50)"
grep -qF 'labels=rejected&limit=50&page=2' "$CALLS" \
  || ac_fail "must fetch every page of closed rejected issues (page 2 missing)"
grep -qF 'labels=prediction/dismissed&limit=50&page=1' "$CALLS" \
  || ac_fail "must list closed prediction/dismissed issues"
rej_page2=$(grep -n 'labels=rejected&limit=50&page=2' "$CALLS" | head -n1 | cut -d: -f1)
dis_page1=$(grep -n 'labels=prediction/dismissed&limit=50&page=1' "$CALLS" | head -n1 | cut -d: -f1)
if [ -z "$rej_page2" ] || [ -z "$dis_page1" ] || [ "$rej_page2" -ge "$dis_page1" ]; then
  ac_fail "rejected pages must be listed before prediction/dismissed"
fi

prop5="$(prop_of 5)"
[ -n "$prop5" ] || ac_fail "AC1: no proposal for ref 5"
ac_assert_eq "$(jq -r '.loop' <<<"$prop5")" "dev" "AC1: loop must be dev"
ac_assert_eq "$(jq -r '.decision' <<<"$prop5")" "rejected" "AC1: decision must be rejected"
ac_assert_eq "$(jq -r '.ref' <<<"$prop5")" "5" "AC1: ref must be 5"
ac_assert_eq "$(jq -r '.class' <<<"$prop5")" "backlog" "AC1: class must be backlog (no milestone)"
ac_assert_eq "$(jq -r '.context | type' <<<"$prop5")" "object" "AC1: context must be an object"
ac_assert_eq "$(jq -r 'has("forecast")' <<<"$prop5")" "false" "AC1: a rejected proposal carries no forecast"
ac_assert_eq "$(jq -r 'has("parent")' <<<"$prop5")" "false" "AC1: a rejected proposal carries no parent"
[ -f "$TAPE_DIR/rejected/issue-5" ] || ac_fail "AC1: marker rejected/issue-5 must exist"
ac_assert_eq "$(count_ref 5)" "1" "AC1: exactly one proposal for ref 5"

# ── AC2: a closed rejected issue whose number already has a proposal ────────
ac_log "AC2: issue 6 already has a proposal (loop repair) — nothing appended"
ac_assert_eq "$(count_ref 6)" "1" "AC2: the pre-existing proposal must be the only one for ref 6"
ac_assert_eq "$(jq -r '.loop' <<<"$(prop_of 6)")" "repair" \
  "AC2: the existing proposal must be left as it was (any loop)"
[ ! -f "$TAPE_DIR/rejected/issue-6" ] \
  || ac_fail "AC2: a skipped issue must not gain a marker"

# ── AC3: prediction/dismissed in a milestone whose class line is deploy ─────
ac_log "AC3: prediction/dismissed issue 9, milestone class deploy"
prop9="$(prop_of 9)"
[ -n "$prop9" ] || ac_fail "AC3: no proposal for ref 9"
ac_assert_eq "$(jq -r '.loop' <<<"$prop9")" "dev" "AC3: loop must be dev"
ac_assert_eq "$(jq -r '.decision' <<<"$prop9")" "rejected" "AC3: decision must be rejected"
ac_assert_eq "$(jq -r '.ref' <<<"$prop9")" "9" "AC3: ref must be 9"
ac_assert_eq "$(jq -r '.class' <<<"$prop9")" "deploy" "AC3: class must be deploy"
[ -f "$TAPE_DIR/rejected/issue-9" ] || ac_fail "AC3: marker rejected/issue-9 must exist"

# Milestone present, no class line: unclassed (the other half of the class rule).
prop11="$(prop_of 11)"
[ -n "$prop11" ] || ac_fail "issue 11 (milestone, no class line) must be recorded"
ac_assert_eq "$(jq -r '.class' <<<"$prop11")" "unclassed" \
  "a milestone with no class line must be unclassed"

# Marker skip: issue 12 had a marker and no tape proposal. Still none.
ac_assert_eq "$(count_ref 12)" "0" \
  "an issue whose marker exists must not be appended"

# ── AC4: a second run appends nothing ───────────────────────────────────────
ac_log "AC4: a second run appends nothing"
before="$(wc -l < "$TAPE_DIR/tape.jsonl" | tr -d ' ')"
: >"$CALLS"
run
ac_assert_eq "$RC" "0" "AC4: second run must exit 0 (rc=$RC)"
after="$(wc -l < "$TAPE_DIR/tape.jsonl" | tr -d ' ')"
ac_assert_eq "$after" "$before" \
  "AC4: a second run must append nothing (was $before lines, now $after)"
ac_assert_eq "$(count_ref 5)" "1" "AC4: ref 5 still has exactly one proposal"
ac_assert_eq "$(count_ref 9)" "1" "AC4: ref 9 still has exactly one proposal"

ac_pass "issue #1631: rejected issues reach the tape"
