#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2113.sh
#
# Issue #2113: tools/rollout.sh can file the dev issue for a commit the
# rollout rolled back from the canary (docs/design/notes/self-update.md,
# "Roll back"). rollout_rollback_issue COMMIT SUBJECT REASON EVIDENCE files
# as the caller's forge account (FORGE_TOKEN against FORGE_API, the project
# repo's API base as lib/env.sh exports it):
#   1. GET ${FORGE_API}/labels?limit=50, take the id of `backlog`; a failed
#      GET returns 1; no such label files without labels.
#   2. POST ${FORGE_API}/issues with title, body and labels, built with jq -n;
#      print the new issue's .number; return 1 when the POST fails or the
#      answer has no number.
#
# Hermetic (no network, no live services): ac_write_curl_stub extended with
# the labels fixture [{"id":7,"name":"backlog"},{"id":9,"name":"bug"}] and an
# issues POST that records its -d body and answers {"number":321}.
#
# Acceptance:
#   1. rollout_rollback_issue <sha> "feat: x" smoke <evidence> prints 321;
#      the POST body has labels [7], a title starting "fix(rollout): " with
#      the sha's first 7 characters, and a body with ## Problem, the sha, the
#      evidence and the smoke hint.
#   2. labels without `backlog`: labels is [].
#   3. a failing labels GET: return 1, no POST.
#   4. a create answer without number: return 1.
#   5. bash -n tools/rollout.sh passes.
#
# Run via `tools/run-acceptance.sh 2113` or `bash tests/acceptance/issue-2113.sh`.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq python3

TOOL="$REPO_ROOT/tools/rollout.sh"
ac_assert_file "$TOOL" "tools/rollout.sh is missing"

# ── AC5: the tool parses ──────────────────────────────────────────────────────
ac_log "AC5: bash -n tools/rollout.sh passes"
bash -n "$TOOL" || ac_fail "bash -n tools/rollout.sh must pass"
ac_log "AC5 OK"

# Source the tool: the usage guard keeps the direct-run block from executing.
# shellcheck source=../../tools/rollout.sh
source "$TOOL"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/issue-2113.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

STUB_BIN="$TMP_DIR/stub"
mkdir -p "$STUB_BIN"
ac_write_curl_stub "$STUB_BIN"

# Extend the shared stub: the labels GET answers the fixture, the issues POST
# records its -d body to AC_BODY_FILE and answers {"number":321}.
# AC_NO_BACKLOG=1 drops the backlog label, AC_LABELS_FAIL=1 fails the GET,
# AC_CREATE_NO_NUMBER=1 answers without a number.
python3 - "$STUB_BIN/curl" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
old = "  *)\n    exit 22\n    ;;\n"
new = (
    "  *'/labels?limit=50'*)\n"
    "    if [ \"${AC_LABELS_FAIL:-}\" = \"1\" ]; then exit 22; fi\n"
    "    if [ \"${AC_NO_BACKLOG:-}\" = \"1\" ]; then\n"
    "      printf '%s\\n' '[{\"id\":9,\"name\":\"bug\"}]'\n"
    "    else\n"
    "      printf '%s\\n' '[{\"id\":7,\"name\":\"backlog\"},{\"id\":9,\"name\":\"bug\"}]'\n"
    "    fi\n"
    "    ;;\n"
    "  *'/issues'*)\n"
    "    body=\"\"\n"
    "    prev=\"\"\n"
    "    for a in \"$@\"; do\n"
    "      if [ \"$prev\" = \"-d\" ] || [ \"$prev\" = \"--data\" ]; then body=\"$a\"; fi\n"
    "      prev=\"$a\"\n"
    "    done\n"
    "    if [ -n \"${AC_BODY_FILE:-}\" ]; then printf '%s' \"$body\" > \"$AC_BODY_FILE\"; fi\n"
    "    if [ \"${AC_CREATE_NO_NUMBER:-}\" = \"1\" ]; then\n"
    "      printf '%s\\n' '{\"id\":55}'\n"
    "    else\n"
    "      printf '%s\\n' '{\"number\":321}'\n"
    "    fi\n"
    "    ;;\n"
    "  *)\n"
    "    exit 22\n"
    "    ;;\n"
)
if old not in text:
    raise SystemExit("ac_write_curl_stub catch-all not found")
path.write_text(text.replace(old, new, 1))
PY

export FORGE_API="https://forge.example/api/v1/repos/disinto/disinto"
export FORGE_TOKEN="stub-token"

COMMIT="deadbeefcafebabe1234567890abcdef"
SHORT="deadbee"
EVIDENCE='{"kind":"take","commit":"deadbeefcafebabe1234567890abcdef","t":100,"smoke":1}
{"kind":"poll","commit":"deadbeefcafebabe1234567890abcdef","t":110,"rc":0}'

