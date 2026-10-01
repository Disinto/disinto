#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1632.sh
#
# Issue #1632: feat(dev): dev proposals carry no forecast and no Jev reading.
#
# Contract under test (dev/dev-poll.sh, emit_tape_proposal): a pick's proposal
# carries no forecast and no Jev-scope reading, and the pick path never dials
# catalog_forecast (lib/catalog-forecast.sh) nor the Jev scope door
# (tools/jev-scope.sh). Those libraries remain in the repo, unused; they return
# later as named forecast methods. Everything else on the proposal stays as
# before (class/parent derivation, open_prs, size_class, backend, decision
# "approved", ref = the issue number, the re-pick guard, the started epoch).
#
# The test is hermetic (read-only, extract-and-stub, no live services, no agent
# launched): emit_tape_proposal() is extracted out of dev-poll.sh and run in
# throwaway subshells against a fake Forge curl and a fake tape (lib/tape.sh +
# the sprint helpers). Each run plants a probe — a fake catalog_forecast()
# function and a fake JEV_SCOPE_TOOL file — so that a pick path that still
# reached either would leave a marker file. The ACs assert the markers are
# absent (i.e. the pick path never called them).
#
# Acceptance (mirrors #1398 / #1598 / #1619 conventions):
#   * AC1: a stubbed pick writes a dev proposal with no forecast key and no
#          forecast_method/jev in context; the planted catalog_forecast and the
#          Jev-scope door are both present in the run environment and BOTH
#          uninvoked.
#   * AC2: the same pick under a genuine top-level set -e context (a bare
#          subshell, no `||`/`if` guard) — the removed forecast/Jev blocks
#          carried set-e hazards, so the pick must still survive and append
#          exactly one proposal with no forecast/Jev.
#   * AC3: static — the extracted emitter references neither the forecast
#          machinery (catalog_forecast / CATALOG_FORECAST_METHOD) nor the
#          Jev-scope door (JEV_SCOPE_TOOL / jev-).
#   * AC4: this test exits 0 and calls ac_pass.
#
# Run via: tools/run-acceptance.sh 1632
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk jq grep mktemp head wc cat

DEV_POLL="$REPO_ROOT/dev/dev-poll.sh"
ac_assert_file "$DEV_POLL" "dev/dev-poll.sh is missing"
ac_assert_file "$REPO_ROOT/lib/tape.sh" "lib/tape.sh is missing"
ac_assert_file "$REPO_ROOT/lib/sprint-block.sh" "lib/sprint-block.sh is missing"
ac_assert_file "$REPO_ROOT/lib/sprint-tape.sh" "lib/sprint-tape.sh is missing"
grep -q '^source .*lib/tape\.sh' "$DEV_POLL" \
  || ac_fail "dev-poll.sh must source lib/tape.sh"
grep -qF 'emit_tape_proposal "$READY_ISSUE"' "$DEV_POLL" \
  || ac_fail 'dev-poll.sh must call emit_tape_proposal "$READY_ISSUE"'

# ── Extract the function under test ───────────────────────────────────────────
FN_SRC="$(ac_extract_fn emit_tape_proposal "$DEV_POLL")"
[ -n "$FN_SRC" ] || ac_fail "could not extract emit_tape_proposal() from dev-poll.sh"

TMP_DIR="$(mktemp -d /tmp/disinto-acceptance-1632.XXXXXX)"
PROJECT_NAME="acceptance-1632"   # sentinel — can never clobber a live id file
export PROJECT_NAME
# Distinct issues per AC (1632/1633) => distinct re-pick id files; the guard
# never fires.
rm -f "/tmp/dev-proposal-id-${PROJECT_NAME}-1632" \
      "/tmp/dev-proposal-id-${PROJECT_NAME}-1633" \
      "/tmp/dev-proposal-started-${PROJECT_NAME}-1632" \
      "/tmp/dev-proposal-started-${PROJECT_NAME}-1633" 2>/dev/null || true
trap 'rm -rf "$TMP_DIR" \
      /tmp/dev-proposal-id-acceptance-1632-1632 \
      /tmp/dev-proposal-id-acceptance-1632-1633 \
      /tmp/dev-proposal-started-acceptance-1632-1632 \
      /tmp/dev-proposal-started-acceptance-1632-1633' EXIT

