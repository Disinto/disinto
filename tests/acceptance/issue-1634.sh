#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1634.sh
#
# Issue #1634: proposals may carry payloads. The proposal text is what the
# read-time features derive from, and issues get edited after filing — so the
# tape proposal record gains an optional 10th argument, PAYLOADS_JSON, on
# tape_proposal (lib/tape.sh):
#   * an array of sha256 refs (64 lowercase hex), validated exactly like
#     tape_outcome's payloads;
#   * when given and non-empty, the record gains `payloads` after `ref`;
#   * when absent or [], the record is byte-identical to its pre-#1634 shape
#     (no `payloads` field at all).
#
# Hermetic: no network, no agent — a temp TAPE_DIR per scenario, lib/tape.sh
# sourced in a throwaway subshell (same pattern as the other tape tests,
# e.g. issue-1618.sh).
#
# Acceptance: `bash tests/acceptance/issue-1634.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq flock sha256sum
ac_assert_file "$REPO_ROOT/lib/tape.sh" "lib/tape.sh is missing"

# Two real sha256 refs (64 lowercase hex) for the happy path.
HEX1="$(printf 'payload-one' | sha256sum | cut -d' ' -f1)"
HEX2="$(printf 'payload-two' | sha256sum | cut -d' ' -f1)"

# run_proposal <tape_dir> <out_file> <err_file> [payloads-json]
# Source lib/tape.sh in a throwaway subshell with the scenario's TAPE_DIR and
# call tape_proposal with the proposal args. With a 4th positional, the
# optional 10th PAYLOADS_JSON argument is passed; without it, tape_proposal
# is invoked with exactly 9 args — the true "no 10th argument" path.
# tape_proposal prints nothing on stdout (the record lands in the tape), so
# the record is read back from $tape_dir/tape.jsonl into $LINE.
# stdout -> <out_file>, stderr -> <err_file>, exit status -> $RC.
run_proposal() {
  local tape_dir="$1" out_file="$2" err_file="$3"
  local args=(id-1 dev fix "" '' '{"k":"v"}' '' approved 'ref-1')
  if [ "$#" -ge 4 ]; then
    args+=("$4")
  fi
  RC=0
  (
    export TAPE_DIR="$tape_dir"
    # shellcheck source=../lib/tape.sh
    source "$REPO_ROOT/lib/tape.sh"
    tape_proposal "${args[@]}"
  ) >"$out_file" 2>"$err_file" || RC=$?
  OUT="$(cat "$out_file" 2>/dev/null)"
  ERR="$(cat "$err_file" 2>/dev/null)"
  # No tape line on the refusal paths — keep the assignment alive under set -e.
  LINE="$(tail -n1 "$tape_dir/tape.jsonl" 2>/dev/null || true)"
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ── AC1: a 10th argument ["<64 lowercase hex>"] gives a record with ─────────
# ─── that payloads array, placed after ref ───────────────────────────────────
ac_log "AC1: payload array appended as payloads after ref"
TAPE_1="$TMP_DIR/tape-1"
mkdir -p "$TAPE_1"
run_proposal "$TAPE_1" "$TMP_DIR/out-1" "$TMP_DIR/err-1" "[\"$HEX1\"]"
ac_assert_eq "$RC" "0" \
  "payloaded proposal must return 0 (got $RC): $OUT | $ERR"
ac_assert_eq "$(wc -l < "$TAPE_1/tape.jsonl")" "1" \
  "exactly one tape line after the payloaded call (got $(wc -l < "$TAPE_1/tape.jsonl"))"
ac_assert_jq ".type == \"proposal\" and .id == \"id-1\" and .loop == \"dev\" \
    and .class == \"fix\" and .context == {\"k\":\"v\"} \
    and .decision == \"approved\" and .ref == \"ref-1\" \
    and .payloads == [\"$HEX1\"] \
    and (has(\"parent\") | not) and (has(\"caused_by\") | not) \
    and (has(\"forecast\") | not)" "$LINE" \
  "record must be a dev proposal whose payloads array is exactly the 10th argument"
case "$LINE" in
  *'"decision":"approved","ref":"ref-1","payloads":["'"$HEX1"'"]}'*) ;;
  *) ac_fail "payloads must be the final field, right after ref; got: $LINE" ;;
