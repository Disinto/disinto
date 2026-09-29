#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1598.sh
#
# Issue #1598: feat(dev): record Jev scope on the pick without changing it.
#
# Contract under test (dev/dev-poll.sh, emit_tape_proposal): when a pick emits
# a proposal, it also asks tools/jev-scope.sh for the issue's scope and records
# it on the proposal context — never changing the pick, the forecast, or
# forecast_method.
#
# Acceptance (read-only — no live services, no agents started, no pick
# triggered; the emitter is exercised in-process with a stub curl and a throwaway
# fake jev-scope, the same extract-and-stub approach as issue-1398):
#   * AC1: the stub jev-scope (exit 0, printing a scope body with three noul
#          numbers) adds context.jev = {method: "jev", pack: "scope",
#          one_concept, one_repo, one_behavior} to the proposal context.
#   * AC2: stub exit 1 (ssh/ssh-like failure) -> no context.jev; the proposal
#          is still written (fails closed, warns).
#   * AC3: stub exit 2 (unconfigured) -> no context.jev; the proposal is still
#          written (silent, per the tool's unconfigured contract).
#   * AC4: the emitter survives a genuine top-level set -e context (no
#          `||`/`if` guard), exactly as dev-poll.sh calls it — an unguarded
#          failing command substitution would kill the process and fail the test.
#   * AC5: the pick (claim-scan region of dev-poll.sh, before the
#          "# TAPE: emit a proposal record" header) reads no context.jev — the
#          scope is recorded on the proposal, never wired into the pick.
#   * AC6: this test exits 0 and calls ac_pass.
#
# Hermetic: the real tools/jev-scope.sh is replaced by a throwaway stub
# (pointed at via the JEV_SCOPE_TOOL env var), so no ssh, no network, no
# real door. Each AC uses a distinct issue number so the re-pick guard's
# id file never pre-exists.
#
# Run via: tools/run-acceptance.sh 1598
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk jq grep mktemp head wc cat

DEV_POLL="$REPO_ROOT/dev/dev-poll.sh"
ac_assert_file "$DEV_POLL" "dev/dev-poll.sh is missing"
ac_assert_file "$REPO_ROOT/lib/tape.sh" "lib/tape.sh is missing"

# ── Wiring: dev-poll sources the tape lib, calls the emitter, and hooks Jev ──
grep -q '^source .*lib/tape\.sh' "$DEV_POLL" \
  || ac_fail "dev-poll.sh must source lib/tape.sh"
grep -q 'emit_tape_proposal "\$READY_ISSUE"' "$DEV_POLL" \
  || ac_fail "dev-poll.sh must call emit_tape_proposal for the picked issue"
grep -Eq 'JEV_SCOPE_TOOL|context\.jev|one_concept' "$DEV_POLL" \
  || ac_fail "dev-poll.sh has no Jev-scope hook (#1598)"

# ── Extract the function under test ───────────────────────────────────────────
FN_SRC="$(ac_extract_fn emit_tape_proposal "$DEV_POLL")"
[ -n "$FN_SRC" ] || ac_fail "could not extract emit_tape_proposal() from dev-poll.sh"

TMP_DIR="$(mktemp -d /tmp/disinto-acceptance-1598.XXXXXX)"
PROJECT_NAME="acceptance-1598"   # sentinel — can never clobber a live id file
# Distinct issues per AC => distinct id files; the re-pick guard never fires.
rm -f "/tmp/dev-proposal-id-${PROJECT_NAME}-1598" \
      "/tmp/dev-proposal-id-${PROJECT_NAME}-1599" \
      "/tmp/dev-proposal-id-${PROJECT_NAME}-1600" \
      "/tmp/dev-proposal-id-${PROJECT_NAME}-1601" 2>/dev/null || true
trap 'rm -rf "$TMP_DIR" \
      /tmp/dev-proposal-id-acceptance-1598-1598 \
      /tmp/dev-proposal-id-acceptance-1598-1599 \
      /tmp/dev-proposal-id-acceptance-1598-1600 \
      /tmp/dev-proposal-id-acceptance-1598-1601 \
      /tmp/dev-proposal-started-acceptance-1598-1601' EXIT

# ── Hermetic forge (shared) ───────────────────────────────────────────────────
STUB_BIN="$TMP_DIR/bin"
mkdir -p "$STUB_BIN"
ac_write_curl_stub "$STUB_BIN"

# The extracted emitter logs through log(); subshells inherit this stand-in.
log() { echo "poll: $*"; }

