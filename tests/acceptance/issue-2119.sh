#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2119.sh
#
# Issue #2119: the canary rollout fails closed (docs/design/notes/self-update.md)
# — if tools/rollout.sh breaks, nothing moves, every agent keeps the last good
# version, and nobody notices. The check sits outside the tool: bin/healer.sh
# runs bin/live-lag.sh each tick (it runs from /opt/disinto, not from live),
# and lib/notice.sh queues exactly one owner notice when `live` has trailed
# `main` for lag_notice_h hours (ops packs/rollout.toml, default 24) with no
# promotion. The notices drain (#2032) sends it in the same tick.
#
# Contract under test (bin/live-lag.sh):
#   * heads: `timeout 20 git -C ${FACTORY_ROOT:-/opt/disinto} ls-remote origin
#     refs/heads/main refs/heads/live`; a failure or a missing `live` exits 0
#     and leaves the state file untouched.
#   * hours: integer lag_notice_h from ${ROLLOUT_PACK_FILE:-
#     /srv/disinto/ops-repo/packs/rollout.toml}, flat TOML; missing file or key
#     means 24.
#   * state: ${HEALER_STATE_DIR:-/srv/disinto/healer}/live-lag.json,
#     {"live":"<sha>","since":<epoch>|null,"told":0|1}, temp file then mv.
#   * live == main -> {live, since null, told 0}, no notice.
#   * live behind, since null or the stored live differs -> since = now, told 0.
#   * live behind, now - since > hours*3600, told 0 -> one notice naming both
#     short SHAs; told 1 after a successful queue, told stays 0 after a failed
#     one.
#   * every path exits 0.
#
# Hermetic: a bare repo as origin plus a clone (tests/lib/rollout-fixture.sh),
# a temp HEALER_STATE_DIR and NOTICES_DIR, a pack with lag_notice_h = 24,
# HEALER_NOW pinned. No git remote, no network, no services.
#
# Acceptance:
#   1. live == main: no notice, since null.
#   2. live behind: a run at 1000 sets since 1000 with no notice; a run at
#      87401 queues exactly one notice naming live's and main's short SHAs and
#      sets told 1; a further run queues none.
#   3. live moved forward but still behind, after the notice: since resets to
#      that run's clock, told 0, no new notice.
#   4. no live branch: exit 0, no state file.
#   5. no pack: the 24 h default applies (nothing at 86400, notice at 87401).
#   6. a notice that cannot be queued leaves told 0, so the next tick retries.
#   7. bin/healer.sh runs the check once, after escalate_pass and before the
#      notices drain; bin/live-lag.sh and bin/healer.sh pass bash -n;
#      tests/lib/healer-stubs.sh passes HEALER_LIVE_LAG so the healer tests
#      make no git call.
#   8. a real `healer.sh --once` tick (stubbed Nomad, a recording sender) runs
#      bin/live-lag.sh and sends the notice it queued in the same tick.
#
# Run via `tools/run-acceptance.sh 2119` or `bash tests/acceptance/issue-2119.sh`.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"
# shellcheck source=../lib/rollout-fixture.sh
source "$REPO_ROOT/tests/lib/rollout-fixture.sh"
# shellcheck source=../lib/healer-stubs.sh
source "$REPO_ROOT/tests/lib/healer-stubs.sh"

ac_require_cmd bash git jq timeout date

TOOL="$REPO_ROOT/bin/live-lag.sh"
ac_assert_file "$TOOL" "bin/live-lag.sh is missing"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/issue-2119.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PACK="$WORK/rollout.toml"
printf 'lag_notice_h = 24\nsoak_s = 1800\n' > "$PACK"

# fixture NAME — a fresh origin/clone pair (main at M2, live at M1) plus the
# temp state dir and notices queue this AC runs with.
fixture() {
  local name="$1"
  rollout_fixture "$name"
  STATE_DIR="$WORK/$name/healer"
  NOTICES_DIR="$WORK/$name/notices"
}