esac

# ── AC2 (multi-ref): two valid refs both land in payloads ────────────────────
ac_log "AC2: a two-element payloads array is preserved"
TAPE_2="$TMP_DIR/tape-2"
mkdir -p "$TAPE_2"
run_proposal "$TAPE_2" "$TMP_DIR/out-2" "$TMP_DIR/err-2" "[\"$HEX1\",\"$HEX2\"]"
ac_assert_eq "$RC" "0" \
  "two-ref payloaded proposal must return 0 (got $RC): $OUT | $ERR"
ac_assert_eq "$(wc -l < "$TAPE_2/tape.jsonl")" "1" \
  "exactly one tape line (got $(wc -l < "$TAPE_2/tape.jsonl"))"
ac_assert_jq ".payloads == [\"$HEX1\",\"$HEX2\"]" "$LINE" \
  "record must carry exactly the two ref arrays in order"

# ── AC3: no 10th argument -> record identical to today's shape ───────────────
ac_log "AC3: a 9-argument call leaves the record at its pre-#1634 shape"
TAPE_3="$TMP_DIR/tape-3"
mkdir -p "$TAPE_3"
run_proposal "$TAPE_3" "$TMP_DIR/out-3" "$TMP_DIR/err-3"
ac_assert_eq "$RC" "0" \
  "plain proposal (no 10th argument) must return 0 (got $RC): $OUT | $ERR"
ac_assert_eq "$(wc -l < "$TAPE_3/tape.jsonl")" "1" \
  "exactly one tape line (got $(wc -l < "$TAPE_3/tape.jsonl"))"
ac_assert_jq "keys == [\"class\",\"context\",\"decision\",\"id\",\"loop\",\"ref\",\"t\",\"type\"]
    and (has(\"payloads\") | not)" "$LINE" \
  "plain proposal must carry exactly the pre-#1634 fields, no payloads"

# ── AC4 (issue body): [] also leaves the record unchanged ────────────────────
ac_log "AC4: a [] argument also leaves the record at its pre-#1634 shape"
TAPE_4="$TMP_DIR/tape-4"
mkdir -p "$TAPE_4"
run_proposal "$TAPE_4" "$TMP_DIR/out-4" "$TMP_DIR/err-4" "[]"
ac_assert_eq "$RC" "0" \
  "a [] payload argument must return 0 (got $RC): $OUT | $ERR"
ac_assert_eq "$(wc -l < "$TAPE_4/tape.jsonl")" "1" \
  "exactly one tape line (got $(wc -l < "$TAPE_4/tape.jsonl"))"
ac_assert_jq "keys == [\"class\",\"context\",\"decision\",\"id\",\"loop\",\"ref\",\"t\",\"type\"]
    and (has(\"payloads\") | not)" "$LINE" \
  "a [] payload argument must not add a payloads field"

# ── AC5: [\"nothex\"] returns 1 and appends nothing ───────────────────────────
ac_log "AC5: [\"nothex\"] returns 1 and appends nothing"
TAPE_5="$TMP_DIR/tape-5"
mkdir -p "$TAPE_5"
run_proposal "$TAPE_5" "$TMP_DIR/out-5" "$TMP_DIR/err-5" "[\"nothex\"]"
ac_assert_eq "$RC" "1" \
  "invalid payload ref must return 1 (got $RC): $OUT | $ERR"
[ -z "$OUT" ] || ac_fail "invalid payload ref must print nothing to stdout (got: $OUT)"
[ ! -e "$TAPE_5/tape.jsonl" ] || ac_fail "invalid payload ref must not append a record"

# ── the usage line now names the new argument ────────────────────────────────
ac_log "usage line mentions PAYLOADS_JSON"
grep -qF 'PAYLOADS_JSON' "$REPO_ROOT/lib/tape.sh" \
  || ac_fail "lib/tape.sh must mention PAYLOADS_JSON (usage line)"

ac_pass "issue #1634: tape_proposal accepts an optional payloads array"
