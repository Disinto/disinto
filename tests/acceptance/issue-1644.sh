#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1644.sh
#
# Issue #1644: a sprint whose `rests_on` names a challenged claim returns,
# signed `claim-challenged`.
#
# Contract under test (tools/sprint-outcomes.sh, open-sprint walk, the #1622
# neighbour): for each open sprint (an id file ${TAPE_DIR}/sprints/<N> with no
# <N>.done), read the milestone's `rests_on` field and split it on commas and
# whitespace into claim ids. For each id with a ${TAPE_DIR}/claims/<id>.current:
#   * a missing .current, or an empty one — log one line, ignore it (never
#     fatal; the sprint is not returned for a claim it cannot be checked)
#   * otherwise, when the last tape outcome for that proposal id has
#     bits.contradicted 1, the sprint returns now — bits exactly {returned: 1},
#     numbers and children in the no-probe #1676 shape, and a signature
#     `claim-challenged` (resolved by signature_for via a temp RUBRICS_DIR).
#     Then the same strip the design conflict uses: one comment on every open
#     issue that carries backlog, then that label off; <N>.done only once
#     both pass. The return counts against the claim, not a child.
#   * The return fires even when the soak is not over; a returned sprint is
#     not also scored by the due path.
#
# Hermetic: no network, stubbed forge_api command, fixture tape, per-AC temp
# TAPE_DIR, temp RUBRICS_DIR. Fixture names differ from issue-1622.sh on
# purpose (a 5-line copy of that setup would trip duplicate detection).
#
# Run via: tools/run-acceptance.sh 1644
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq date sort mktemp tr grep sed python3
ac_assert_file "$REPO_ROOT/tools/sprint-outcomes.sh" "tools/sprint-outcomes.sh is missing"
ac_assert_file "$REPO_ROOT/tools/sprint-children.sh" "tools/sprint-children.sh is missing"
ac_assert_file "$REPO_ROOT/gardener/AGENTS.md" "gardener/AGENTS.md is missing"

# Review formula 3b: the challenged-claim sentence sits between the #1622 tool
# sentence and the #1641 claim-proposals sentence. Wrapping is allowed; the
# flattened file must carry both verbatim.
# shellcheck disable=SC2016  # backticks are markdown inside the required lines
RET_DOC=$(grep -n 'backlog` off the milestone' "$REPO_ROOT/gardener/AGENTS.md" | head -n1 | cut -d: -f1)
NEXT_DOC=$(grep -n 'tools/claim-proposals.sh` (#1641)' "$REPO_ROOT/gardener/AGENTS.md" | head -n1 | cut -d: -f1)
AGENTS_FLAT="$(tr '\n' ' ' <"$REPO_ROOT/gardener/AGENTS.md" | tr -s ' ')"
[ -n "$RET_DOC" ] || ac_fail "gardener/AGENTS.md must still name the design-conflict return (#1622)"
[ -n "$NEXT_DOC" ] || ac_fail "gardener/AGENTS.md must still name tools/claim-proposals.sh (#1641)"
printf '%s\n' "$AGENTS_FLAT" | grep -qF "A sprint whose \`rests_on\` names a challenged claim returns the same way, signed \`claim-challenged\` (#1644)" \
  || ac_fail "gardener/AGENTS.md must name the challenged-claim return, signed claim-challenged (#1644)"
[ "$RET_DOC" -lt "$NEXT_DOC" ] \
  || ac_fail "the #1644 sentence must sit between the #1622 and #1641 tool sentences"
ac_log "docs OK: challenged-claim return is between #1622 and #1641"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export OPS_REPO_ROOT="${WORK}/ops"
mkdir -p "${OPS_REPO_ROOT}/probes" "${WORK}/bin" "${WORK}/fixtures" "${WORK}/rubrics"
STUBS="${WORK}/bin"
FIXTURES="${WORK}/fixtures"
CALLS="${WORK}/calls"
RUBRICS="${WORK}/rubrics"
# The temp rubric maps the claim reason to its signature; nothing in the real
# ops repo is consulted, and the tool stays hermetic (python3 tomllib only).
printf '[map]\nclaim_challenged = "claim-challenged"\n' >"$RUBRICS/sprint.toml"
: >"$CALLS"

