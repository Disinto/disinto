#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1440.sh
#
# Issue #1440: dev-agent.sh passes the pick's proposal id into the
# formula-session tape run: when the id file dev-poll wrote at pick time
# (#1398) — /tmp/dev-proposal-id-${PROJECT_NAME:-default}-<issue>, contents
# just the id — exists and is non-empty, dev-agent exports TAPE_PROPOSAL_ID
# before formula_session_start "dev", so formula-session (#1391) attaches
# the run record to that proposal instead of a fresh ULID. Missing or
# empty id file → TAPE_PROPOSAL_ID stays unset and the run keys on its
# own ULID (pre-#1398 behavior). No proposal record is created in
# dev-agent.sh.
#
# Acceptance (read-only — no agents started; the export block is extracted
# from dev/dev-agent.sh and exercised in a subshell with a sentinel
# PROJECT_NAME and fake id files):
#   1. wiring: dev-agent.sh reads the id file at the exact project-scoped
#      path used by the #1398 writer in dev-poll.sh, exports
#      TAPE_PROPOSAL_ID, and the export precedes formula_session_start
#   2. with a non-empty id file present, the block exports
#      TAPE_PROPOSAL_ID with exactly the file's contents
#   3. with the id file missing, empty, or whitespace-only,
#      TAPE_PROPOSAL_ID stays unset
#   4. dev-agent.sh creates no proposal record itself (no tape_proposal
#      call)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk

TARGET="$REPO_ROOT/dev/dev-agent.sh"
ac_assert_file "$TARGET" "dev/dev-agent.sh must exist"

# ── 1. Wiring: same project-scoped id-file path as the #1398 writer ────────
# Fixed-string pattern, not an expansion — disable SC2016.
# shellcheck disable=SC2016
ID_FILE_PATTERN='dev-proposal-id-${PROJECT_NAME:-default}-${ISSUE}'
grep -qF "$ID_FILE_PATTERN" "$TARGET" \
  || ac_fail "dev-agent.sh must read the pick id file at /tmp/${ID_FILE_PATTERN}"
grep -qF 'export TAPE_PROPOSAL_ID' "$TARGET" \
  || ac_fail "dev-agent.sh must export TAPE_PROPOSAL_ID from the id file's contents"

EXPORT_LINE="$(grep -nF 'export TAPE_PROPOSAL_ID' "$TARGET" | head -n 1 | cut -d: -f1)"
START_LINE="$(grep -nF 'formula_session_start "dev"' "$TARGET" | head -n 1 | cut -d: -f1)"
[ -n "$EXPORT_LINE" ] || ac_fail "could not find the TAPE_PROPOSAL_ID export line"
[ -n "$START_LINE" ] || ac_fail "could not find formula_session_start \"dev\""
[ "$EXPORT_LINE" -lt "$START_LINE" ] \
  || ac_fail "the TAPE_PROPOSAL_ID export (line $EXPORT_LINE) must precede formula_session_start \"dev\" (line $START_LINE)"

# The id file is written with the same project-scoped pattern by the #1398
# writer in dev-poll.sh — the two must agree or the pick never pairs.
# shellcheck disable=SC2016
grep -qF 'dev-proposal-id-${PROJECT_NAME:-default}-' "$REPO_ROOT/dev/dev-poll.sh" \
  || ac_fail "dev-poll.sh must still write the project-scoped id file"

# ── 4. No proposal record created in dev-agent.sh ──────────────────────────
if grep -q 'tape_proposal' "$TARGET"; then
  ac_fail "dev-agent.sh must not create a proposal record (no tape_proposal call)"
fi

# ── 2-3. Behavior: extract the export block and run it in a subshell ───────
# The block is top-level in dev-agent.sh: from the PROPOSAL_ID_FILE=
# assignment to its closing column-0 `fi`.
BLOCK="$(awk '
  /^PROPOSAL_ID_FILE=/ { grab = 1 }
  grab { print }
  grab && /^fi$/ { exit }
' "$TARGET")"
[ -n "$BLOCK" ] || ac_fail "could not extract the TAPE_PROPOSAL_ID export block from dev-agent.sh"

PROJECT_NAME="acceptance-1440"   # sentinel — can never clobber a live id file
trap 'rm -f /tmp/dev-proposal-id-acceptance-1440-9996 \
  /tmp/dev-proposal-id-acceptance-1440-9997 \
  /tmp/dev-proposal-id-acceptance-1440-9998 \
  /tmp/dev-proposal-id-acceptance-1440-9999' EXIT

# run_block <issue> — run the extracted block in a throwaway subshell with
# the sentinel PROJECT_NAME, a fake ISSUE, and TAPE_PROPOSAL_ID unset;
# prints the block's output plus the resulting TAPE_PROPOSAL_ID
# (<unset> when the block left it unset).
run_block() {
  local issue="$1"
  BLOCK_SRC="$BLOCK" PROJECT_NAME="$PROJECT_NAME" ISSUE="$issue" bash -c '
    set -u
    log() { echo "agent: $*"; }
    eval "$BLOCK_SRC"
    printf "TAPE_PROPOSAL_ID=%s\n" "${TAPE_PROPOSAL_ID:-<unset>}"
  ' 2>&1
}

# ── 2. Non-empty id file → TAPE_PROPOSAL_ID equals the file's contents ─────
ID="4eadbd3a-1234-5678-9abc-def012345678"
printf '%s' "$ID" > "/tmp/dev-proposal-id-${PROJECT_NAME}-9998"
rc=0
out="$(run_block 9998)" || rc=$?
ac_assert_eq "$rc" "0" "the export block must succeed when the id file is present (got $rc): $out"
case "$out" in
  *"TAPE_PROPOSAL_ID=${ID}"*) ;;
  *) ac_fail "with a non-empty id file, TAPE_PROPOSAL_ID must equal the file's contents (${ID}), got: $out" ;;
esac

# ── 3a. Missing id file → TAPE_PROPOSAL_ID stays unset ─────────────────────
rm -f "/tmp/dev-proposal-id-${PROJECT_NAME}-9997"
out="$(run_block 9997)"
case "$out" in
  *"TAPE_PROPOSAL_ID=<unset>"*) ;;
  *) ac_fail "with no id file, TAPE_PROPOSAL_ID must stay unset, got: $out" ;;
esac

# ── 3b. Empty id file → TAPE_PROPOSAL_ID stays unset ───────────────────────
: > "/tmp/dev-proposal-id-${PROJECT_NAME}-9999"
out="$(run_block 9999)"
case "$out" in
  *"TAPE_PROPOSAL_ID=<unset>"*) ;;
  *) ac_fail "with an empty id file, TAPE_PROPOSAL_ID must stay unset, got: $out" ;;
esac

# ── 3c. Whitespace-only id file → TAPE_PROPOSAL_ID stays unset ─────────────
printf '\n' > "/tmp/dev-proposal-id-${PROJECT_NAME}-9996"
out="$(run_block 9996)"
case "$out" in
  *"TAPE_PROPOSAL_ID=<unset>"*) ;;
  *) ac_fail "with a whitespace-only id file, TAPE_PROPOSAL_ID must stay unset, got: $out" ;;
esac

ac_pass
