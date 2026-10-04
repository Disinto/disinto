#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1622.sh
#
# Issue #1622: feat(tools): a design-conflict rejection returns the sprint.
#
# Contract under test (tools/sprint-outcomes.sh, before the #1676 soak verdict):
#   For each open sprint (id file without .done), if any child's last outcome
#   has a signature listed in ${SPRINT_RETURN_SIGNATURES:-design-conflict}:
#     * one tape outcome with bits exactly {returned: 1} (no effect — nothing
#       was measured); numbers and children as the no-probe #1676 shape.
#     * forge_api GET "/issues?milestone=<N>&state=open&type=issues".
#       Each issue with the backlog label loses it and gets one comment:
#       "Sprint returned: #<child issue> reported a design conflict. Re-add backlog when the design is fixed."
#     * an issue without backlog (in-progress) is not touched.
#     * <N>.done is touched once the append and the label pass succeed.
#   A child whose last outcome is signed needs-ops does not return the sprint.
#   An earlier design-conflict outcome does not count once a later outcome
#   carries no return signature.
#
# Hermetic: no network, stubbed forge_api, fixture tape, temp TAPE_DIR.
#
# Run via: tools/run-acceptance.sh 1622
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq date sort mktemp grep
ac_assert_file "$REPO_ROOT/tools/sprint-outcomes.sh" "tools/sprint-outcomes.sh is missing"
ac_assert_file "$REPO_ROOT/tools/sprint-children.sh" "tools/sprint-children.sh is missing"
ac_assert_file "$REPO_ROOT/gardener/AGENTS.md" "gardener/AGENTS.md is missing"

# The review (formula 3b) requires this sentence after the #1676 sentence.
# Wrapping is allowed; the flattened file must still contain it verbatim.
# shellcheck disable=SC2016  # backticks are markdown in the required sentence
DOC_SENTENCE=$'It also returns an open sprint at once when a child\'s last outcome is signed with one of `SPRINT_RETURN_SIGNATURES` (default `design-conflict`), and takes `backlog` off the milestone\'s open issues (#1622).'
AGENTS_FLAT="$(tr '\n' ' ' <"$REPO_ROOT/gardener/AGENTS.md" | tr -s ' ')"
printf '%s\n' "$AGENTS_FLAT" | grep -qF "$DOC_SENTENCE" \
  || ac_fail "gardener/AGENTS.md must describe the design-conflict return (#1622)"
SO_DOC=$(grep -n 'tools/sprint-outcomes.sh` (#1676)' "$REPO_ROOT/gardener/AGENTS.md" | head -n1 | cut -d: -f1)
RET_DOC=$(grep -n 'SPRINT_RETURN_SIGNATURES' "$REPO_ROOT/gardener/AGENTS.md" | head -n1 | cut -d: -f1)
NEXT_DOC=$(grep -n 'tools/claim-proposals.sh` (#1641)' "$REPO_ROOT/gardener/AGENTS.md" | head -n1 | cut -d: -f1)
[ -n "$SO_DOC" ] || ac_fail "gardener/AGENTS.md must still name tools/sprint-outcomes.sh (#1676)"
[ -n "$RET_DOC" ] || ac_fail "gardener/AGENTS.md must name SPRINT_RETURN_SIGNATURES (#1622)"
[ -n "$NEXT_DOC" ] || ac_fail "gardener/AGENTS.md must still name tools/claim-proposals.sh (#1641)"
[ "$SO_DOC" -lt "$RET_DOC" ] \
  || ac_fail "return sentence (line $RET_DOC) must follow the #1676 sentence (line $SO_DOC)"
[ "$RET_DOC" -lt "$NEXT_DOC" ] \
  || ac_fail "return sentence (line $RET_DOC) must precede claim-proposals (line $NEXT_DOC)"
ac_log "docs OK: design-conflict return follows the #1676 sentence"

# Names differ from the #1676 fixture on purpose: a 5-line copy of that
# setup is a duplicate-detection failure.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export OPS_REPO_ROOT="${WORK}/ops"
STUB_BIN="${WORK}/bin"
FIXTURES="${WORK}/fixtures"
CALLS="${WORK}/calls"
mkdir -p "${OPS_REPO_ROOT}/probes" "$STUB_BIN" "$FIXTURES"
printf '%s\n' 'echo 5' >"${OPS_REPO_ROOT}/probes/five.sh"
: >"$CALLS"

