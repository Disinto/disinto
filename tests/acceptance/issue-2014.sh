#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2014.sh
#
# Issue #2014: dev/dev-poll.sh's emit_tape_proposal() must name the model the
# local server actually serves.  context.backend takes the served model first
# (served_model_id, lib/served-model.sh, #2013) — the local model server
# ignores the requested model name, so the config chain can name a model that
# no longer runs — and only then falls back to DSH_MODEL > CLAUDE_MODEL >
# AGENT_HARNESS, omitting the key when nothing is known.
#
# Acceptance (hermetic — stub curl on PATH, no network, no live services, no
# pick triggered; the emitter is exercised in-process via the shared
# ac_run_tape_emit runner, the same extract-and-stub pattern as
# issue-1443.sh):
#   AC1  stub serving {"data":[{"id":"served-x"}]} at */models*,
#        DSH_BASE_URL=http://x/v1, DSH_MODEL=configured
#        -> context.backend == "served-x"
#   AC2  stub fails the models call (exit 7), same env
#        -> context.backend == "configured" (DSH_MODEL fallback)
#   AC3  DSH_BASE_URL unset -> today's precedence applies (DSH_MODEL wins,
#        backend omitted when no model env is set)
#   AC4  bash -n dev/dev-poll.sh passes
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk jq

TARGET="$REPO_ROOT/dev/dev-poll.sh"
ac_assert_file "$TARGET" "dev-poll.sh must exist for the backend-source check"

# ── 0. Wiring: dev-poll sources lib/served-model.sh and takes backend from
#        served_model_id before the DSH_MODEL chain ──────────────────────────
grep -q '^source .*lib/served-model\.sh' "$TARGET" \
  || ac_fail "dev-poll.sh must source lib/served-model.sh (served model first)"
BACKEND_LINE="backend=\"\$(served_model_id)\""
grep -qF -- "$BACKEND_LINE" "$TARGET" \
  || ac_fail "dev-poll.sh must set backend from served_model_id first"

FN_SRC="$(ac_extract_fn emit_tape_proposal "$TARGET")"
[ -n "$FN_SRC" ] || ac_fail "could not extract emit_tape_proposal() from dev-poll.sh"

TMP_DIR="$(mktemp -d)"
PROJECT_NAME="acceptance-2014"   # sentinel — can never clobber a live id file
rm -f "/tmp/dev-proposal-id-${PROJECT_NAME}-*" 2>/dev/null || true
trap 'rm -rf "$TMP_DIR" /tmp/dev-proposal-id-acceptance-2014-*' EXIT

# ── Stub curl: hermetic forge stand-in plus a fake model server ──────────────
# */models* answers the served-model listing; AC_STUB_MODEL_FAIL=1 makes that
# call exit 7 (a dead server, like curl's failure on an unreachable host).
# */issues/* and */pulls* answer like the shared fake forge; AC_STUB_FAIL=1
# makes every call fail.
STUB_BIN="$TMP_DIR/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/curl" <<'STUB_2014'
#!/usr/bin/env bash
# Fake forge + fake model server for issue-2014. The URL is the http(s)
# argument, never a flag like -sf or -m 5.
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
if [ -n "${AC_STUB_FAIL:-}" ]; then exit 22; fi
case "$url" in
  *models*)
    if [ -n "${AC_STUB_MODEL_FAIL:-}" ]; then exit 7; fi
    printf '%s' '{"data":[{"id":"served-x"}]}'
    ;;
  *issues*)
    printf '%s' '{"labels":[{"name":"backlog"}]}'
    ;;
  *pulls*)
    printf '%s' '[{"number":1},{"number":2},{"number":3}]'
    ;;
  *) exit 22 ;;
esac
STUB_2014
chmod +x "$STUB_BIN/curl"

# The extracted emitter logs through log(); the subshells inherit this
# stand-in so its lines land in the runner's captured output.
log() { echo "poll: $*"; }

