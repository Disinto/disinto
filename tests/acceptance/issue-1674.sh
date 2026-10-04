#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1674.sh
#
# Issue #1674: feat(tools): count a sprint's children from the tape.
#
# Contract under test (tools/sprint-children.sh SPRINT_ID):
#   * Reads ${TAPE_DIR:-/srv/disinto/tape}/tape.jsonl and counts the
#     proposals whose `parent` is SPRINT_ID.
#   * Prints one compact JSON object:
#       {"n_children":N,"n_merged":N,"n_rejected":N,"n_failed":N}
#     where n_children is all of them, n_merged are those whose LAST outcome
#     (last in tape order) carries bits.merged 1 or true, n_rejected are
#     the rest whose last outcome carries bits.rejected 1 or true, and
#     n_failed are the remainder — including children with no outcome.
#   * Missing tape (no tape.jsonl, or empty) prints all four as 0.
#   * Malformed lines are skipped (a torn final line from a crashed writer),
#     noted on stderr, and never fail the count.
#
# Acceptance (hermetic, in-process — no network, temp TAPE_DIR with fixture
# tape, same pattern as issue-1673.sh):
#   * AC1: three children of s1 — one merged, one rejected, one without an
#         outcome — plus one child of s2 -> s1 prints
#         {"n_children":3,"n_merged":1,"n_rejected":1,"n_failed":1}, and s2's
#         child is not counted in s1 (it is counted as s2's failed child).
#   * AC2: a child whose first outcome is merged: 0 and last is merged: 1
#         counts as merged (only the last outcome decides).
#   * AC3: booleans count, and last beats first: a child merged: true then
#         merged: false / rejected: false -> failed; rejected: true ->
#         rejected; merged: true -> merged.
#   * AC4: a missing tape.jsonl and an empty tape.jsonl both print all zeros.
#   * AC5: a malformed line (torn line, and a non-object JSON line) is
#         skipped, not fatal — the count is unchanged, rc 0, stderr noted.
#   * AC6: bash tests/acceptance/issue-1674.sh exits 0 and calls ac_pass.
#
# Run via: tools/run-acceptance.sh 1674
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq
ac_assert_file "$REPO_ROOT/tools/sprint-children.sh" "tools/sprint-children.sh is missing"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# run_children <tape_dir> [args...] — run the tool with TAPE_DIR=<tape_dir>;
# rc/out/err land in globals. The tool's stdout is never leaked onto the
# test's stdout, so the last line there stays PASS.
run_children() {
  local dir="$1"
  shift
  RC=0
  OUT=""
  OUT="$(TAPE_DIR="$dir" bash "$REPO_ROOT/tools/sprint-children.sh" "$@" 2>"$TMP_DIR/err")" || RC=$?
  ERR="$(cat "$TMP_DIR/err" 2>/dev/null || true)"
}

# expect <tape_dir> <sprint_id> <expected_json> — assert the tool's output for
# the sprint exactly (string equality against the compact form).
expect() {
  local dir="$1" sprint="$2" expected="$3"
  run_children "$dir" "$sprint"
  ac_assert_eq "$RC" "0" \
    "sprint-children $sprint must exit 0 (got $RC): $OUT / $ERR"
  ac_assert_eq "$OUT" "$expected" \
    "sprint-children $sprint output, expected '$expected', got '$OUT'"
}

# ── Fixture: AC1 — s1 (3 children: merged / rejected / no outcome) + s2
# (one child, no outcome). c1's outcome carries the full outcome shape
# (bits/numbers/children/payloads) as lib/tape.sh emits it. ──────────────────
TAPE1="$TMP_DIR/tape-ac1"
mkdir -p "$TAPE1"
cat > "$TAPE1/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-09T00:00:00Z","id":"s1","loop":"sprint","class":"internal","context":{},"decision":"approved","ref":"milestone:7"}
{"type":"proposal","t":"2026-02-09T00:00:00Z","id":"s2","loop":"sprint","class":"internal","context":{},"decision":"approved","ref":"milestone:8"}
{"type":"proposal","t":"2026-02-09T00:10:00Z","id":"c1","loop":"dev","class":"internal","parent":"s1","context":{},"decision":"approved","ref":"10"}
{"type":"proposal","t":"2026-02-09T00:20:00Z","id":"c2","loop":"dev","class":"internal","parent":"s1","context":{},"decision":"approved","ref":"11"}
{"type":"proposal","t":"2026-02-09T00:30:00Z","id":"c3","loop":"dev","class":"internal","parent":"s1","context":{},"decision":"approved","ref":"12"}
{"type":"proposal","t":"2026-02-09T00:40:00Z","id":"d1","loop":"dev","class":"internal","parent":"s2","context":{},"decision":"approved","ref":"13"}
{"type":"outcome","t":"2026-02-09T10:00:00Z","proposal_id":"c1","bits":{"merged":1,"ci_green":1},"numbers":{"duration_s":1200},"children":{},"payloads":[]}
{"type":"outcome","t":"2026-02-09T11:00:00Z","proposal_id":"c2","bits":{"merged":0,"rejected":1},"numbers":{"duration_s":1800},"children":{},"payloads":[]}
EOF