# Milestone 9 is due (closed, soak 0, a probe that would met) so a fall-through
# to the #1676 path would write effect: 1. Milestones 7 and 8 are open, so the
# soak path writes nothing for them — a return is the only way they get an outcome.
jq -n '{id: 9, state: "closed", open_issues: 2, closed_issues: 1,
  description: "class: internal\neffect: probes/five.sh\nexpect: >= 3\nsoak: 0h"}' \
  >"$FIXTURES/milestone-9.json"
jq -n '{id: 8, state: "open", open_issues: 1, closed_issues: 0,
  description: "class: internal\neffect: none\nsoak: 48h"}' \
  >"$FIXTURES/milestone-8.json"
jq -n '{id: 7, state: "open", open_issues: 1, closed_issues: 0,
  description: "class: internal\neffect: none\nsoak: 48h"}' \
  >"$FIXTURES/milestone-7.json"
jq -n '[
  {number: 20, labels: [{id: 11, name: "backlog"}]},
  {number: 21, labels: [{id: 12, name: "in-progress"}]}
]' >"$FIXTURES/issues-9.json"

cat >"$STUB_BIN/forge_api" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FORGE_CALLS:?}"
method="${1:-}"
path="${2:-}"
case "${method} ${path}" in
  "GET /milestones/9") cat "${FORGE_FIXTURES:?}/milestone-9.json" ;;
  "GET /milestones/8") cat "${FORGE_FIXTURES:?}/milestone-8.json" ;;
  "GET /milestones/7") cat "${FORGE_FIXTURES:?}/milestone-7.json" ;;
  "GET /issues?milestone=9&state=open&type=issues")
    cat "${FORGE_FIXTURES:?}/issues-9.json"
    ;;
  "DELETE /issues/20/labels/11") ;;
  "POST /issues/20/comments") ;;
  *)
    echo "stub: unexpected ${method} ${path}" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$STUB_BIN/forge_api"

# append_proposal DIR ID PARENT REF
append_proposal() {
  local dir="$1" id="$2" parent="$3" ref="$4"
  jq -cn \
    --arg id "$id" --arg parent "$parent" --arg ref "$ref" \
    '{type:"proposal",t:"2026-02-10T00:00:00Z",id:$id,loop:"dev",
      class:"internal",parent:$parent,context:{},decision:"approved",
      ref:$ref}' >>"$dir/tape.jsonl"
}

# append_outcome DIR PID BITS_JSON [SIGNATURE]
append_outcome() {
  local dir="$1" pid="$2" bits="$3" sig="${4:-}"
  if [ -n "$sig" ]; then
    jq -cn --arg id "$pid" --argjson bits "$bits" --arg sig "$sig" \
      '{type:"outcome",t:"2026-02-10T01:00:00Z",proposal_id:$id,
        bits:$bits,numbers:{},children:{},payloads:[],signature:$sig}' \
      >>"$dir/tape.jsonl"
  else
    jq -cn --arg id "$pid" --argjson bits "$bits" \
      '{type:"outcome",t:"2026-02-10T01:00:00Z",proposal_id:$id,
        bits:$bits,numbers:{},children:{},payloads:[]}' \
      >>"$dir/tape.jsonl"
  fi
}

TAPEDIR="${WORK}/tape"
mkdir -p "$TAPEDIR/sprints"
: >"$TAPEDIR/tape.jsonl"
printf '%s\n' "s-9" >"$TAPEDIR/sprints/9"
printf '%s\n' "s-8" >"$TAPEDIR/sprints/8"
printf '%s\n' "s-7" >"$TAPEDIR/sprints/7"

# Sprint 9: last outcome is design-conflict. Ref 10 is the child issue.
append_proposal "$TAPEDIR" c9 s-9 10
append_outcome "$TAPEDIR" c9 '{"merged":0}'
append_outcome "$TAPEDIR" c9 '{"rejected":1}' design-conflict

# Sprint 8: needs-ops must not return the sprint.
append_proposal "$TAPEDIR" c8 s-8 30
append_outcome "$TAPEDIR" c8 '{"rejected":1}' needs-ops

# Sprint 7: an earlier design-conflict is not the last outcome.
append_proposal "$TAPEDIR" c7 s-7 40
append_outcome "$TAPEDIR" c7 '{"rejected":1}' design-conflict
append_outcome "$TAPEDIR" c7 '{"merged":1}'

COMMENT='Sprint returned: #10 reported a design conflict. Re-add backlog when the design is fixed.'

