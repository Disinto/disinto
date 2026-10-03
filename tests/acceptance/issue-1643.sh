#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1643.sh
#
# Issue #1643: a claim that passes a full window is held.
#
# After a check that meets expect, tools/claim-checks.sh writes one outcome
# with bits {held: 1, contradicted: 0} when the tape has no outcome yet for
# the proposal and that proposal is older than sprint_duration_seconds of the
# claim's window. A proposal still inside the window gets no outcome. A later
# passing check, with held already on the tape, appends only its run. A later
# miss appends a contradicted outcome; the last outcome counts.
#
# gardener/AGENTS.md carries the #1643 sentence after the #1642 claim-checks
# sentence (review formula 3b).
#
# Hermetic: no network, no forge, no agent. Fixture probes live under a temp
# OPS_REPO_ROOT; the tape (back-dated proposal rows) and claim files live in
# temp dirs. The tool is executed, not sourced.
#
# Acceptance: `bash tests/acceptance/issue-1643.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq flock python3 timeout date
ac_assert_file "$REPO_ROOT/tools/claim-checks.sh" "tools/claim-checks.sh is missing"
ac_assert_file "$REPO_ROOT/gardener/AGENTS.md" "gardener/AGENTS.md is missing"

# The review (formula 3b) requires this sentence after the #1642 claim-checks
# sentence. Wrapping is allowed; the words must appear in this order.
# shellcheck disable=SC2016  # backticks are markdown in the required sentence
HELD_SENTENCE='A claim whose checks pass for its whole `window` gets a `held` outcome; checks go on, and a later miss still contradicts it (#1643).'
AGENTS_FLAT="$(tr '\n' ' ' < "$REPO_ROOT/gardener/AGENTS.md" | tr -s ' ')"
printf '%s\n' "$AGENTS_FLAT" | grep -qF "$HELD_SENTENCE" \
  || ac_fail "gardener/AGENTS.md must describe a held outcome (#1643)"
CHECK_DOC=$(grep -n 'tools/claim-checks.sh` (#1642)' "$REPO_ROOT/gardener/AGENTS.md" | head -n1 | cut -d: -f1)
HELD_DOC=$(grep -n '#1643' "$REPO_ROOT/gardener/AGENTS.md" | head -n1 | cut -d: -f1)
[ -n "$CHECK_DOC" ] || ac_fail "gardener/AGENTS.md must still name tools/claim-checks.sh (#1642)"
[ -n "$HELD_DOC" ] || ac_fail "gardener/AGENTS.md must name #1643"
[ "$CHECK_DOC" -lt "$HELD_DOC" ] \
  || ac_fail "held sentence (line $HELD_DOC) must follow the claim-checks sentence (line $CHECK_DOC)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

OPS_REPO_ROOT="$WORK/ops"
CLAIMS_DIR="$WORK/claims"
TAPE_DIR="$WORK/tape"
PAYLOAD_DIR="$WORK/payloads"
mkdir -p "$OPS_REPO_ROOT/probes" "$CLAIMS_DIR" "$TAPE_DIR/claims" "$PAYLOAD_DIR"
export OPS_REPO_ROOT CLAIMS_DIR TAPE_DIR PAYLOAD_DIR

# plant_claim ID CHECK — a valid claim, window 7d, expect "<= 0.2".
plant_claim() {
  local id="$1" check="$2"
  python3 - "$CLAIMS_DIR/${id}.toml" "$check" <<'PY'
import sys
path, check = sys.argv[1], sys.argv[2]
open(path, "w", encoding="utf-8").write(
    "\n".join([
        'statement = "the bound still holds"',
        'class = "internal"',
        f'check = "{check}"',
        'expect = "<= 0.2"',
        'window = "7d"',
        "rests_on = []",
        "",
    ])
)
PY
}

# plant_probe REL NUMBER — a non-executable probe that prints NUMBER.
plant_probe() {
  local rel="$1" number="$2" dest
  dest="$OPS_REPO_ROOT/$rel"
  mkdir -p "$(dirname "$dest")"
  printf '%s\n' '#!/usr/bin/env bash' "printf '%s\n' '$number'" >"$dest"
  chmod a-x "$dest"
}

# plant_proposal PID AGE_DAYS — one back-dated proposal row for PID.
plant_proposal() {
  local pid="$1" age_days="$2"
  python3 - "$TAPE_DIR/tape.jsonl" "$pid" "$age_days" <<'PY'
import json, sys, time
path, pid, age_days = sys.argv[1], sys.argv[2], int(sys.argv[3])
stamp = time.strftime(
    "%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(time.time()) - age_days * 86400)
)
row = {
    "type": "proposal",
    "t": stamp,
    "id": pid,
    "loop": "claim",
    "class": "internal",
    "context": {},
    "decision": "approved",
    "ref": "claims/bound.toml",
}
with open(path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(row, separators=(",", ":")) + "\n")
PY
}

