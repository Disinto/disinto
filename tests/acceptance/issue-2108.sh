#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2108.sh
#
# Issue #2108: docker/agents/entrypoint.sh records its own rollout evidence
# (lib/rollout-evidence.sh, #2106): the commit its factory checkout runs, the
# smoke exit on a NEW commit, and each fast organ's exit after every iteration.
# The bare `wait "${FAST_PIDS[@]}"` is replaced by wait_fast_organs, which waits
# per pid (so every organ's exit is recorded) and still returns the LAST pid's
# code, so the entrypoint exits the same way it used to.
#
# Acceptance:
#   1. FAST_PIDS = ((exit 0) &) then ((exit 3) &), FAST_ROLES=(review dev):
#      wait_fast_organs returns 3 and the evidence file holds two poll lines —
#      review rc 0, dev rc 3.
#   2. The same with the exits swapped returns 0.
#   3. A temp git repo as DISINTO_LIVE/DISINTO_DIR whose
#      .woodpecker/agent-smoke.sh prints "boom" and exits 1: record_factory_take
#      appends one take line with smoke 1 and a smoke_tail containing "boom"; a
#      second call appends nothing (same HEAD).
#   4. grep -cF 'wait "${FAST_PIDS[@]}"' docker/agents/entrypoint.sh prints 0,
#      and bash -n on the entrypoint passes.
#
# Hermetic: no network, no forge, no nomad — a temp TAPE_DIR per AC, a temp
# DISINTO_LOG_DIR, NOMAD_JOB_NAME=agents-test, gosu() stubbed as
# `gosu() { shift; "$@"; }`, factory_ref prints "canary", log() is a no-op.
# The two entrypoint functions are extracted with ac_extract_fn and eval'd
# against the REAL lib/rollout-evidence.sh.
#
# Run via: bash tests/acceptance/issue-2108.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq git mktemp tail grep awk timeout

ENTRYPOINT="$REPO_ROOT/docker/agents/entrypoint.sh"
EVIDENCE_LIB="$REPO_ROOT/lib/rollout-evidence.sh"
ac_assert_file "$ENTRYPOINT" "docker/agents/entrypoint.sh must exist"
ac_assert_file "$EVIDENCE_LIB" "lib/rollout-evidence.sh must exist"

WFO_SRC="$(ac_extract_fn wait_fast_organs "$ENTRYPOINT")"
[ -n "$WFO_SRC" ] || ac_fail "could not extract wait_fast_organs() from the entrypoint"
RFT_SRC="$(ac_extract_fn record_factory_take "$ENTRYPOINT")"
[ -n "$RFT_SRC" ] || ac_fail "could not extract record_factory_take() from the entrypoint"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

export NOMAD_JOB_NAME=agents-test
export DISINTO_LOG_DIR="$TMP_DIR/logs"
mkdir -p "$DISINTO_LOG_DIR"

# run_evidence_fn <fn-source> <prelude> <live> <dir> <fn-name>...
# Run extracted entrypoint function(s) in ONE throwaway subshell, so the
# entrypoint's globals (FAST_PIDS, FAST_ROLES, _TAKEN_COMMIT) survive between
# calls: the real evidence lib sourced, gosu/factory_ref/log stubbed,
# DISINTO_LIVE/DISINTO_DIR set, <prelude> eval'd, then each <fn-name> called in
# order. stdout/stderr go to the caller; the exit status is the last call's.
run_evidence_fn() {
  local fn_src="$1" prelude="$2" live="$3" dir="$4"
  shift 4
  (
    # shellcheck disable=SC1091
    source "$EVIDENCE_LIB"
    eval "$fn_src"
    # shellcheck disable=SC2317
    gosu() { shift; "$@"; }
    # shellcheck disable=SC2317
    factory_ref() { printf 'canary\n'; }
    # shellcheck disable=SC2317
    log() { :; }
    # The extracted functions read these; exporting keeps shellcheck from
    # calling them unused.
    export DISINTO_LIVE="$live"
    export DISINTO_DIR="$dir"
    # The entrypoint calls rollout_evidence_init once before the loop (#2108).
    rollout_evidence_init
    eval "$prelude"
    for fn in "$@"; do
      "$fn"
    done
  )
}

# poll_lines <file> — the poll lines in a evidence file, as "role rc" pairs.
poll_lines() {
  jq -r 'select(.kind == "poll") | "\(.role) \(.rc) \(.ref) \(.commit)"' "$1"
}

# ── AC1: two fast organs, last one fails -> rc 3, two poll lines ──────────────
EV1="$TMP_DIR/ev-ac1"
export ROLLOUT_EVIDENCE_DIR="$EV1"
PRELUDE1='FAST_PIDS=(); FAST_ROLES=(); ( exit 0 ) & FAST_PIDS+=($!); FAST_ROLES+=(review); ( exit 3 ) & FAST_PIDS+=($!); FAST_ROLES+=(dev)'
rc=0
out=""
out="$(run_evidence_fn "$WFO_SRC" "$PRELUDE1" "$TMP_DIR/live1" "$TMP_DIR/live1" wait_fast_organs)" || rc=$?
ac_assert_eq "$rc" "3" "AC1: wait_fast_organs must return the last organ's exit code (got $rc, out: $out)"
lines="$(poll_lines "$EV1/agents-test.jsonl")"
ac_assert_eq "$(printf '%s\n' "$lines" | wc -l)" "2" "AC1: two poll lines must be recorded, got: $lines"
case "$lines" in
  *"review 0 canary "*"dev 3 canary "*) ac_log "AC1: poll lines review rc 0 / dev rc 3, function returned 3" ;;
  *) ac_fail "AC1: poll lines must be review rc 0 and dev rc 3, got: $lines" ;;
