#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2030.sh
#
# Issue #2030: feat(tools): sprint-held.sh reads whether a sprint's merges held.
#
# Contract under test (tools/sprint-held.sh SPRINT_ID):
#   * Children come from ${TAPE_DIR:-/srv/disinto/tape}/tape.jsonl: proposals
#     whose parent is SPRINT_ID whose LAST outcome in tape order carries
#     bits.merged 1 or true — the same rule tools/sprint-children.sh uses for
#     n_merged. Each child's ref is the issue number. Malformed lines are
#     skipped, not fatal.
#   * For each issue N, git log --merges --grep="from fix/issue-N(-[0-9]+)?
#     into " over SPRINT_HELD_REF (default HEAD) finds its merge commits; a
#     merge <sha> is reverted when the range <sha>..ref contains "This reverts
#     commit <sha>".
#   * Prints one word, rc 0: `broke` if some found merge is reverted, `held`
#     if at least one merge was found and none is reverted, `none` if no merge
#     was found.
#   * rc 1 with empty stdout when SPRINT_ID is empty, jq or git is missing,
#     PROJECT_REPO_ROOT is not a git checkout, or the tape cannot be read.
#
# Hermetic: a fixture git repo (git init -b main, one base commit, fix/issue-41
# and fix/issue-42-1 merged with --no-ff messages shaped like forge dev PR
# merges) and fixture tapes in a temp dir. No network, no live services.
#
# Acceptance:
#   AC1: merges for 41 and 42-1 on main, none reverted -> held, rc 0, even
#        with a malformed tape line.
#   AC2: a tape whose only merged child is 43 (no branch in git) -> none.
#   AC3: a sprint with no children -> none; SPRINT_HELD_REF=main reads the
#        same as the default HEAD.
#   AC4: after git revert -m 1 of 41's merge -> broke, rc 0.
#   AC5: empty SPRINT_ID -> rc 1, nothing printed; bash -n passes; a missing
#        tape -> rc 1.
#
# Run via: tools/run-acceptance.sh 2030
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq git
ac_assert_file "$REPO_ROOT/tools/sprint-held.sh" "tools/sprint-held.sh is missing"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Deterministic identity for the fixture commits.
export GIT_AUTHOR_NAME="ac-fixture" GIT_AUTHOR_EMAIL="ac@example.com"
export GIT_COMMITTER_NAME="ac-fixture" GIT_COMMITTER_EMAIL="ac@example.com"

# ── Fixture repo: main, then fix/issue-41 and fix/issue-42-1 merged --no-ff ──
REPO="$TMP_DIR/repo"
mkdir -p "$REPO"
git init -q -b main "$REPO"
git -C "$REPO" commit -q --allow-empty -m "base"

# merge_branch BRANCH MESSAGE — one commit on BRANCH, then a --no-ff merge
# onto main whose message reads like a forge dev PR merge commit. Echoes the
# merge commit sha.
merge_branch() {
  git -C "$REPO" checkout -q -b "$1" main
  echo "work on $1" > "$REPO/${1##*/}.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "work on $1"
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge -q --no-ff -m "$2" "$1"
  git -C "$REPO" log --merges -1 --format=%H
}
MERGE_41="$(merge_branch fix/issue-41 \
  "Merge pull request 'x (#41)' (#50) from fix/issue-41 into main")"
MERGE_42="$(merge_branch fix/issue-42-1 \
  "Merge pull request 'y (#42)' (#51) from fix/issue-42-1 into main")"
if [ -z "$MERGE_41" ] || [ -z "$MERGE_42" ]; then
  ac_fail "fixture merges are missing (41=$MERGE_41 42=$MERGE_42)"
fi

# ── Fixture tape: sprint S has children 41, 42 (merged) and 43 (merged, no
#    branch), plus a torn final line that must be skipped. ────────────────────
TAPE="$TMP_DIR/tape"
mkdir -p "$TAPE"
cat > "$TAPE/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-09T00:00:00Z","id":"p41","loop":"sprint","class":"internal","parent":"S","context":{},"decision":"approved","ref":"41"}
{"type":"proposal","t":"2026-02-09T00:01:00Z","id":"p42","loop":"sprint","class":"internal","parent":"S","context":{},"decision":"approved","ref":"42"}
{"type":"proposal","t":"2026-02-09T00:02:00Z","id":"p43","loop":"sprint","class":"internal","parent":"S","context":{},"decision":"approved","ref":"43"}
{"type":"outcome","t":"2026-02-09T01:00:00Z","proposal_id":"p41","bits":{"merged":1,"code_shipped":1},"numbers":{},"children":[],"payloads":[]}
{"type":"outcome","t":"2026-02-09T01:01:00Z","proposal_id":"p42","bits":{"merged":true},"numbers":{},"children":[],"payloads":[]}
{"type":"outcome","t":"2026-02-09T01:02:00Z","proposal_id":"p43","bits":{"merged":1},"numbers":{},"children":[],"payloads":[]}
{"type":"proposal","t":"2026-02-09T00:03:00Z","id":"p44","loop":"sprint","class":"internal","parent":"T","context":{},"decision":"approved","ref":"44"}
{"type":"outcome","t":"2026-02-09T01:03:00Z","proposal_id":"p44","bits":{"rejected":1},"numbers":{},"children":[],"payloads":[]}
{"type":
EOF

# run_held <tape_dir> <sprint_id> [ref] — run the tool against the fixture repo
# with TAPE_DIR and SPRINT_HELD_REF set; rc/out/err land in globals.
run_held() {
  local dir="$1" sprint="$2" ref="${3:-}"
  RC=0 OUT="" ERR=""
  # shellcheck disable=SC2034  # RC/OUT/ERR are consumed by the assertions below
  OUT="$(TAPE_DIR="$dir" PROJECT_REPO_ROOT="$REPO" SPRINT_HELD_REF="$ref" \
    bash "$REPO_ROOT/tools/sprint-held.sh" "$sprint" 2>"$TMP_DIR/err")" || RC=$?
  ERR="$(cat "$TMP_DIR/err" 2>/dev/null || true)"
}

expect_word() {
  local dir="$1" sprint="$2" word="$3" ref="${4:-}"
  run_held "$dir" "$sprint" "$ref"
  ac_assert_eq "$RC" "0" "sprint-held $sprint must exit 0 (got $RC): $OUT / $ERR"
  ac_assert_eq "$OUT" "$word" \
    "sprint-held $sprint must print '$word', got '$OUT' [stderr: $ERR]"
}

# ── AC1: both merges on main, none reverted -> held, despite the torn line ──
ac_log "AC1: both merges on main, none reverted -> held"
expect_word "$TAPE" "S" held
case "$ERR" in
  *"malformed line(s)"*) ;;
  *) ac_fail "AC1 must note the skipped malformed line on stderr, got: $ERR" ;;