# invoke_checks — run the tool. stdout -> $OUT, stderr -> $ERR, status -> $RC.
invoke_checks() {
  local err_file="$WORK/tool.err"
  : >"$err_file"
  set +e
  OUT="$(
    env OPS_REPO_ROOT="$OPS_REPO_ROOT" CLAIMS_DIR="$CLAIMS_DIR" \
      TAPE_DIR="$TAPE_DIR" PAYLOAD_DIR="$PAYLOAD_DIR" \
      bash "$REPO_ROOT/tools/claim-checks.sh" 2>"$err_file"
  )"
  RC=$?
  set -e
  ERR=""
  if [ -s "$err_file" ]; then
    ERR="$(cat "$err_file")"
  fi
}

# tally PID TYPE — how many tape records of TYPE sit under PID.
tally() {
  local pid="$1" kind="$2"
  jq -s --arg pid "$pid" --arg kind "$kind" \
    '[.[] | select(.proposal_id == $pid and .type == $kind)] | length' \
    "$TAPE_DIR/tape.jsonl"
}

# newest_outcome PID — the last outcome object for PID.
newest_outcome() {
  local pid="$1"
  jq -sc --arg pid "$pid" \
    '[.[] | select(.type == "outcome" and .proposal_id == $pid)] | last' \
    "$TAPE_DIR/tape.jsonl"
}

# ── AC1 + AC2 in one run: 8 days holds, 2 days does not ─────────────────────
ac_log "AC1/AC2: 8-day proposal meeting expect is held; 2-day proposal is not"
plant_claim bound-aged probes/aged.sh
plant_probe probes/aged.sh 0.1
printf '%s\n' pid-aged >"$TAPE_DIR/claims/bound-aged.current"
plant_proposal pid-aged 8

plant_claim bound-fresh probes/fresh.sh
plant_probe probes/fresh.sh 0.1
printf '%s\n' pid-fresh >"$TAPE_DIR/claims/bound-fresh.current"
plant_proposal pid-fresh 2

invoke_checks
ac_assert_eq "$RC" "0" "window check must return 0 (got $RC): $OUT | $ERR"
[ -z "$ERR" ] || ac_fail "window check must not print stderr (got: $ERR)"
ac_assert_eq "$(tally pid-aged run)" "1" "aged claim must append exactly one run"
ac_assert_eq "$(tally pid-aged outcome)" "1" "aged claim must append exactly one outcome"
ac_assert_jq \
  '.bits == {"held": 1, "contradicted": 0} and .numbers.value == 0.1 and .children == {} and .payloads == []' \
  "$(newest_outcome pid-aged)" \
  "8-day pass must be bits {held: 1, contradicted: 0} with value 0.1"
ac_assert_eq "$(tally pid-fresh run)" "1" "2-day claim must still record its run"
ac_assert_eq "$(tally pid-fresh outcome)" "0" "2-day claim must append no outcome"
ac_log "AC1/AC2 OK: held for 8 days, no outcome for 2 days"

# ── AC3: held already present, a passing check appends only its run ─────────
ac_log "AC3: with held present, a passing check appends only its run"
rm -f "$TAPE_DIR/claims/bound-aged.checked"
plant_probe probes/aged.sh 0.1
FRESH_RUNS="$(tally pid-fresh run)"
FRESH_OUTCOMES="$(tally pid-fresh outcome)"
invoke_checks
ac_assert_eq "$RC" "0" "recheck after held must return 0 (got $RC): $OUT | $ERR"
[ -z "$ERR" ] || ac_fail "recheck after held must not print stderr (got: $ERR)"
ac_assert_eq "$(tally pid-aged run)" "2" "passing recheck must append one more run"
ac_assert_eq "$(tally pid-aged outcome)" "1" "passing recheck must not append another outcome"
ac_assert_jq \
  '.bits == {"held": 1, "contradicted": 0}' \
  "$(newest_outcome pid-aged)" \
  "the only outcome must still be held"
ac_assert_eq "$(tally pid-fresh run)" "$FRESH_RUNS" \
  "the young claim must not be rechecked inside the interval"
ac_assert_eq "$(tally pid-fresh outcome)" "$FRESH_OUTCOMES" \
  "the young claim must still have no outcome"
ac_log "AC3 OK: passing recheck appended only its run"

# ── AC4: held already present, a miss appends a contradicted outcome ────────
ac_log "AC4: with held present, a missing check appends a contradicted outcome"
rm -f "$TAPE_DIR/claims/bound-aged.checked"
plant_probe probes/aged.sh 0.5
invoke_checks
ac_assert_eq "$RC" "0" "miss after held must return 0 (got $RC): $OUT | $ERR"
[ -z "$ERR" ] || ac_fail "miss after held must not print stderr (got: $ERR)"
ac_assert_eq "$(tally pid-aged run)" "3" "miss after held must append one more run"
ac_assert_eq "$(tally pid-aged outcome)" "2" "miss after held must append one contradicted outcome"
ac_assert_jq \
  '.bits == {"contradicted": 1, "held": 0} and .numbers.value == 0.5 and .children == {} and .payloads == []' \
  "$(newest_outcome pid-aged)" \
  "the last outcome must be contradicted with value 0.5"
ac_assert_jq \
  '.bits.held == 1 and .bits.contradicted == 0' \
  "$(jq -sc --arg pid pid-aged '[.[] | select(.type == "outcome" and .proposal_id == $pid)] | .[0]' "$TAPE_DIR/tape.jsonl")" \
  "the earlier held outcome must stay on the tape"
ac_log "AC4 OK: miss after held appended a contradicted outcome"

ac_pass