run() {
  RC=0
  env -u FORGE_API -u FORGE_TOKEN \
    FORGE_CALLS="$CALLS" \
    FORGE_FIXTURES="$FIXTURES" \
    PATH="${STUB_BIN}:${PATH}" \
    TAPE_DIR="$TAPEDIR" \
    bash "$REPO_ROOT/tools/sprint-outcomes.sh" >"${WORK}/out" 2>"${WORK}/err" || RC=$?
}

outcome_of() {
  local pid="$1"
  jq -r -c 'select(.type == "outcome" and .proposal_id == $pid)' \
    --arg pid "$pid" \
    "$TAPEDIR/tape.jsonl" 2>/dev/null | tail -n 1
}

count_outcomes() {
  local pid="$1"
  jq -c 'select(.type == "outcome" and .proposal_id == $pid)' \
    --arg pid "$pid" \
    "$TAPEDIR/tape.jsonl" 2>/dev/null | grep -c . || true
}

# ── AC1: design-conflict returns the sprint; backlog sibling is pulled ──────
ac_log "AC1: design-conflict child + backlog sibling -> {returned: 1}, label off, one comment"
run
ac_assert_eq "$RC" "0" "AC1: tool must exit 0 (rc=$RC): $(cat "${WORK}/out" 2>/dev/null)"
out="$(outcome_of s-9)"
[ -n "$out" ] || ac_fail "AC1: no outcome for s-9"
ac_assert_jq '.bits == {returned: 1}' "$out" \
  "AC1: bits must be exactly {returned: 1} (got $out)"
ac_assert_jq '.numbers | keys == ["duration_s"] and (.duration_s | type == "number") and .duration_s >= 0' \
  "$out" "AC1: numbers must be duration_s only (nothing was measured) (got $out)"
ac_assert_jq '.children.n_children == 1 and .children.n_rejected == 1 and .children.n_failed == 0' \
  "$out" "AC1: children rollup must count the design-conflict child (got $out)"
ac_assert_eq "$(count_outcomes s-9)" "1" "AC1: exactly one sprint outcome"
[ -f "$TAPEDIR/sprints/9.done" ] || ac_fail "AC1: sprints/9.done must exist"
grep -qF 'GET /issues?milestone=9&state=open&type=issues' "$CALLS" \
  || ac_fail "AC1: must list the milestone's open issues"
grep -qF 'DELETE /issues/20/labels/11' "$CALLS" \
  || ac_fail "AC1: backlog sibling must lose the backlog label"
grep -qF "POST /issues/20/comments -d {\"body\":\"${COMMENT}\"}" "$CALLS" \
  || ac_fail "AC1: backlog sibling must get the return comment (calls: $(cat "$CALLS"))"
ac_assert_eq "$(grep -cF 'POST /issues/20/comments' "$CALLS")" "1" \
  "AC1: exactly one comment"

# ── AC2: in-progress sibling is not touched ─────────────────────────────────
ac_log "AC2: in-progress sibling is not touched"
if grep -qF '/issues/21' "$CALLS"; then
  ac_fail "AC2: in-progress issue #21 must not be touched (calls: $(cat "$CALLS"))"
fi

# ── AC3: needs-ops does not return the sprint ───────────────────────────────
ac_log "AC3: needs-ops does not return the sprint"
[ -z "$(outcome_of s-8)" ] || ac_fail "AC3: needs-ops must not write a sprint outcome"
[ ! -f "$TAPEDIR/sprints/8.done" ] || ac_fail "AC3: needs-ops must not touch .done"
if grep -qF 'milestone=8&' "$CALLS"; then
  ac_fail "AC3: needs-ops must not list the milestone's issues"
fi

# An earlier design-conflict is not the last outcome, so sprint 7 stays open.
[ -z "$(outcome_of s-7)" ] || ac_fail "last outcome without a return signature must not return the sprint"
[ ! -f "$TAPEDIR/sprints/7.done" ] || ac_fail "sprint 7 must not be marked done"
if grep -qF 'milestone=7&' "$CALLS"; then
  ac_fail "an earlier design-conflict must not list the milestone's issues"
fi

# A second run writes no second outcome and posts no second comment.
ac_log "second run: no second outcome, no second comment"
run
ac_assert_eq "$RC" "0" "second run must exit 0 (rc=$RC)"
ac_assert_eq "$(count_outcomes s-9)" "1" "second run must not write another outcome"
ac_assert_eq "$(grep -cF 'POST /issues/20/comments' "$CALLS")" "1" \
  "second run must not post another comment"

ac_pass "issue #1622: a design-conflict rejection returns the sprint"