# The extracted emitter logs through log(); subshells inherit this stand-in.
log() { echo "poll: $*"; }

# ── Hermetic forge (shared stub: no milestone => class "backlog") ─────────────
ac_stub_bin_and_log "$TMP_DIR/bin"

# A throwaway fake tools/jev-scope.sh. Any invocation writes a marker line to
# JEV_TOOL_LOG, so the ACs can assert "never called". Its stdout contract is
# copied from the real tool (valid exit-0 body) so a buggy pick would see a
# plausibly valid reading — it only matters that we can tell it fired.
STUB_TOOL="$TMP_DIR/jev-scope-stub/jev-scope.sh"
mkdir -p "$TMP_DIR/jev-scope-stub"
cat > "$STUB_TOOL" <<'STUB_EOF'
#!/usr/bin/env bash
if [[ -n "${JEV_TOOL_LOG:-}" ]]; then
  printf 'jev-scope: called\n' >> "${JEV_TOOL_LOG}"
fi
printf '%s\n' '{"answers":{"one_concept":{"noul":0.8},"one_repo":{"noul":0.7},"one_behavior":{"noul":0.6}}}'
exit 0
STUB_EOF
chmod +x "$STUB_TOOL"

# Run the extracted emitter in a throwaway subshell.
#   issue   — issue number handed to emit_tape_proposal (=> a distinct re-pick
#             id file, so the guard never fires).
#   bare    — "1" opens the subshell under set -euo pipefail (a genuine
#             top-level set -e context, like the #1598 AC4 regression);
#             "0" is the guarded subshell.
#   tape    — the caller's TAPE_DIR.
# The subshell plants a fake catalog_forecast() (lib/catalog-forecast.sh is
# deliberately NOT sourced, so the probe IS the lib's function) and points
# JEV_SCOPE_TOOL at the stub tool. A pick path that still reached either leaves
# a marker file (cf.log / jev.log); the ACs assert both are absent.
run_emit() {
  local issue="$1" bare="$2" tape_dir="$3"
  (
    [ "$bare" = "1" ] && set -euo pipefail
    export PATH="$STUB_BIN:$PATH"
    export API="https://forge.example/api/v1"
    export FORGE_API="https://forge.example/api/v1"
    export FORGE_TOKEN="stub-token"
    export TAPE_DIR="$tape_dir"
    export JEV_SCOPE_TOOL="$STUB_TOOL"
    export JEV_TOOL_LOG="$tape_dir/jev.log"
    export CATALOG_FORECAST_LOG="$tape_dir/cf.log"
    # shellcheck disable=SC1090,SC1091
    source "$REPO_ROOT/lib/tape.sh"
    source "$REPO_ROOT/lib/sprint-block.sh"
    source "$REPO_ROOT/lib/sprint-tape.sh"
    # Probe: if the pick path still dials the catalog forecast lib, it writes a
    # marker line here. (It also echoes a flat prior so a buggy pick could read
    # a value — the assertion never needs the value, only whether it fired.)
    # shellcheck disable=SC2317  # invoked only by a buggy pick, not statically reachable
    catalog_forecast() {
      printf 'catalog_forecast: %s %s\n' "$1" "$2" >> "${CATALOG_FORECAST_LOG:-/dev/null}"
      echo '{"p_success":0.5,"est_cost":0,"est_dvision":0}'
    }
    eval "$FN_SRC"
    emit_tape_proposal "$issue"
  ) 2>&1
}

# AC1: the stubbed pick writes a dev proposal with no forecast/Jev, and neither
# planted probe is invoked.
ac_log "AC1: a stubbed pick writes a dev proposal with no forecast/Jev — and neither probe is invoked"
TAPE1="$TMP_DIR/tape1"
mkdir -p "$TAPE1"
rc=0
out="$(run_emit 1632 0 "$TAPE1")" || rc=$?
ac_assert_eq "$rc" "0" "AC1: emit_tape_proposal must exit 0 (got $rc): $out"
ac_assert_file "$TAPE1/tape.jsonl" "AC1: no tape.jsonl was written"
ac_assert_eq "$(wc -l < "$TAPE1/tape.jsonl")" "1" "AC1: picking an issue must append exactly one proposal line"
LINE="$(head -n 1 "$TAPE1/tape.jsonl")"
ac_assert_jq '.type == "proposal" and .loop == "dev" and .decision == "approved" and .ref == "1632" and .class == "backlog" and .context.open_prs == 3 and .context.size_class == "M"' \
  "$LINE" \
  "AC1: the proposal must be a valid approved dev proposal (ref 1632, class backlog, 3 open PRs, size M)"