ac_log "AC1: s1 with merged/rejected/no-outcome children + an s2 child -> 3/1/1/1 for s1"
expect "$TAPE1" s1 '{"n_children":3,"n_merged":1,"n_rejected":1,"n_failed":1}'
# s2's child (no outcome) is a failed child of s2, not of s1.
ac_log "AC1: s2 -> 1 child, failed (d1 has no outcome)"
expect "$TAPE1" s2 '{"n_children":1,"n_merged":0,"n_rejected":0,"n_failed":1}'
# A foreign sprint id is counted over the whole tape and finds nothing.
ac_log "AC1: foreign sprint id -> all zeros"
expect "$TAPE1" s999 '{"n_children":0,"n_merged":0,"n_rejected":0,"n_failed":0}'

# ── AC2: only the last outcome decides ──────────────────────────────────────
TAPE2="$TMP_DIR/tape-ac2"
mkdir -p "$TAPE2"
cat > "$TAPE2/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-09T00:00:00Z","id":"s1","loop":"sprint","class":"internal","context":{},"decision":"approved","ref":"milestone:7"}
{"type":"proposal","t":"2026-02-09T00:10:00Z","id":"c1","loop":"dev","class":"internal","parent":"s1","context":{},"decision":"approved","ref":"10"}
{"type":"outcome","t":"2026-02-09T10:00:00Z","proposal_id":"c1","bits":{"merged":0,"ci_green":0},"numbers":{"duration_s":300},"children":{},"payloads":[]}
{"type":"outcome","t":"2026-02-09T11:00:00Z","proposal_id":"c1","bits":{"merged":1,"ci_green":1},"numbers":{"duration_s":1200},"children":{},"payloads":[]}
{"type":"outcome","t":"2026-02-09T11:01:00Z","proposal_id":"c1","bits":{"merged":0,"ci_green":0},"numbers":{"duration_s":300},"children":{},"payloads":[]}
EOF
# Two more outcomes after the merged one; the LAST (rejected-ish) one wins,
# so c1 is not merged — AC2's stated case is first merged:0, last merged:1
# (covered by the first three lines), and the trailing pair proves tape order
# (position in the file), not latest t, is the ordering.
ac_log "AC2: first merged:0 then merged:1 then merged:0 -> last (merged:0) wins: failed"
expect "$TAPE2" s1 '{"n_children":1,"n_merged":0,"n_rejected":0,"n_failed":1}'

cat > "$TMP_DIR/tape-ac2b.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-09T00:00:00Z","id":"s1","loop":"sprint","class":"internal","context":{},"decision":"approved","ref":"milestone:7"}
{"type":"proposal","t":"2026-02-09T00:10:00Z","id":"c1","loop":"dev","class":"internal","parent":"s1","context":{},"decision":"approved","ref":"10"}
{"type":"outcome","t":"2026-02-09T10:00:00Z","proposal_id":"c1","bits":{"merged":0,"ci_green":0},"numbers":{"duration_s":300},"children":{},"payloads":[]}
{"type":"outcome","t":"2026-02-09T11:00:00Z","proposal_id":"c1","bits":{"merged":1,"ci_green":1},"numbers":{"duration_s":1200},"children":{},"payloads":[]}
EOF
cp "$TMP_DIR/tape-ac2b.jsonl" "$TAPE2/tape.jsonl"
ac_log "AC2: first outcome merged: 0, last outcome merged: 1 -> merged (AC2)"
expect "$TAPE2" s1 '{"n_children":1,"n_merged":1,"n_rejected":0,"n_failed":0}'