# ── A throwaway fake tools/jev-scope.sh; behaviour set by env vars ───────────
# Mirrors the real tool's stdout contract: body only on exit 0; exit 1 =
# failure (no body), exit 2 = unconfigured (no body).
STUB_TOOL="$TMP_DIR/jev-scope-stub/jev-scope.sh"
mkdir -p "$TMP_DIR/jev-scope-stub"
cat > "$STUB_TOOL" <<'STUB_EOF'
#!/usr/bin/env bash
if [[ -n "${JEV_TOOL_LOG:-}" ]]; then
  printf 'jev-scope: %s\n' "$*" >> "${JEV_TOOL_LOG}"
fi
if [[ -n "${JEV_STDIN_LOG:-}" ]]; then
  cat >> "${JEV_STDIN_LOG}"
fi
if [[ "${JEV_STUB_RC:-2}" == "0" ]]; then
  printf '%s\n' "${JEV_STUB_BODY:-}"
fi
exit "${JEV_STUB_RC:-2}"
STUB_EOF
chmod +x "$STUB_TOOL"
export JEV_SCOPE_TOOL="$STUB_TOOL"

# ACs drive emit_tape_proposal through the shared ac_run_tape_emit subshell
# runner (stub curl on PATH, real lib/tape.sh, sentinel PROJECT_NAME, caller's
# TAPE_DIR). The jev stub is selected via JEV_SCOPE_TOOL (inherited by the
# subshell) and behaves per JEV_STUB_RC / JEV_STUB_BODY.

# ── AC1: stub exit 0 + three noul numbers -> context.jev written ──────────────
ac_log "AC1: a valid scope reading adds context.jev to the proposal context"
TAPE1="$TMP_DIR/tape1"
mkdir -p "$TAPE1"
SCOPE_BODY='{"answers":{"one_concept":{"noul":0.8},"one_repo":{"noul":0.7},"one_behavior":{"noul":0.6}}}'
export JEV_STUB_RC=0
export JEV_STUB_BODY="$SCOPE_BODY"
export JEV_TOOL_LOG="$TAPE1/tool.log"
rc=0
out="$(ac_run_tape_emit "$STUB_BIN" "$TAPE1" "$FN_SRC" "0" emit_tape_proposal 1598)" || rc=$?
ac_assert_eq "$rc" "0" "AC1: emit_tape_proposal must exit 0 (got $rc): $out"
ac_assert_file "$TAPE1/tape.jsonl" "AC1: no tape.jsonl was written"
ac_assert_eq "$(wc -l < "$TAPE1/tape.jsonl")" "1" \
  "AC1: picking an issue must append exactly one proposal line"
LINE="$(head -n 1 "$TAPE1/tape.jsonl")"
ac_assert_jq '.type == "proposal" and .loop == "dev" and .decision == "approved" and .ref == "1598" and .class == "backlog" and .context.open_prs == 3' \
  "$LINE" \
  "AC1: the proposal must be a valid approved dev proposal (ref 1598, class backlog, 3 open PRs)"
ac_assert_jq '.context.jev == {method: "jev", pack: "scope", one_concept: 0.8, one_repo: 0.7, one_behavior: 0.6}' \
  "$LINE" \
  "AC1: context.jev must be exactly {method: jev, pack: scope, the three noul readings}"
ac_log "AC1: valid scope reading lands on the proposal context"

# ── AC2: stub exit 1 -> no context.jev, proposal still written ────────────────
ac_log "AC2: stub exit 1 fails closed (no context.jev); the proposal is still written"
TAPE2="$TMP_DIR/tape2"
mkdir -p "$TAPE2"
export JEV_STUB_RC=1
export JEV_STUB_BODY=""
export JEV_TOOL_LOG="$TAPE2/tool.log"
rc=0
out="$(ac_run_tape_emit "$STUB_BIN" "$TAPE2" "$FN_SRC" "0" emit_tape_proposal 1599)" || rc=$?
ac_assert_eq "$rc" "0" "AC2: emit_tape_proposal must exit 0 on jev exit 1 (got $rc): $out"
ac_assert_file "$TAPE2/tape.jsonl" "AC2: the proposal must still be written on jev exit 1"
ac_assert_eq "$(wc -l < "$TAPE2/tape.jsonl")" "1" \
  "AC2: picking an issue must append exactly one proposal line"
LINE="$(head -n 1 "$TAPE2/tape.jsonl")"
ac_assert_jq '.type == "proposal" and .ref == "1599" and .class == "backlog" and .context.open_prs == 3 and (.context.jev == null)' \
  "$LINE" \
  "AC2: context.jev must be absent when the stub exits 1"
