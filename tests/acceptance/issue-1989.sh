#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1989.sh
#
# Issue #1989: the healer marked a public URL unfixable on another URL's
# edge cooldown.
#
# The bug (flagged by AI review in PR #1987): handle_public_endpoints recorded
# unfixable whenever the URL was still down, its backend healthy, and the
# target job (edge) was in cooldown. Cooldown is per job, not per URL, so an
# edge restart for /forge/ (or any other edge restart within
# HEALER_COOLDOWN_SECS) declared a different down URL such as /ci/ unfixable
# on the first tick its failure streak was high enough — without an endpoint
# restart ever being attempted for /ci/. PR #1987 additionally pages the owner
# on the tick unfixable is recorded, so the borrowed cooldown also paged the
# owner with the cloudflared text for the innocent URL.
#
# The fix gates the unfixable record on the URL's *own* endpoint restart
# (its endpoint_open entry), not the shared per-job cooldown.
#
# Hermetic: shared curl + nomad stubs, a notify stub that records its
# single message argument, and `--once` ticks driven by HEALER_TEST_NOW so no
# real sleep is needed. HEALER_TEST_COOLDOWN_SECS is small so the edge cooldown
# expires on a deliberately late tick within the run.
#
# Verifies:
#   AC1 (the regression): a down URL whose own streak is at the failure
#        threshold does not become unfixable while a sibling URL's edge
#        restart is still in cooldown — and the owner is not paged for it.
#   AC2: once the sibling's cooldown expires, the previously "innocent" URL
#        gets its own edge restart, and is declared unfixable only after that
#        own restart (owner paged then).
#
# Run via: tools/run-acceptance.sh 1989
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"
# shellcheck source=../lib/healer-stubs.sh
source "$REPO_ROOT/tests/lib/healer-stubs.sh"

ac_require_cmd bash jq grep mktemp date flock

HEALER="$REPO_ROOT/bin/healer.sh"
ac_assert_file "$HEALER" "bin/healer.sh must exist"

# The unfixable decision must be per-URL (its own restart), not the shared
# per-job cooldown.
grep -qF 'own_endpoint_restart' "$HEALER" \
  || ac_fail "unfixable must be gated on the URL's own endpoint restart"
grep -qF 'HEALER_TEST_COOLDOWN_SECS' "$REPO_ROOT/tests/lib/healer-stubs.sh" \
  || ac_fail "stubs must support a test cooldown override"

# Shared fake curl/nomad + the three registered services.
ac_healer_init "${TMPDIR:-/tmp}/healer-1989.XXXXXX"
ac_healer_public_fixtures

STATE_DIR="$WORK/state"
TAPE_DIR="$WORK/tape"
STUB_LOG="$WORK/nom-1.log"
mkdir -p "$STATE_DIR" "$TAPE_DIR"
: > "$STUB_LOG"

# Recording notify stub: its single message argument is the condition; write
# it to $NOTIFY_LOG so the test can assert what (and when) the owner was paged.
NOTIFY_LOG="$WORK/notify.log"
: > "$NOTIFY_LOG"
cat > "$BIN/notify-owner" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ -n "${NOTIFY_LOG:-}" ] || { echo "notify stub: NOTIFY_LOG unset" >&2; exit 1; }
printf '%s\n' "${1:-}" >> "$NOTIFY_LOG"
exit 0
STUB
chmod +x "$BIN/notify-owner"
export NOTIFY_LOG
export HEALER_TEST_NOTIFY_CMD="$BIN/notify-owner"
# 30s cooldown: the sibling's edge restart expires on a deliberately late
# tick (1045 > 1010 + 30), so the "innocent" URL gets its own restart without
# a real sleep.
export HEALER_TEST_COOLDOWN_SECS=30
export HEALER_TEST_ESCALATE_AFTER_SECS=1800
export HEALER_TEST_REMIND_SECS=86400

# Both endpoints down for the whole run; backends healthy (edge is the target).
set_probe_code forge 502
set_probe_code ci 502
set_probe_code forgejo 200
set_probe_code woodpecker 200

# One `--once` tick at an explicit epoch (no real sleep).
tick() {
  local now="$1"
  export HEALER_TEST_NOW="$now"
  healer_run_once "$STATE_DIR" "$TAPE_DIR"
}

edge_restarts() {
  healer_restarts_of "edge"
}

# Count owner messages about one URL's condition.
notify_for() {
  grep -c "public-endpoint-down:${1}" "$NOTIFY_LOG" || true
}

# URL is unfixable in state.json? 0 = yes, 1 = no.
is_unfixable() {
  jq -e --arg u "$1" '.unfixable // {} | has($u)' \
    "$STATE_DIR/state.json" >/dev/null 2>&1
}

# ── AC1: innocent /ci/ stays unfixable-free while /forge/'s edge cools ─────
ac_log "AC1: /forge/ restarts edge at tick 1010; /ci/ reaches its own threshold
        at the same tick and remains inside the sibling's 30s cooldown"
tick 1000   # forge streak 1, ci streak 1
tick 1005   # forge streak 2, ci streak 2
tick 1010   # forge streak 3 -> restart edge (cooling). ci streak 3 ->
            # in_cooldown(edge) true but no own ci restart -> must NOT be
            # unfixable (the regression).
tick 1015   # forge -> unfixable (own restart cooling). ci streak 4, still in
            # the sibling cooldown, no own restart -> still not unfixable.

ac_log "AC1 assertions"
ac_assert_eq "$(edge_restarts)" "1" \
  "AC1 exactly one edge restart (forge only), got $(edge_restarts)"
ac_assert_eq "$(notify_for "https://self.disinto.ai/forge/")" "1" \
  "AC1 forge paged once when it became unfixable"
if is_unfixable "https://self.disinto.ai/forge/"; then
  :
else
  ac_fail "AC1 /forge/ must be unfixable after its own restart"
fi
if is_unfixable "https://self.disinto.ai/ci/"; then
  ac_fail "AC1 /ci/ must NOT be unfixable while only the sibling edge cools: $(cat "$NOTIFY_LOG")"
fi
ac_assert_eq "$(notify_for "https://self.disinto.ai/ci/")" "0" \
  "AC1 the owner must not be paged for /ci/ during the sibling cooldown"
ac_log "AC1 passed"

# ── AC2: once the cooldown expires the innocent URL gets its own restart ───
ac_log "AC2: after the sibling cooldown expires, /ci/ gets its own edge restart
        and is only then declared unfixable"
tick 1045   # 1045 > 1010 + 30 -> edge cooldown expired. forge is unfixable
            # (note only). ci streak 5, in_cooldown(edge) now false -> restart
            # edge FOR ci (its own).
tick 1050   # ci's own restart cooling (1050 - 1045 < 30) -> ci becomes
            # unfixable.
ac_log "AC2 assertions"
ac_assert_eq "$(edge_restarts)" "2" \
  "AC2 a second (ci's own) edge restart after the cooldown, got $(edge_restarts)"
if is_unfixable "https://self.disinto.ai/ci/"; then
  :
else
  ac_fail "AC2 /ci/ must be unfixable only after its own restart"
fi
ac_assert_eq "$(notify_for "https://self.disinto.ai/ci/")" "1" \
  "AC2 the owner is paged for /ci/ only after its own unfixable"
ac_pass
