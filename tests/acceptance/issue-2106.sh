#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2106.sh
#
# Issue #2106: lib/rollout-evidence.sh writes the canary evidence the rollout
# tool (tools/rollout.sh, docs/design/notes/self-update.md "The flow") will
# one day read: one JSON line per take, per poll, per review poll's work, in
# ${TAPE_DIR}/rollout/evidence/<nomad job>.jsonl. Nothing calls it yet.
#
# Functions (sourced; pure bash + jq, no lib/env.sh):
#   rollout_evidence_file              -> the evidence file path
#   rollout_evidence_init              -> mkdir -p the dir; as root, touch the
#                                         file and chown agent:agent file, dir,
#                                         parent rollout/; always rc 0
#   rollout_evidence_take REF COMMIT SMOKE_RC [SMOKE_TAIL]
#   rollout_evidence_poll REF COMMIT ROLE RC
#   rollout_evidence_work ROLE DUE DONE FAILED
#     * rc 0: exactly one line appended, nothing printed on stdout
#     * rc 1, nothing written: REF/COMMIT/ROLE empty, or a non-^[0-9]+$ number
#     * t is a number (date -u +%s); smoke_tail (take) present iff SMOKE_RC != 0,
#       cut to the first 500 characters
#     * work's commit is git -C FACTORY_ROOT rev-parse HEAD, "unknown" if that fails
#     * cap: with ROLLOUT_EVIDENCE_MAX_B/ROLLOUT_EVIDENCE_KEEP set, the file is
#       rewritten in place (inode unchanged) to its last KEEP lines when it
#       exceeds MAX_B bytes
#
# Hermetic: no network, no forge, no nomad — a temp TAPE_DIR, NOMAD_JOB_NAME=
# agents-test and a temp git repo as FACTORY_ROOT (issue-2031.sh pattern).
#
# Acceptance: `bash tests/acceptance/issue-2106.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq git stat tail wc mktemp
ac_assert_file "$REPO_ROOT/lib/rollout-evidence.sh" "lib/rollout-evidence.sh is missing"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

EV_DIR="$TMP_DIR/tape"
EV_FILE="$EV_DIR/rollout/evidence/agents-test.jsonl"
GIT_DIR="$TMP_DIR/factory"
NOTGIT_DIR="$TMP_DIR/not-a-repo"
export TAPE_DIR="$EV_DIR"
export NOMAD_JOB_NAME=agents-test

# git fixture for the work line's commit.
mkdir -p "$GIT_DIR" "$NOTGIT_DIR"
git init -q "$GIT_DIR"
git -C "$GIT_DIR" config user.name "evidence-test"
git -C "$GIT_DIR" config user.email "evidence-test@example.com"
printf '# factory\n' >"$GIT_DIR/README.md"
git -C "$GIT_DIR" add -A
git -C "$GIT_DIR" commit -q -m "initial factory commit"
HEAD_SHA="$(git -C "$GIT_DIR" rev-parse HEAD)"

# run_ev <fn> [args...] — source lib/rollout-evidence.sh in a throwaway
# subshell with the current env and call <fn>. stdout -> $OUT, stderr -> $ERR,
# exit status -> $RC.
run_ev() {
  local fn="$1"
  shift
  RC=0 OUT="" ERR=""
  # shellcheck disable=SC2034  # RC/OUT/ERR are consumed by the assertions below
  (
    # shellcheck source=../lib/rollout-evidence.sh
    source "$REPO_ROOT/lib/rollout-evidence.sh"
    "$fn" "$@"
  ) >"$TMP_DIR/out" 2>"$TMP_DIR/err" || RC=$?
  OUT="$(cat "$TMP_DIR/out" 2>/dev/null)"
  ERR="$(cat "$TMP_DIR/err" 2>/dev/null)"
}

line_count() {
  wc -l <"$EV_FILE" 2>/dev/null | tr -d ' '
}

last_line() {
  tail -n 1 "$EV_FILE"
}

# AC: bash -n passes on the lib.
bash -n "$REPO_ROOT/lib/rollout-evidence.sh" || ac_fail "bash -n fails on lib/rollout-evidence.sh"

# AC: rollout_evidence_file prints <TAPE_DIR>/rollout/evidence/agents-test.jsonl.
run_ev rollout_evidence_file
ac_assert_eq "$RC" "0" "rollout_evidence_file failed: $ERR"
ac_assert_eq "$OUT" "$EV_FILE" "rollout_evidence_file printed '$OUT', expected '$EV_FILE'"

# AC: rollout_evidence_init returns 0 and creates the directory.
run_ev rollout_evidence_init
ac_assert_eq "$RC" "0" "rollout_evidence_init must always return 0 (got $RC): $ERR"
[ -d "$EV_DIR/rollout/evidence" ] || ac_fail "rollout_evidence_init did not create $EV_DIR/rollout/evidence"

# AC: take with smoke 0 appends one line: kind take, ref canary, smoke the
# number 0, t a number, no smoke_tail key; nothing printed on stdout.
run_ev rollout_evidence_take canary "$HEAD_SHA" 0
ac_assert_eq "$RC" "0" "rollout_evidence_take failed: $ERR"
ac_assert_eq "$OUT" "" "rollout_evidence_take must print nothing on stdout, got: $OUT"
ac_assert_eq "$(line_count)" "1" "take must append exactly one line"
ac_assert_jq '.kind == "take" and .ref == "canary" and .commit == "'"${HEAD_SHA}"'" and .smoke == 0 and (.smoke|type) == "number" and (.t|type) == "number" and (has("smoke_tail") == false)' \
  "$(last_line)" "take line malformed: $(last_line)"