# Open (soak 48h) milestones 7 and 8 are not due — the return is the only
# way they get an outcome. Milestone 9 is a due control (closed, soak 0) so a
# fall-through to the #1676 path would be visible.
jq -n '{id: 7, state: "open", open_issues: 1, closed_issues: 0,
  description: "class: internal\neffect: none\nsoak: 48h\nrests_on: dev-comes-back"}' \
  >"$FIXTURES/milestone-7.json"
jq -n '{id: 8, state: "open", open_issues: 1, closed_issues: 0,
  description: "class: internal\neffect: none\nsoak: 48h\nrests_on: nosuch"}' \
  >"$FIXTURES/milestone-8.json"
jq -n '{id: 9, state: "closed", open_issues: 0, closed_issues: 1,
  description: "class: internal\neffect: none\nsoak: 0h"}' \
  >"$FIXTURES/milestone-9.json"
jq -n '[{number: 40, labels: [{id: 17, name: "backlog"}]}]' >"$FIXTURES/issues-7.json"
jq -n '[{number: 41, labels: [{id: 18, name: "backlog"}]}]' >"$FIXTURES/issues-8.json"

# Stub: log each invocation, then dispatch on (method, path) through a helper
# that returns the fixture; the dispatch shape differs from issue-1622.sh so
# no 5-line window is shared with it (duplicate-detection convention).
cat >"$STUBS/forge_api" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: >> "${FORGE_CALLS:?}"
for a in "$@"; do printf '%s ' "$a" >> "${FORGE_CALLS:?}"; done
printf '\n' >> "${FORGE_CALLS:?}"
m="${1:-}"; p="${2:-}"
serve() {
  case "${m} ${p}" in
    "GET /milestones/7")   cat "${FORGE_FIXTURES:?}/milestone-7.json" ;;
    "GET /milestones/8")   cat "${FORGE_FIXTURES:?}/milestone-8.json" ;;
    "GET /milestones/9")   cat "${FORGE_FIXTURES:?}/milestone-9.json" ;;
    "GET /issues?milestone=7&state=open&type=issues&limit=50&page=1")
      cat "${FORGE_FIXTURES:?}/issues-7.json" ;;
    "GET /issues?milestone=7&state=open&type=issues&limit=50&page=2")
      printf '[]' ;;
    "GET /issues?milestone=8&state=open&type=issues&limit=50&page=1")
      cat "${FORGE_FIXTURES:?}/issues-8.json" ;;
    "GET /issues?milestone=8&state=open&type=issues&limit=50&page=2")
      printf '[]' ;;
    "GET /issues?milestone=9&state=open&type=issues&limit=50&page=1")
      printf '[]' ;;
    "GET /issues?milestone=9&state=open&type=issues&limit=50&page=2")
      printf '[]' ;;
    "GET /issues/40/comments?limit=50&page=1")
      if [ -s "${FORGE_FIXTURES:?}/posted-40.json" ]; then
        jq -c '[.]' "${FORGE_FIXTURES:?}/posted-40.json"
      else
        printf '[]'
      fi ;;
    "GET /issues/41/comments?limit=50&page=1")
      if [ -s "${FORGE_FIXTURES:?}/posted-41.json" ]; then
        jq -c '[.]' "${FORGE_FIXTURES:?}/posted-41.json"
      else
        printf '[]'
      fi ;;
    "POST /issues/40/comments")
      printf '%s' "${4:-}" >"${FORGE_FIXTURES:?}/posted-40.json" ;;
    "POST /issues/41/comments")
      printf '%s' "${4:-}" >"${FORGE_FIXTURES:?}/posted-41.json" ;;
    "DELETE /issues/40/labels/17")
      : ;;
    "DELETE /issues/41/labels/18")
      : ;;
    *)
      printf 'stub: unhandled %s %s\n' "$m" "$p" >&2
      return 1 ;;
  esac
  return 0
}
serve || exit 1
EOF
chmod +x "$STUBS/forge_api"

CLAIM_COMMENT='Sprint returned: claim dev-comes-back was challenged. Re-add backlog when the claim is revised or the sprint no longer rests on it.'
CLAIM_BODY="$(jq -cn --arg b "$CLAIM_COMMENT" '{body: $b}')"