# run_lag NOW [pack] — one run of bin/live-lag.sh. RC holds the status, OUT the
# combined stdout/stderr.
run_lag() {
  local now="$1" pack="${2:-$PACK}"
  RC=0
  # shellcheck disable=SC2034  # OUT is consumed by the assertions below
  OUT="$(FACTORY_ROOT="$CLONE" HEALER_STATE_DIR="$STATE_DIR" \
        NOTICES_DIR="$NOTICES_DIR" ROLLOUT_PACK_FILE="$pack" \
        HEALER_NOW="$now" bash "$TOOL" 2>&1)" || RC=$?
}

notice_count() {
  find "$NOTICES_DIR" -maxdepth 1 -type f -name '*.txt' 2>/dev/null | wc -l | tr -d ' '
}

state() {
  cat "$STATE_DIR/live-lag.json" 2>/dev/null || echo '{}'
}

# ── AC1: live caught up — no notice, the clock is off ────────────────────────
ac_log "AC1: live == main -> no notice, since null, told 0"
fixture ac1
git -C "$CLONE" push --quiet origin "$M2:refs/heads/live"
run_lag 5000
ac_assert_eq "$RC" "0" "AC1 a caught-up run must exit 0, got $RC: $OUT"
ac_assert_eq "$(notice_count)" "0" "AC1 a caught-up live queues no notice"
S="$(state)"
jq -e --arg m2 "$M2" '.live == $m2 and .since == null and .told == 0' <<<"$S" >/dev/null \
  || ac_fail "AC1 the state must record live $M2 with a null clock: $S"
ac_log "AC1 OK"

# ── AC2: live behind — the clock starts, one notice after 24 h, then silence ──
ac_log "AC2: live behind main -> since 1000, one notice at 87401, none after"
fixture ac2
run_lag 1000
ac_assert_eq "$RC" "0" "AC2 the first run must exit 0, got $RC: $OUT"
S="$(state)"
jq -e --arg m1 "$M1" '.live == $m1 and .since == 1000 and .told == 0' <<<"$S" >/dev/null \
  || ac_fail "AC2 the first run must start the clock at 1000: $S"
ac_assert_eq "$(notice_count)" "0" "AC2 a run that only starts the clock queues no notice"

run_lag 87401
ac_assert_eq "$RC" "0" "AC2 the lagging run must exit 0, got $RC: $OUT"
ac_assert_eq "$(notice_count)" "1" "AC2 the 24 h lag must queue exactly one notice"
NOTICE="$(find "$NOTICES_DIR" -maxdepth 1 -type f -name '*.txt' | head -n 1)"
TEXT="$(cat "$NOTICE")"
case "$TEXT" in
  *"live ${M1:0:7}"*) ;;
  *) ac_fail "AC2 the notice must name live's short sha ${M1:0:7}: $TEXT" ;;
esac
case "$TEXT" in
  *"main ${M2:0:7}"*) ;;
  *) ac_fail "AC2 the notice must name main's short sha ${M2:0:7}: $TEXT" ;;
esac
case "$TEXT" in
  *"for 24 h"*) ;;
  *) ac_fail "AC2 the notice must say the lag is 24 h: $TEXT" ;;
esac
case "$TEXT" in
  *"disinto-admin push of live to a commit of main"*) ;;
  *) ac_fail "AC2 the notice must say how to unblock the rollout: $TEXT" ;;
esac
S="$(state)"
jq -e --arg m1 "$M1" '.live == $m1 and .since == 1000 and .told == 1' <<<"$S" >/dev/null \
  || ac_fail "AC2 a sent notice must set told 1 and keep since 1000: $S"

run_lag 90000
ac_assert_eq "$RC" "0" "AC2 a further run must exit 0, got $RC: $OUT"
ac_assert_eq "$(notice_count)" "1" "AC2 the owner is told once, not every tick"
ac_log "AC2 OK"

# ── AC3: live promoted to a new commit, still behind — the clock restarts ─────
ac_log "AC3: live moves forward but stays behind -> since resets, told 0, no notice"
fixture ac3
run_lag 1000
run_lag 87401
ac_assert_eq "$(notice_count)" "1" "AC3 the lag must have queued one notice first"

M3="$(commit_on main "M3")"
git -C "$CLONE" push --quiet origin main
git -C "$CLONE" push --quiet origin "$M3:refs/heads/live"
M4="$(commit_on main "M4")"
git -C "$CLONE" push --quiet origin main

