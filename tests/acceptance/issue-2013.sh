#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2013.sh
#
# Issue #2013: lib/served-model.sh defines served_model_id — the model id the
# local model server reports at $DSH_BASE_URL/models, so the formula tape
# (formula_tape_agent) and dev-poll can share one lookup instead of
# duplicating the curl pipeline.
#
# Acceptance (hermetic: a stub `curl` on PATH logs its arguments; no forge,
# no nomad, no daemon, no network):
#   1. Stub prints {"data":[{"id":"m1"}]}, AGENT_HARNESS unset,
#      DSH_BASE_URL=http://x/v1 -> served_model_id prints m1, and the stub
#      was called with http://x/v1/models.
#   2. Stub exits 7 -> prints nothing, returns 0.
#   3. DSH_PROVIDER=xai, or AGENT_HARNESS=claude, or DSH_BASE_URL unset ->
#      prints nothing, and the stub is never called.
#   4. grep -c '/models' lib/formula-session.sh prints 0, and
#      bats tests/lib-formula-tape.bats passes.
#
# Run via: tools/run-acceptance.sh 2013
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq bats

LIB="$REPO_ROOT/lib/served-model.sh"
FORMULA="$REPO_ROOT/lib/formula-session.sh"
BATS_FILE="$REPO_ROOT/tests/lib-formula-tape.bats"
ac_assert_file "$LIB" "lib/served-model.sh must exist"
ac_assert_file "$FORMULA" "lib/formula-session.sh must exist"
ac_assert_file "$BATS_FILE" "tests/lib-formula-tape.bats must exist"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Control the harness env: the probes set exactly what they need.
unset AGENT_HARNESS DSH_PROVIDER DSH_BASE_URL CLAUDE_MODEL

# ── The curl stub ───────────────────────────────────────────────────────────
# Logs every invocation's arguments to $CURL_LOG. MODE=ok prints the models
# response; MODE=fail exits 7 like an unreachable server.
cat > "$WORK/curl" <<'STUB_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
if [ "${MODE:-ok}" = fail ]; then
  exit 7
fi
printf '{"data":[{"id":"m1"}]}'
STUB_EOF
chmod +x "$WORK/curl"

# run_probe <mode> [VAR=VALUE ...] — sources lib/served-model.sh and calls
# served_model_id with MODE and the given env vars; sets PROBE_OUT and
# PROBE_STATUS. CURL_LOG is reset before each run.
run_probe() {
  local mode="$1"; shift
  MODE="$mode" CURL_LOG="$WORK/curl.log"
  rm -f "$CURL_LOG"
  export MODE CURL_LOG
  PROBE_STATUS=0
  PROBE_OUT="$(env PATH="$WORK:$PATH" "$@" \
    bash -c 'set -euo pipefail
source "$1/lib/served-model.sh"
served_model_id' _ "$REPO_ROOT")" || PROBE_STATUS=$?
}

# ── AC 1: local dsh agent with a answering server -> the served id ──────────
ac_log "AC 1: stub answers, AGENT_HARNESS unset -> served_model_id prints m1 and hits http://x/v1/models"
run_probe ok DSH_BASE_URL=http://x/v1
ac_assert_eq "$PROBE_STATUS" "0" "served_model_id must return 0 (got $PROBE_STATUS)"
ac_assert_eq "$PROBE_OUT" "m1" "served_model_id must print m1 (got '${PROBE_OUT}')"
if ! grep -q 'http://x/v1/models' "$WORK/curl.log"; then
  ac_fail "the curl stub must have been called with http://x/v1/models (log: $(cat "$WORK/curl.log"))"
fi
ac_log "AC 1 OK"

# ── AC 2: server failure -> nothing printed, still returns 0 ────────────────
ac_log "AC 2: stub exits 7 -> empty output, return 0"
run_probe fail DSH_BASE_URL=http://x/v1
ac_assert_eq "$PROBE_STATUS" "0" "served_model_id must return 0 even when curl fails (got $PROBE_STATUS)"
ac_assert_eq "$PROBE_OUT" "" "served_model_id must print nothing when the server fails (got '${PROBE_OUT}')"
ac_log "AC 2 OK"

# ── AC 3: not a local dsh agent -> the stub is never called ──────────────────
ac_log "AC 3a: DSH_PROVIDER=xai -> no output, stub never called"
run_probe ok DSH_BASE_URL=http://x/v1 DSH_PROVIDER=xai
ac_assert_eq "$PROBE_STATUS" "0" "served_model_id must return 0 (got $PROBE_STATUS)"
ac_assert_eq "$PROBE_OUT" "" "served_model_id must print nothing for a non-llamacpp provider (got '${PROBE_OUT}')"
if [ -e "$WORK/curl.log" ]; then
  ac_fail "the curl stub must never be called when DSH_PROVIDER is not llamacpp"
fi

ac_log "AC 3b: AGENT_HARNESS=claude -> no output, stub never called"
run_probe ok AGENT_HARNESS=claude DSH_BASE_URL=http://x/v1
ac_assert_eq "$PROBE_STATUS" "0" "served_model_id must return 0 (got $PROBE_STATUS)"
ac_assert_eq "$PROBE_OUT" "" "served_model_id must print nothing for the claude harness (got '${PROBE_OUT}')"
if [ -e "$WORK/curl.log" ]; then
  ac_fail "the curl stub must never be called for AGENT_HARNESS=claude"
fi

ac_log "AC 3c: DSH_BASE_URL unset -> no output, stub never called"
run_probe ok
ac_assert_eq "$PROBE_STATUS" "0" "served_model_id must return 0 (got $PROBE_STATUS)"
ac_assert_eq "$PROBE_OUT" "" "served_model_id must print nothing when DSH_BASE_URL is unset (got '${PROBE_OUT}')"
if [ -e "$WORK/curl.log" ]; then
  ac_fail "the curl stub must never be called when DSH_BASE_URL is unset"
fi
ac_log "AC 3 OK"

# ── AC 4: formula-session.sh no longer inlines the lookup; bats suite passes ─
ac_log "AC 4: lib/formula-session.sh contains no '/models' and the tape bats suite passes"
models_count="$(grep -c '/models' "$FORMULA" || true)"
ac_assert_eq "$models_count" "0" \
  "lib/formula-session.sh must not reference '/models' anymore (got ${models_count})"

bats "$BATS_FILE" >/dev/null 2>&1 \
  || ac_fail "bats tests/lib-formula-tape.bats failed"
ac_log "AC 4 OK"

ac_pass