esac

# ── AC2: only merged child is 43, which has no merge in git -> none ──────────
ac_log "AC2: merged child with no merge commit in git -> none"
TAPE2="$TMP_DIR/tape-43"
mkdir -p "$TAPE2"
cat > "$TAPE2/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-09T00:00:00Z","id":"p43","loop":"sprint","class":"internal","parent":"S","context":{},"decision":"approved","ref":"43"}
{"type":"outcome","t":"2026-02-09T01:02:00Z","proposal_id":"p43","bits":{"merged":1},"numbers":{},"children":[],"payloads":[]}
EOF
expect_word "$TAPE2" "S" none

# ── AC3: no children -> none; SPRINT_HELD_REF=main reads like the default ────
ac_log "AC3: a sprint with no children -> none; the ref seam reads the same"
expect_word "$TAPE" "NOSUCHSPRINT" none
expect_word "$TAPE" "S" held main

# ── AC4: revert 41's merge -> broke ───────────────────────────────────────────
ac_log "AC4: after reverting the merge of 41 -> broke"
git -C "$REPO" revert -m 1 --no-edit "$MERGE_41" >/dev/null
expect_word "$TAPE" "S" broke

# ── AC5: empty SPRINT_ID -> rc 1, nothing printed; bash -n passes ─────────────
ac_log "AC5: empty SPRINT_ID -> rc 1 with empty stdout"
run_held "$TAPE" ""
ac_assert_eq "$RC" "1" "sprint-held with no SPRINT_ID must exit 1 (got $RC)"
ac_assert_eq "$OUT" "" "sprint-held with no SPRINT_ID must print nothing (got '$OUT')"

bash -n "$REPO_ROOT/tools/sprint-held.sh" \
  || ac_fail "bash -n must pass on tools/sprint-held.sh"

# A missing tape is not readable: rc 1, empty stdout.
EMPTY_DIR="$TMP_DIR/tape-missing"
mkdir -p "$EMPTY_DIR"
run_held "$EMPTY_DIR" "S"
ac_assert_eq "$RC" "1" "sprint-held must exit 1 when the tape cannot be read (got $RC)"
ac_assert_eq "$OUT" "" "sprint-held must print nothing when the tape cannot be read (got '$OUT')"

# PROJECT_REPO_ROOT not a git checkout: rc 1, empty stdout.
RC=0 OUT=""
OUT="$(TAPE_DIR="$TAPE" PROJECT_REPO_ROOT="$TMP_DIR/not-a-repo" \
  bash "$REPO_ROOT/tools/sprint-held.sh" "S" 2>/dev/null)" || RC=$?
ac_assert_eq "$RC" "1" "sprint-held must exit 1 when PROJECT_REPO_ROOT is not a git checkout (got $RC)"
ac_assert_eq "$OUT" "" "sprint-held must print nothing for a non-checkout repo root (got '$OUT')"

ac_pass