ac_assert_jq '.forecast == null' "$LINE" "AC1: the proposal must carry no forecast key"
ac_assert_jq '.context.forecast_method == null' "$LINE" "AC1: context must have no forecast_method"
ac_assert_jq '.context.jev == null' "$LINE" "AC1: context must have no jev"
if [[ -f "$TAPE1/cf.log" ]]; then
  ac_fail "AC1: catalog_forecast WAS called (cf.log present): $(tr '\n' ' ' < "$TAPE1/cf.log")"
fi
if [[ -f "$TAPE1/jev.log" ]]; then
  ac_fail "AC1: the Jev scope door WAS called (jev.log present): $(tr '\n' ' ' < "$TAPE1/jev.log")"
fi
ac_log "AC1: the pick carries no forecast/Jev and invoked neither the catalog forecast nor the Jev door"

# AC2: the same pick under a genuine top-level set -e context still survives and
# writes one proposal with no forecast/Jev (set-e regression from the removed
# forecast/Jev blocks; mirrors the #1598 AC4).
ac_log "AC2: the pick under a genuine top-level set -e context still survives"
TAPE2="$TMP_DIR/tape2"
mkdir -p "$TAPE2"
rc=0
out="$(run_emit 1633 1 "$TAPE2")" || rc=$?
ac_assert_eq "$rc" "0" "AC2: the pick under genuine set -e must exit 0 (got $rc): $out"
ac_assert_file "$TAPE2/tape.jsonl" "AC2: set-e kill — no proposal line written"
ac_assert_eq "$(wc -l < "$TAPE2/tape.jsonl")" "1" "AC2: a fresh pick under set -e appends exactly one proposal line"
LINE="$(head -n 1 "$TAPE2/tape.jsonl")"
ac_assert_jq '.type == "proposal" and .loop == "dev" and .decision == "approved" and .ref == "1633" and .class == "backlog" and .context.open_prs == 3 and .forecast == null and .context.jev == null and .context.forecast_method == null' \
  "$LINE" \
  "AC2: under genuine set -e the pick still writes a proposal with no forecast/Jev"
if [[ -f "$TAPE2/cf.log" ]] || [[ -f "$TAPE2/jev.log" ]]; then
  ac_fail "AC2: a forecast/Jev probe fired under set -e (cf.log: $(tr '\n' ' ' < "$TAPE2/cf.log" 2>/dev/null); jev.log: $(tr '\n' ' ' < "$TAPE2/jev.log" 2>/dev/null))"
fi
ac_log "AC2: the pick survives the live (no-guard) set -e context"

# AC3: the extracted emitter references neither the forecast machinery nor the
# Jev-scope door. (Static belt-and-braces complement to AC1/AC2's probe absence.)
ac_log "AC3: the extracted emitter references neither the forecast machinery nor the Jev-scope door"
if printf '%s\n' "$FN_SRC" | grep -Eq 'catalog_forecast|CATALOG_FORECAST_METHOD'; then
  ac_fail "AC3: emit_tape_proposal still references the catalog forecast machinery (catalog_forecast / CATALOG_FORECAST_METHOD)"
fi
if printf '%s\n' "$FN_SRC" | grep -Eq 'JEV_SCOPE_TOOL|tools/jev-scope|jev-scope|context\.jev|jev_state|jev_out|jev_rc|jev_nouls|jev_tool'; then
  ac_fail "AC3: emit_tape_proposal still references the Jev-scope door (JEV_SCOPE_TOOL / jev-)"
fi
ac_log "AC3: the extracted emitter carries neither the forecast machinery nor the Jev-scope door"

ac_log "all acceptance criteria met for issue 1632"
ac_pass