ac_log "AC2: jev exit 1 degrades to no jev field; the proposal is still written"

# ── AC3: stub exit 2 (unconfigured) -> no context.jev, proposal still written ──
ac_log "AC3: stub exit 2 (unconfigured) -> no context.jev; the proposal is still written"
TAPE3="$TMP_DIR/tape3"
mkdir -p "$TAPE3"
export JEV_STUB_RC=2
export JEV_STUB_BODY=""
rc=0
out="$(ac_run_tape_emit "$STUB_BIN" "$TAPE3" "$FN_SRC" "0" emit_tape_proposal 1600)" || rc=$?
ac_assert_eq "$rc" "0" "AC3: emit_tape_proposal must exit 0 on jev exit 2 (got $rc): $out"
ac_assert_file "$TAPE3/tape.jsonl" "AC3: the proposal must still be written on jev exit 2"
ac_assert_eq "$(wc -l < "$TAPE3/tape.jsonl")" "1" \
  "AC3: picking an issue must append exactly one proposal line"
LINE="$(head -n 1 "$TAPE3/tape.jsonl")"
ac_assert_jq '.type == "proposal" and .ref == "1600" and .class == "backlog" and .context.open_prs == 3 and (.context.jev == null)' \
  "$LINE" \
  "AC3: context.jev must be absent when the stub exits 2 (unconfigured)"
ac_log "AC3: jev exit 2 degrades to no jev field; the proposal is still written"

# ── AC4: genuine top-level set -e (no guard) — live-context regression ────────
# AC1-AC3 drive the emitter via ac_run_tape_emit, which runs it in a subshell
# invoked from the caller's `|| rc=$?` guard; set-e suppression propagates into
# that conditional context, so a set-e bug in the emitter would not surface there.
# AC4 runs the emitter as a BARE command in a fresh subshell under
# `set -euo pipefail` with no guard, mirroring dev-poll.sh's top-level
# `emit_tape_proposal "$READY_ISSUE"` (a bare command, not under ||/if). An
# unguarded failing command substitution kills the subshell — and this process —
# failing the test: exactly the #1598 set-e outage the reviewer flagged.
ac_log "AC4: the emitter survives a genuine top-level set -e context (no guard)"
TAPE4="$TMP_DIR/tape4"
mkdir -p "$TAPE4"
export JEV_STUB_RC=2
export JEV_STUB_BODY=""
export TMP_DIR STUB_BIN STUB_TOOL REPO_ROOT FN_SRC PROJECT_NAME TAPE4
# Bare subshell, set -e active inside, unguarded: a set-e bug in the emitter
# kills it (and hence this process, via the parent's set -e).
(
  set -euo pipefail
  export PATH="$STUB_BIN:$PATH"
  export API="https://forge.example/api/v1"
  export FORGE_API="https://forge.example/api/v1"
  export FORGE_TOKEN="stub-token"
  export TAPE_DIR="$TAPE4"
  export JEV_SCOPE_TOOL="$STUB_TOOL"
  # shellcheck disable=SC1090,SC1091
  source "$REPO_ROOT/lib/tape.sh"
  eval "$FN_SRC"
  emit_tape_proposal 1601
)
ac_assert_file "$TAPE4/tape.jsonl" "AC4: set-e kill — no proposal line written"
ac_assert_eq "$(wc -l < "$TAPE4/tape.jsonl")" "1" \
  "AC4: a fresh pick under set -e still appends exactly one proposal line"
LINE="$(head -n 1 "$TAPE4/tape.jsonl")"
ac_assert_jq '.type == "proposal" and .ref == "1601" and .class == "backlog" and .context.open_prs == 3 and (.context.jev == null)' \
  "$LINE" \
  "AC4: under genuine set -e the unconfigured tool yields no context.jev"
ac_log "AC4: the emitter survives the live (no-guard) set -e context"

# ── AC5: the pick reads no context.jev (static) ────────────────────────────────
ac_log "AC5: the pick (pre-#TAPE region) reads no context.jev / jev (scope stays on the proposal)"
PICK_REGION="$(awk '/# TAPE: emit a proposal record for the picked issue/ { exit } { print }' "$DEV_POLL")"
grep -Eq 'context\.jev' <<< "$PICK_REGION" && ac_fail "AC5: the pick region references context.jev"
grep -qF 'jev' <<< "$PICK_REGION" && ac_fail "AC5: the pick region references 'jev'"
ac_log "AC5: the claim scan is untouched — the scope is never read to pick"

ac_log "all acceptance criteria met for issue 1598"
ac_pass