run_lag 100000
ac_assert_eq "$RC" "0" "AC3 the restart run must exit 0, got $RC: $OUT"
ac_assert_eq "$(origin_head main)" "$M4" "AC3 main must still be ahead of the promoted live"
S="$(state)"
jq -e --arg m3 "$M3" '.live == $m3 and .since == 100000 and .told == 0' <<<"$S" >/dev/null \
  || ac_fail "AC3 a promoted live must restart the clock at 100000 with told 0: $S"
ac_assert_eq "$(notice_count)" "1" "AC3 the restarted clock queues no notice in its first tick"
ac_log "AC3 OK"

# ── AC4: no live branch — rollouts are not set up ─────────────────────────────
ac_log "AC4: origin has no live branch -> exit 0, no state file"
fixture ac4
git -C "$ORIGIN" update-ref -d refs/heads/live
run_lag 1000
ac_assert_eq "$RC" "0" "AC4 a missing live head must exit 0, got $RC: $OUT"
if [ -e "$STATE_DIR/live-lag.json" ]; then
  ac_fail "AC4 a missing live head must write no state file"
fi
ac_assert_eq "$(notice_count)" "0" "AC4 a missing live head queues no notice"
ac_log "AC4 OK"

# ── AC5: no pack — the 24 h default ───────────────────────────────────────────
ac_log "AC5: no pack file -> the 24 h default applies"
fixture ac5
run_lag 1000 "$WORK/does-not-exist.toml"
S="$(state)"
jq -e '.since == 1000' <<<"$S" >/dev/null || ac_fail "AC5 the first run must start the clock: $S"
run_lag 86400 "$WORK/does-not-exist.toml"
ac_assert_eq "$(notice_count)" "0" "AC5 at 85400 s of lag the 24 h default is not yet met"
run_lag 87401 "$WORK/does-not-exist.toml"
ac_assert_eq "$(notice_count)" "1" "AC5 at 86401 s of lag the 24 h default fires the notice"
NOTICE="$(find "$NOTICES_DIR" -maxdepth 1 -type f -name '*.txt' | head -n 1)"
case "$(cat "$NOTICE")" in
  *"for 24 h"*) ;;
  *) ac_fail "AC5 the default must be 24 h, got: $(cat "$NOTICE")" ;;
esac
ac_log "AC5 OK"

# ── AC6: a queue that cannot be written leaves told 0 so the next tick retries ─
ac_log "AC6: a failed notice keeps told 0 and retries on the next run"
fixture ac6
# A regular file where the queue directory belongs: mkdir -p fails, so
# notice_owner returns 1 and nothing is queued.
: > "$WORK/ac6-queue-blocked"
NOTICES_DIR="$WORK/ac6-queue-blocked"
run_lag 1000
run_lag 87401
ac_assert_eq "$RC" "0" "AC6 a failed notice must still exit 0, got $RC: $OUT"
S="$(state)"
jq -e '.told == 0' <<<"$S" >/dev/null \
  || ac_fail "AC6 a failed notice must keep told 0: $S"
NOTICES_DIR="$WORK/ac6-queue"
run_lag 87402
ac_assert_eq "$RC" "0" "AC6 the retry must exit 0, got $RC: $OUT"
ac_assert_eq "$(notice_count)" "1" "AC6 the retry must queue the notice the first run could not"
ac_log "AC6 OK"

# ── AC7: the wiring in the healer, and syntax ─────────────────────────────────
ac_log "AC7: healer_tick runs live-lag.sh after escalate_pass, before the drain"
lag_line="$(grep -n 'HEALER_LIVE_LAG:-[$]FACTORY_ROOT/bin/live-lag.sh' "$REPO_ROOT/bin/healer.sh" | head -n 1 | cut -d: -f1)"
esc_line="$(grep -n 'escalate_pass "[$]now" || log "WARNING: escalate pass failed"' "$REPO_ROOT/bin/healer.sh" | head -n 1 | cut -d: -f1)"
drain_line="$(grep -n 'HEALER_NOTICES_DRAIN:-[$]FACTORY_ROOT/bin/notices-drain.sh' "$REPO_ROOT/bin/healer.sh" | head -n 1 | cut -d: -f1)"
[ -n "$lag_line" ] || ac_fail "AC7 bin/healer.sh must run bin/live-lag.sh in the tick"
[ -n "$esc_line" ] || ac_fail "AC7 bin/healer.sh must still call escalate_pass in the tick"
[ -n "$drain_line" ] || ac_fail "AC7 bin/healer.sh must still call the notices drain in the tick"
[ "$lag_line" -gt "$esc_line" ] \
  || ac_fail "AC7 the live-lag line ($lag_line) must come after the escalate_pass line ($esc_line)"