# AC: take with smoke 1 and a 600-char tail writes smoke 1 and a smoke_tail
# of exactly 500 characters.
run_ev rollout_evidence_take canary "$HEAD_SHA" 1 "$(printf 'x%.0s' {1..600})"
ac_assert_eq "$RC" "0" "rollout_evidence_take with tail failed: $ERR"
ac_assert_eq "$(line_count)" "2" "second take must append exactly one more line"
ac_assert_jq '.smoke == 1 and has("smoke_tail") and (.smoke_tail|length) == 500' \
  "$(last_line)" "take line with tail malformed: $(last_line)"

# AC: poll appends kind poll, role review, rc 3.
run_ev rollout_evidence_poll canary "$HEAD_SHA" review 3
ac_assert_eq "$RC" "0" "rollout_evidence_poll failed: $ERR"
ac_assert_eq "$OUT" "" "rollout_evidence_poll must print nothing on stdout, got: $OUT"
ac_assert_eq "$(line_count)" "3" "poll must append exactly one line"
ac_assert_jq '.kind == "poll" and .role == "review" and .rc == 3 and (.rc|type) == "number" and .ref == "canary"' \
  "$(last_line)" "poll line malformed: $(last_line)"

# AC: work appends kind work whose commit is the FACTORY_ROOT repo's HEAD.
FACTORY_ROOT="$GIT_DIR" run_ev rollout_evidence_work review 2 1 1
ac_assert_eq "$RC" "0" "rollout_evidence_work failed: $ERR"
ac_assert_eq "$OUT" "" "rollout_evidence_work must print nothing on stdout, got: $OUT"
ac_assert_eq "$(line_count)" "4" "work must append exactly one line"
ac_assert_jq '.kind == "work" and .commit == "'"${HEAD_SHA}"'" and .role == "review" and .due == 2 and .done == 1 and .failed == 1' \
  "$(last_line)" "work line malformed: $(last_line)"

# AC: with FACTORY_ROOT not a git repo, work's commit is "unknown".
FACTORY_ROOT="$NOTGIT_DIR" run_ev rollout_evidence_work review 0 0 0
ac_assert_eq "$RC" "0" "rollout_evidence_work with a bad FACTORY_ROOT failed: $ERR"
ac_assert_jq '.kind == "work" and .commit == "unknown"' "$(last_line)" \
  "work line with a non-git FACTORY_ROOT must have commit unknown: $(last_line)"

# AC: a non-numeric rc returns 1 and leaves the file unchanged.
BEFORE="$(line_count)"
BEFORE_BYTES="$(wc -c <"$EV_FILE" | tr -d ' ')"
run_ev rollout_evidence_poll canary "$HEAD_SHA" review x
ac_assert_eq "$RC" "1" "poll with a non-numeric rc must return 1 (got $RC)"
ac_assert_eq "$(line_count)" "$BEFORE" "invalid poll must not append a line"
ac_assert_eq "$(wc -c <"$EV_FILE" | tr -d ' ')" "$BEFORE_BYTES" "invalid poll must not change the file"
run_ev rollout_evidence_take "" "$HEAD_SHA" 0
ac_assert_eq "$RC" "1" "take with an empty ref must return 1 (got $RC)"
run_ev rollout_evidence_work review 1 1 y
ac_assert_eq "$RC" "1" "work with a non-numeric failed must return 1 (got $RC)"
ac_assert_eq "$(line_count)" "$BEFORE" "invalid calls appended lines to the file"

# AC: the size cap keeps the last ROLLOUT_EVIDENCE_KEEP lines in place: same
# inode, exactly 3 lines, the last one the tenth poll.
INODE_BEFORE="$(stat -c %i "$EV_FILE")"
for i in 1 2 3 4 5 6 7 8 9 10; do
  ROLLOUT_EVIDENCE_MAX_B=200 ROLLOUT_EVIDENCE_KEEP=3 run_ev rollout_evidence_poll canary "commit-$i" review "$i"
  ac_assert_eq "$RC" "0" "capped poll $i failed: $ERR"
  ac_assert_eq "$OUT" "" "capped poll must print nothing on stdout, got: $OUT"
done
ac_assert_eq "$(line_count)" "3" "the cap must leave exactly ROLLOUT_EVIDENCE_KEEP=3 lines"
ac_assert_eq "$(stat -c %i "$EV_FILE")" "$INODE_BEFORE" "the cap must rewrite in place, keeping the inode"
ac_assert_jq '.kind == "poll" and .rc == 10 and .commit == "commit-10"' "$(last_line)" \
  "the last surviving line must be the tenth poll: $(last_line)"
# every surviving line is valid JSON of the poll shape
while IFS= read -r line; do
  ac_assert_jq '.kind == "poll" and (.rc|type) == "number"' "$line" "capped line malformed: $line"
done <"$EV_FILE"

# AC: the default cap (1 MiB) never triggers at this size: every line appended
# after the cap scenario stays in the file.
run_ev rollout_evidence_init
run_ev rollout_evidence_take default-cap "$HEAD_SHA" 0
run_ev rollout_evidence_poll default-cap "$HEAD_SHA" review 0
ac_assert_eq "$(line_count)" "5" "without ROLLOUT_EVIDENCE_MAX_B, nothing is trimmed"

echo PASS