# ── AC1: smoke rollback files the issue and prints its number ────────────────
ac_log "AC1: rollout_rollback_issue prints 321 and posts the full issue"
BODY_FILE="$TMP_DIR/post1"
out="$(PATH="$STUB_BIN:$PATH" AC_BODY_FILE="$BODY_FILE" \
    rollout_rollback_issue "$COMMIT" "feat: x" smoke "$EVIDENCE")"
ac_assert_eq "$out" "321" "AC1: expected the new issue number 321, got '${out}'"

ac_assert_jq '.labels == [7]' "$(cat "$BODY_FILE")" \
  "AC1: the POST body must carry labels [7], the backlog id"
title="$(jq -r '.title' "$BODY_FILE")"
case "$title" in
  "fix(rollout): ${SHORT} failed on the canary (smoke)") ;;
  *) ac_fail "AC1: title must be 'fix(rollout): ${SHORT} failed on the canary (smoke)', got '${title}'" ;;
esac
body="$(jq -r '.body' "$BODY_FILE")"
grep -qF '## Problem' <<<"$body" || ac_fail "AC1: body must have the ## Problem section"
grep -qF "$COMMIT" <<<"$body" || ac_fail "AC1: body must name the rolled-back commit"
while IFS= read -r line; do
  grep -qF "$line" <<<"$body" || ac_fail "AC1: body must carry the evidence line: $line"
done <<<"$EVIDENCE"
grep -qF 'the smoke (`.woodpecker/agent-smoke.sh`) failed on it, see `smoke_tail`' \
  <<<"$body" || ac_fail "AC1: body must carry the smoke hint"
grep -qF '## Proposed solution' <<<"$body" || ac_fail "AC1: body must have the ## Proposed solution section"
grep -qF '## Acceptance criteria' <<<"$body" || ac_fail "AC1: body must have the ## Acceptance criteria section"
grep -qF '## Acceptance test' <<<"$body" || ac_fail "AC1: body must have the ## Acceptance test section"
ac_log "AC1 OK"

# A non-mapping reason becomes the hint itself.
BODY_FILE2="$TMP_DIR/post2"
out="$(PATH="$STUB_BIN:$PATH" AC_BODY_FILE="$BODY_FILE2" \
    rollout_rollback_issue "$COMMIT" "feat: x" left "$EVIDENCE")"
ac_assert_eq "$out" "321" "AC1: the left-reason call must also print 321"
body2="$(jq -r '.body' "$BODY_FILE2")"
grep -qF 'the canary stopped running it' <<<"$body2" \
  || ac_fail "AC1: reason left must hint 'the canary stopped running it'"
ac_log "AC1b (reason hint) OK"

# ── AC2: no `backlog` label files the issue without labels ────────────────────
ac_log "AC2: labels fixture without backlog posts labels []"
BODY_FILE3="$TMP_DIR/post3"
out="$(PATH="$STUB_BIN:$PATH" AC_NO_BACKLOG=1 AC_BODY_FILE="$BODY_FILE3" \
    rollout_rollback_issue "$COMMIT" "feat: x" rc "$EVIDENCE")"
ac_assert_eq "$out" "321" "AC2: expected 321, got '${out}'"
ac_assert_jq '.labels == []' "$(cat "$BODY_FILE3")" \
  "AC2: without a backlog label the POST body must have labels []"
grep -qF '`review/review-poll.sh` exited non-zero' <<<"$(jq -r '.body' "$BODY_FILE3")" \
  || ac_fail "AC2: reason rc must hint that review/review-poll.sh exited non-zero"
ac_log "AC2 OK"

# ── AC3: a failing labels GET returns 1 and posts nothing ─────────────────────
ac_log "AC3: a failing labels GET returns 1 and never POSTs"
BODY_FILE4="$TMP_DIR/post4"
rc=0
out="$(PATH="$STUB_BIN:$PATH" AC_LABELS_FAIL=1 AC_BODY_FILE="$BODY_FILE4" \
    rollout_rollback_issue "$COMMIT" "feat: x" smoke "$EVIDENCE")" || rc=$?
ac_assert_eq "$rc" 1 "AC3: a failed labels GET must return 1, got $rc"
if [ -e "$BODY_FILE4" ]; then
  ac_fail "AC3: a failed labels GET must not POST an issue"
fi
ac_log "AC3 OK"

# ── AC4: a create answer without a number returns 1 ───────────────────────────
ac_log "AC4: an issue create without number returns 1"
BODY_FILE5="$TMP_DIR/post5"
rc=0
out="$(PATH="$STUB_BIN:$PATH" AC_CREATE_NO_NUMBER=1 AC_BODY_FILE="$BODY_FILE5" \
    rollout_rollback_issue "$COMMIT" "feat: x" smoke "$EVIDENCE")" || rc=$?
ac_assert_eq "$rc" 1 "AC4: a create answer with no number must return 1, got $rc"
ac_log "AC4 OK"

ac_pass