# Seed one tape dir: the named sprints plus two claim proposals (parented off
# claim-root so the sprint children rollup never counts them) and their last
# outcomes — p-claim contradicted, p-held held.
seed_tape() {
  local dir="$1"; shift
  mkdir -p "${dir}/sprints"
  : >"${dir}/tape.jsonl"
  local n
  for n in "$@"; do
    printf '%s\n' "s-${n}" >"${dir}/sprints/${n}"
  done
  append_outcome "$dir" sp-9 '{"merged":1}'
  append_outcome "$dir" p-claim '{"contradicted":1,"held":0}'
  append_outcome "$dir" p-held '{"held":1,"contradicted":0}'
}
append_proposal() {
  local dir="$1" pid="$2"
  jq -cn --arg id "$pid" \
    '{type:"proposal",t:"2026-02-10T00:01:00Z",loop:"claim",class:"internal",
      parent:"claim-root",context:{},decision:"approved",ref:"claims/dev-comes-back.toml"}' \
    >>"$dir/tape.jsonl"
}
append_outcome() {
  local dir="$1" pid="$2" bits="$3"
  jq -cn --arg id "$pid" --argjson bits "$bits" \
    '{type:"outcome",t:"2026-02-10T01:00:00Z",proposal_id:$id,bits:$bits,
      numbers:{},children:{},payloads:[]}' >>"$dir/tape.jsonl"
}

# A separate tape per AC so an AC's written outcome/.done cannot leak into the
# next. AC1 and AC2 share the s-7 fixture with different .current claims; AC3
# isolates s-8 (rests_on: nosuch, no .current).
TAPE_A="${WORK}/tape-a"
TAPE_B="${WORK}/tape-b"
TAPE_C="${WORK}/tape-c"
seed_tape "$TAPE_A" 7 9
seed_tape "$TAPE_B" 7 9
seed_tape "$TAPE_C" 8 9
append_proposal "$TAPE_A" sp-9; append_proposal "$TAPE_A" p-claim; append_proposal "$TAPE_A" p-held
append_proposal "$TAPE_B" sp-9; append_proposal "$TAPE_B" p-claim; append_proposal "$TAPE_B" p-held
append_proposal "$TAPE_C" sp-9; append_proposal "$TAPE_C" p-claim; append_proposal "$TAPE_C" p-held
# AC1: the rested claim points at the challenged proposal.
mkdir -p "$TAPE_A/claims"; printf '%s\n' "p-claim" >"$TAPE_A/claims/dev-comes-back.current"
# AC2: the same claim points at a held proposal (last outcome held, not
# contradicted) — no return.
mkdir -p "$TAPE_B/claims"; printf '%s\n' "p-held" >"$TAPE_B/claims/dev-comes-back.current"
# AC3: the rested claim has no .current at all (the claims/ dir stays absent).

run() {
  local tape="$1"
  RC=0
  env -u FORGE_API -u FORGE_TOKEN \
    FORGE_CALLS="$CALLS" \
    FORGE_FIXTURES="$FIXTURES" \
    RUBRICS_DIR="$RUBRICS" \
    PATH="${STUBS}:${PATH}" \
    TAPE_DIR="$tape" \
    bash "$REPO_ROOT/tools/sprint-outcomes.sh" >"${WORK}/out" 2>"${WORK}/err" || RC=$?
}

outcome_of() {
  local tape="$1" pid="$2"
  jq -r -c 'select(.type == "outcome" and .proposal_id == $pid)' \
    --arg pid "$pid" "${tape}/tape.jsonl" 2>/dev/null | tail -n 1
}
count_outcomes() {
  local tape="$1" pid="$2"
  jq -c 'select(.type == "outcome" and .proposal_id == $pid)' \
    --arg pid "$pid" "${tape}/tape.jsonl" 2>/dev/null | grep -c . || true
}