esac

# ── AC2: exits swapped -> rc 0 ────────────────────────────────────────────────
EV2="$TMP_DIR/ev-ac2"
export ROLLOUT_EVIDENCE_DIR="$EV2"
PRELUDE2='FAST_PIDS=(); FAST_ROLES=(); ( exit 3 ) & FAST_PIDS+=($!); FAST_ROLES+=(review); ( exit 0 ) & FAST_PIDS+=($!); FAST_ROLES+=(dev)'
rc=0
run_evidence_fn "$WFO_SRC" "$PRELUDE2" "$TMP_DIR/live2" "$TMP_DIR/live2" wait_fast_organs >/dev/null || rc=$?
lines="$(poll_lines "$EV2/agents-test.jsonl")"
ac_assert_eq "$rc" "0" "AC2: a last organ that exits 0 must make wait_fast_organs return 0"
ac_assert_eq "$(printf '%s\n' "$lines" | wc -l)" "2" "AC2: two poll lines must be recorded, got: $lines"
case "$lines" in
  *"review 3 canary "*"dev 0 canary "*) ac_log "AC2: swapped exits -> returned 0, both organ exits still recorded" ;;
  *) ac_fail "AC2: poll lines must be review rc 3 and dev rc 0, got: $lines" ;;
esac

# ── AC3: a live checkout records one take line per new commit ─────────────────
LIVE="$TMP_DIR/factory"
mkdir -p "$LIVE/.woodpecker"
git init -q "$LIVE"
git -C "$LIVE" config user.name "evidence-test"
git -C "$LIVE" config user.email "evidence-test@example.com"
cat > "$LIVE/.woodpecker/agent-smoke.sh" <<'EOF'
#!/usr/bin/env bash
echo boom
exit 1
EOF
printf '# factory\n' > "$LIVE/README.md"
git -C "$LIVE" add -A
git -C "$LIVE" commit -q -m "canary commit"
HEAD_SHA="$(git -C "$LIVE" rev-parse HEAD)"

EV3="$TMP_DIR/ev-ac3"
export ROLLOUT_EVIDENCE_DIR="$EV3"
rc=0
# Both calls share one subshell, so the entrypoint's _TAKEN_COMMIT global
# survives between them: the second call must find the same HEAD and append
# nothing.
run_evidence_fn "$RFT_SRC" '_TAKEN_COMMIT=""' "$LIVE" "$LIVE" record_factory_take record_factory_take >/dev/null || rc=$?
ac_assert_eq "$rc" "0" "AC3: record_factory_take must return 0 even when the smoke fails"
if [ "$(wc -l <"$EV3/agents-test.jsonl")" != "1" ]; then
  ac_fail "AC3: exactly one take line must be recorded, got: $(cat "$EV3/agents-test.jsonl")"
fi
line="$(head -1 "$EV3/agents-test.jsonl")"
ac_assert_jq '.kind == "take" and .ref == "canary"' "$line" "AC3: the take line must be a take line for the canary ref"
ac_assert_eq "$(jq -r '.commit' <<< "$line")" "$HEAD_SHA" "AC3: the take line must record the checkout's HEAD"
ac_assert_jq '.smoke == 1' "$line" "AC3: the take line must record the smoke's exit code 1"
ac_assert_jq '.smoke_tail | test("boom")' "$line" "AC3: the take line must carry the smoke log's tail when the smoke failed"
if ! grep -q 'boom' "$DISINTO_LOG_DIR/agent-smoke.log"; then
  ac_fail "AC3: the smoke output must be logged to agent-smoke.log"
fi
ac_log "AC3: one take line for the new commit (smoke 1, tail 'boom'), none for the unchanged HEAD"

# A baked checkout records nothing (#2108: only a live checkout is evidence).
rc=0
run_evidence_fn "$RFT_SRC" '_TAKEN_COMMIT=""' "$LIVE" "$TMP_DIR/baked" record_factory_take >/dev/null || rc=$?
ac_assert_eq "$rc" "0" "AC3: record_factory_take must return 0 on a baked checkout"
ac_assert_eq "$(wc -l <"$EV3/agents-test.jsonl")" "1" "AC3: a baked checkout (DISINTO_DIR != DISINTO_LIVE) must record no take line"

# ── AC4: the bare wait is gone and the entrypoint still parses ─────────────────
# AC4: the single quotes are deliberate — the grep pattern is a literal.
# shellcheck disable=SC2016
count="$(grep -cF 'wait "${FAST_PIDS[@]}"' "$ENTRYPOINT" || true)"
ac_assert_eq "$count" "0" "AC4: the bare wait of all fast pids must be gone (count=${count})"
bash -n "$ENTRYPOINT" || ac_fail "AC4: bash -n failed on docker/agents/entrypoint.sh"
ac_log "AC4: no bare wait of all fast pids, and the entrypoint parses"

echo PASS