# run_emit <TAPE_DIR> <issue> <base-url> <dsh> <claude> <harness> <model-fail>
# Runs the extracted emitter via ac_run_tape_emit (stub curl on PATH, real
# lib/tape.sh + lib/served-model.sh, sentinel PROJECT_NAME, caller's TAPE_DIR).
run_emit() {
  local tape_dir="$1" issue="$2" base="${3:-}" dsh="${4:-}" claude="${5:-}" \
    harness="${6:-}" model_fail="${7:-0}"
  local stub_model_fail=""
  if [ "$model_fail" = "1" ]; then stub_model_fail="1"; fi
  DSH_BASE_URL="$base" DSH_MODEL="$dsh" CLAUDE_MODEL="$claude" \
    AGENT_HARNESS="$harness" AC_STUB_MODEL_FAIL="$stub_model_fail" \
    ac_run_tape_emit "$STUB_BIN" "$tape_dir" "$FN_SRC" 0 \
      emit_tape_proposal "$issue"
}

first_line() {
  head -n 1 "$1/tape.jsonl"
}

# ── AC1: the served model wins over the config chain ─────────────────────────
TAPE1="$TMP_DIR/tape-1"
rc=0
out="$(run_emit "$TAPE1" 2014 "http://x/v1" "configured" "" "")" || rc=$?
ac_assert_eq "$rc" "0" "AC1: emit_tape_proposal must return 0 (served model available): $out"
ac_assert_file "$TAPE1/tape.jsonl" "AC1: no tape record was appended to $TAPE1/tape.jsonl"
ac_assert_eq "$(wc -l < "$TAPE1/tape.jsonl")" "1" "AC1: a pick must append exactly one tape line"
ac_assert_jq '.type == "proposal" and .loop == "dev" and .decision == "approved" and .ref == "2014" and .class == "backlog" and .context.open_prs == 3 and .context.backend == "served-x"' \
  "$(first_line "$TAPE1")" \
  "AC1: with a server reporting served-x at DSH_BASE_URL, context.backend must name the served model, not DSH_MODEL"

# ── AC2: a server that does not answer falls back to DSH_MODEL ───────────────
TAPE2="$TMP_DIR/tape-2"
rc=0
out="$(run_emit "$TAPE2" 2015 "http://x/v1" "configured" "" "" 1)" || rc=$?
ac_assert_eq "$rc" "0" "AC2: emit_tape_proposal must return 0 when the model server fails: $out"
ac_assert_jq '.type == "proposal" and .ref == "2015" and .context.backend == "configured"' \
  "$(first_line "$TAPE2")" \
  "AC2: when the models call fails (exit 7), context.backend must fall back to DSH_MODEL"

# ── AC3: DSH_BASE_URL unset — today's precedence, omitted when nothing is set ─
TAPE3="$TMP_DIR/tape-3"
rc=0
out="$(run_emit "$TAPE3" 2016 "" "dsh-model-2014" "claude-model-2014" "harness-2014")" || rc=$?
ac_assert_eq "$rc" "0" "AC3: emit_tape_proposal must return 0 (no base url, model env set): $out"
ac_assert_jq '.type == "proposal" and .ref == "2016" and .context.backend == "dsh-model-2014"' \
  "$(first_line "$TAPE3")" \
  "AC3: with DSH_BASE_URL unset, backend must follow DSH_MODEL > CLAUDE_MODEL > AGENT_HARNESS"

TAPE4="$TMP_DIR/tape-4"
rc=0
out="$(run_emit "$TAPE4" 2017 "" "" "" "")" || rc=$?
ac_assert_eq "$rc" "0" "AC3: emit_tape_proposal must return 0 (no base url, no model env): $out"
ac_assert_jq '.type == "proposal" and .ref == "2017" and (.context | has("backend") | not)' \
  "$(first_line "$TAPE4")" \
  "AC3: when no server is configured and no model env is set, the backend key must be omitted"

# ── AC4: dev-poll.sh still parses ────────────────────────────────────────────
bash -n "$TARGET" || ac_fail "AC4: dev/dev-poll.sh must pass bash -n syntax check"

ac_pass