# ── AC3: booleans count as 1/0; last beats first ────────────────────────────
TAPE3="$TMP_DIR/tape-ac3"
mkdir -p "$TAPE3"
cat > "$TAPE3/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-09T00:00:00Z","id":"s1","loop":"sprint","class":"internal","context":{},"decision":"approved","ref":"milestone:7"}
{"type":"proposal","t":"2026-02-09T00:10:00Z","id":"c1","loop":"dev","class":"internal","parent":"s1","context":{},"decision":"approved","ref":"10"}
{"type":"proposal","t":"2026-02-09T00:20:00Z","id":"c2","loop":"dev","class":"internal","parent":"s1","context":{},"decision":"approved","ref":"11"}
{"type":"proposal","t":"2026-02-09T00:30:00Z","id":"c3","loop":"dev","class":"internal","parent":"s1","context":{},"decision":"approved","ref":"12"}
{"type":"outcome","t":"2026-02-09T10:00:00Z","proposal_id":"c1","bits":{"merged":true,"ci_green":true},"numbers":{"duration_s":1200},"children":{},"payloads":[]}
{"type":"outcome","t":"2026-02-09T10:05:00Z","proposal_id":"c1","bits":{"merged":false,"rejected":false},"numbers":{"duration_s":1200},"children":{},"payloads":[]}
{"type":"outcome","t":"2026-02-09T10:10:00Z","proposal_id":"c2","bits":{"merged":0,"rejected":true},"numbers":{"duration_s":1800},"children":{},"payloads":[]}
{"type":"outcome","t":"2026-02-09T10:15:00Z","proposal_id":"c3","bits":{"merged":true},"numbers":{"duration_s":600},"children":{},"payloads":[]}
EOF
ac_log "AC3: c1 true-then-false -> failed (last wins); c2 rejected:true -> rejected; c3 merged:true -> merged"
expect "$TAPE3" s1 '{"n_children":3,"n_merged":1,"n_rejected":1,"n_failed":1}'

# ── AC4: missing tape and empty tape -> all zeros ────────────────────────────
TAPE4A="$TMP_DIR/tape-ac4a"
mkdir -p "$TAPE4A"   # dir exists, no tape.jsonl
ac_log "AC4: missing tape.jsonl -> all zeros"
expect "$TAPE4A" s1 '{"n_children":0,"n_merged":0,"n_rejected":0,"n_failed":0}'

TAPE4B="$TMP_DIR/tape-ac4b"
mkdir -p "$TAPE4B"
: > "$TAPE4B/tape.jsonl"   # zero-byte tape
ac_log "AC4: empty tape.jsonl -> all zeros"
expect "$TAPE4B" s1 '{"n_children":0,"n_merged":0,"n_rejected":0,"n_failed":0}'

TAPE4C="$TMP_DIR/tape-ac4c"
mkdir -p "$TAPE4C"
: > "$TAPE4C/tape.jsonl"
ac_log "AC4: empty string SPRINT_ID -> all zeros"
expect "$TAPE4C" '' '{"n_children":0,"n_merged":0,"n_rejected":0,"n_failed":0}'

# ── AC5: malformed lines are skipped, not fatal ─────────────────────────────
TAPE5="$TMP_DIR/tape-ac5"
mkdir -p "$TAPE5"
cat > "$TAPE5/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-09T00:00:00Z","id":"s1","loop":"sprint","class":"internal","context":{},"decision":"approved","ref":"milestone:7"}
{"type":"proposal","t":"2026-02-09T00:10:00Z","id":"c1","loop":"dev","class":"internal","parent":"s1","context":{},"decision":"approved","ref":"10"}
{"type":"outcome","t":"2026-02-09T10:00:00Z","proposal_id":"c1","bits":{"merged":1},"numbers":{"duration_s":1200},"children":{},"payloads":[]}
{"torn line without a closing brace
{"type":"outcome","t":"2026-02-09T10:01:00Z","proposal_id":"c999","bits":{"merged":1},"numbers":{},"children":{},"payloads":[]}
[
{"type":"proposal","t":"2026-02-09T00:20:00Z","id":"c2","loop":"dev","class":"internal","parent":"s1","context":{},"decision":"approved","ref":"11"}
EOF
ac_log "AC5: torn + non-object lines skipped -> s1 has 2 children (c1 merged, c2 no outcome), rc 0"
expect "$TAPE5" s1 '{"n_children":2,"n_merged":1,"n_rejected":0,"n_failed":1}'
ac_assert_eq "$RC" "0" "AC5: malformed lines must not fail the count (got $RC): $OUT / $ERR"
case "$ERR" in
  *malformed*) ;;
  *) ac_fail "AC5: malformed-line skip note missing from stderr, got: $ERR" ;;
esac
ac_log "AC5: skipped-count note present on stderr"

# ── AC6: the test itself must exit 0 and ac_pass ────────────────────────────
ac_pass