[ "$lag_line" -lt "$drain_line" ] \
  || ac_fail "AC7 the live-lag line ($lag_line) must come before the drain line ($drain_line)"
ac_assert_eq "$(grep -cF 'HEALER_LIVE_LAG:-$FACTORY_ROOT/bin/live-lag.sh' "$REPO_ROOT/bin/healer.sh")" "1" \
  "AC7 the healer must call live-lag.sh exactly once"

bash -n "$TOOL" || ac_fail "AC7 bin/live-lag.sh has a syntax error"
bash -n "$REPO_ROOT/bin/healer.sh" || ac_fail "AC7 bin/healer.sh has a syntax error"
grep -qF 'HEALER_LIVE_LAG="${HEALER_TEST_LIVE_LAG:-true}"' "$REPO_ROOT/tests/lib/healer-stubs.sh" \
  || ac_fail "AC7 the healer stubs must neutralise the live-lag check (HEALER_LIVE_LAG)"

# ── AC8: a real tick runs the check and the drain sends it that same tick ──────
ac_log "AC8: healer.sh --once runs bin/live-lag.sh and drains the notice it queues"
fixture ac8
export DATA="$WORK/ac8-nomad"
export BIN="$WORK/ac8-bin"
export STUB_LOG="$WORK/ac8-nomad-calls"
export HEALER="$REPO_ROOT/bin/healer.sh"
ac_healer_stubs
ac_healer_public_fixtures

SENDER="$WORK/ac8-sender"
cat > "$SENDER" <<'SEND'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "$RECORD"
SEND
chmod +x "$SENDER"
RECORD="$WORK/ac8-sent.log"
: > "$RECORD"

# FACTORY_ROOT is the clone whose origin is the bare fixture repo; the healer's
# own default (repo/bin/live-lag.sh) is the script under test. With FACTORY_ROOT
# pointing at the clone, the drain default would name a script the clone does
# not have, so it is pinned to the repo's.
export FACTORY_ROOT="$CLONE" ROLLOUT_PACK_FILE="$PACK" RECORD
export HEALER_NOTICES_DRAIN="$REPO_ROOT/bin/notices-drain.sh"
export NOTICES_DIR="$WORK/ac8-tape/notices"
export HEALER_TEST_NOTIFY_CMD="$SENDER" HEALER_TEST_LIVE_LAG="$TOOL"

export HEALER_TEST_NOW=1000
healer_run_once "$WORK/ac8-healer" "$WORK/ac8-tape" >/dev/null
ac_assert_eq "$(wc -l < "$RECORD" | tr -d ' ')" "0" "AC8 a tick that only starts the clock sends nothing"
jq -e '.since == 1000' "$WORK/ac8-healer/live-lag.json" >/dev/null \
  || ac_fail "AC8 the tick must start the live clock: $(cat "$WORK/ac8-healer/live-lag.json")"

export HEALER_TEST_NOW=87401
healer_run_once "$WORK/ac8-healer" "$WORK/ac8-tape" >/dev/null
ac_assert_eq "$(wc -l < "$RECORD" | tr -d ' ')" "1" "AC8 the lagging tick must send exactly one notice"
case "$(cat "$RECORD")" in
  *"live has not caught up with main for 24 h"*) ;;
  *) ac_fail "AC8 the notice must name the lag: $(cat "$RECORD")" ;;
esac
jq -e '.told == 1' "$WORK/ac8-healer/live-lag.json" >/dev/null \
  || ac_fail "AC8 a sent notice must set told 1"
ac_log "AC8 OK"

ac_pass