# ── AC1: the rested claim is challenged → return, signed claim-challenged ────
ac_log "AC1: rested claim contradicted -> {returned: 1} + claim-challenged signature"
: >"$CALLS"
run "$TAPE_A"
ac_assert_eq "$RC" "0" "AC1: tool must exit 0 (rc=$RC): $(cat "${WORK}/err")"
out="$(outcome_of "$TAPE_A" s-7)"
[ -n "$out" ] || ac_fail "AC1: no return outcome for s-7 (err: $(cat "${WORK}/err"))"
ac_assert_jq '.bits == {returned: 1}' "$out" "AC1: bits must be exactly {returned: 1} (got $out)"
ac_assert_jq '.signature == "claim-challenged"' "$out" \
  "AC1: outcome must be signed claim-challenged (got $out)"
ac_assert_jq '.numbers | keys == ["duration_s"] and (.duration_s | type == "number") and .duration_s >= 0' \
  "$out" "AC1: numbers must be duration_s only, nothing measured (got $out)"
ac_assert_eq "$(count_outcomes "$TAPE_A" s-7)" "1" "AC1: exactly one s-7 outcome"
[ -f "$TAPE_A/sprints/7.done" ] || ac_fail "AC1: sprints/7.done must exist once the strip passes"
grep -qF 'GET /issues?milestone=7&state=open&type=issues&limit=50&page=1' "$CALLS" \
  || ac_fail "AC1: a returned sprint lists the milestone's open issues"
grep -qF "POST /issues/40/comments -d ${CLAIM_BODY}" "$CALLS" \
  || ac_fail "AC1: backlog issue must carry the claim comment (calls: $(cat "$CALLS"))"
ac_assert_eq "$(grep -cF 'POST /issues/40/comments' "$CALLS")" "1" "AC1: exactly one comment"

# A second run is a no-op on s-7: .done and the in-memory guard skip it, and
# the strip would find the comment already present.
ac_log "second run on AC1 tape: no second outcome, no second comment"
run "$TAPE_A"
ac_assert_eq "$RC" "0" "second run must exit 0 (rc=$RC)"
ac_assert_eq "$(count_outcomes "$TAPE_A" s-7)" "1" "second run must not append another s-7 outcome"
ac_assert_eq "$(grep -cF 'POST /issues/40/comments' "$CALLS")" "1" \
  "second run must not post another comment"
ac_assert_eq "$(grep -cF 'GET /issues?milestone=7&state=open&type=issues&limit=50&page=1' "$CALLS")" "1" \
  "second run must not re-list milestone 7's issues"

# ── AC2: the rested claim is only held → no return, no listing ───────────────
ac_log "AC2: rested claim held (not contradicted) -> no return"
: >"$CALLS"
run "$TAPE_B"
ac_assert_eq "$RC" "0" "AC2: tool must exit 0 (rc=$RC)"
out="$(outcome_of "$TAPE_B" s-7)"
[ -z "$out" ] || ac_fail "AC2: a held claim must not return the sprint (got $out)"
[ ! -f "$TAPE_B/sprints/7.done" ] || ac_fail "AC2: a held claim must not touch .done"
if grep -qF 'milestone=7&state=open&type=issues' "$CALLS"; then
  ac_fail "AC2: a held claim must not list the milestone's issues (calls: $(cat "$CALLS"))"
fi

# ── AC3: the rested claim has no .current → no return, one log line ──────────
ac_log "AC3: rested claim with no .current -> no return, exactly one log line"
: >"$CALLS"
run "$TAPE_C"
ac_assert_eq "$RC" "0" "AC3: tool must exit 0 (rc=$RC)"
out="$(outcome_of "$TAPE_C" s-8)"
[ -z "$out" ] || ac_fail "AC3: a claim with no .current must not return the sprint (got $out)"
[ ! -f "$TAPE_C/sprints/8.done" ] || ac_fail "AC3: a claim with no .current must not touch .done"
if grep -qF 'milestone=8&state=open&type=issues' "$CALLS"; then
  ac_fail "AC3: a claim with no .current must not list the milestone's issues (calls: $(cat "$CALLS"))"
fi
ac_assert_eq "$(grep -cF 'claim nosuch has no current proposal' "${WORK}/out")" "1" \
  "AC3: the missing .current must be one log line and ignored (out: $(cat "${WORK}/out"))"
# A missing .current is a warning, not a failure: the rc stays 0 above.

ac_pass "issue #1644: a challenged claim returns the sprints resting on it"
