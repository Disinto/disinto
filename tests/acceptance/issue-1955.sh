#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1955.sh
#
# Issue #1955: the healer messages the owner by Telegram only when its own
# fix did not work. Hermetic: shared curl/nomad stubs, a notify stub that
# records its arguments, --once, and HEALER_NOW so the escalate and remind
# windows do not need a real sleep. No network.
#
#   1. A remedy acted and the condition is still there past
#      HEALER_ESCALATE_AFTER_SECS: exactly one message, naming the condition
#      and the restart. Further ticks inside HEALER_REMIND_SECS send nothing.
#      The tick after it sends one reminder.
#   2. unfixable recorded: one message on that tick, without waiting.
#   3. The condition clears: one `resolved` message. A condition that cleared
#      before any message sends none.
#   4. Telegram not configured: the loop goes on, and nothing is lost from
#      the state. A failed send is a WARNING, retried at most once per 10
#      minutes, and does not stop the loop.
#
# Run via: tools/run-acceptance.sh 1955
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"
# shellcheck source=../lib/healer-stubs.sh
source "$REPO_ROOT/tests/lib/healer-stubs.sh"

ac_require_cmd bash jq grep mktemp date

HEALER="$REPO_ROOT/bin/healer.sh"
ac_assert_file "$HEALER" "bin/healer.sh must exist"

# Header is the documentation: when the owner is messaged, and the reminder
# and resolved rules.
grep -qF 'HEALER_ESCALATE_AFTER_SECS:-1800' "$HEALER" \
  || ac_fail "escalate window must default to 1800"
grep -qF 'HEALER_REMIND_SECS:-86400' "$HEALER" \
  || ac_fail "reminder interval must default to 86400"
grep -qF 'HEALER_NOTIFY_CMD:-$FACTORY_ROOT/bin/notify-owner.sh' "$HEALER" \
  || ac_fail "notify command must default to \$FACTORY_ROOT/bin/notify-owner.sh"
grep -qF 'disinto: resolved:' "$HEALER" \
  || ac_fail "header must document the resolved message"
grep -qF 'HEALER_REMIND_SECS' "$HEALER" \
  || ac_fail "header must document the reminder interval"
if grep -qE 'source[[:space:]].*notify-owner' "$HEALER"; then
  ac_fail "healer must run notify-owner, not source it"
fi

ac_healer_init "${TMPDIR:-/tmp}/healer-1955.XXXXXX"

NOTIFY_LOG="$WORK/notify.log"
export NOTIFY_LOG
export NOTIFY_MODE=ok
: > "$NOTIFY_LOG"

cat > "$BIN/notify-owner" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
log="${NOTIFY_LOG:?NOTIFY_LOG unset}"
printf '%s\n' "${1:-}" >> "$log"
case "${NOTIFY_MODE:-ok}" in
  unconfigured)
    printf 'notify-owner: not configured\n' >&2
    exit 0
    ;;
  fail)
    printf 'notify-owner: telegram send failed: stub\n' >&2
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "$BIN/notify-owner"
NOTIFY_CMD="$BIN/notify-owner"
export HEALER_TEST_NOTIFY_CMD="$NOTIFY_CMD"

# forgejo, edge and woodpecker start registered. A scenario rewrites
# services.json when it needs one of them unregistered.
ac_healer_public_fixtures

write_registered() {
  jq -n --argjson names "$1" \
    '[{Namespace:"default",Services:[$names[] | {ServiceName: ., Tags: []}]}]' \
    > "$DATA/services.json"
}

notify_count() {
  if [ ! -s "$NOTIFY_LOG" ]; then
    printf '0'
    return 0
  fi
  grep -c . "$NOTIFY_LOG" || true
}

reset_notify() {
  : > "$NOTIFY_LOG"
  export NOTIFY_MODE=ok
}

# One --once tick. Clock, windows, URLs and the notify command come from
# the HEALER_TEST_* exports; healer_run_once maps them onto the child.
run_once() {
  local state_dir="$1" tape_dir="$2"
  mkdir -p "$state_dir" "$tape_dir"
  [ -f "$STUB_LOG" ] || : > "$STUB_LOG"
  healer_run_once "$state_dir" "$tape_dir"
}

FORGE_URL="https://self.disinto.ai/forge/"
FORGE_COND="public-endpoint-down:${FORGE_URL}"
JOB_COND="service-unregistered:forgejo"

# ── 1. Remedy acted, condition persists past the escalate window ────────────
ac_log "AC1: remedy acted and condition persists past escalate window → one message"
STATE="$WORK/st-1"
TAPE="$WORK/tp-1"
STUB_LOG="$WORK/nm-1.log"
: > "$STUB_LOG"
reset_notify
write_registered '["edge","woodpecker"]'
export HEALER_TEST_PUBLIC_URLS=""
export HEALER_TEST_ESCALATE_AFTER_SECS=100
export HEALER_TEST_REMIND_SECS=50
export HEALER_TEST_COOLDOWN_SECS=999999
export HEALER_TEST_NOW=100000

rc=0
out="$(run_once "$STATE" "$TAPE")" || rc=$?
ac_assert_eq "$rc" "0" "AC1 action tick must exit 0, got $rc: $out"
ac_assert_eq "$(notify_count)" "0" "AC1 no message on the tick the remedy acts"
ac_assert_eq "$(grep -c 'alloc restart alloc-forgejo' "$STUB_LOG" || true)" "1" \
  "AC1 restarts forgejo once: $(cat "$STUB_LOG")"

ac_log "AC1b: still inside the escalate window → no message"
export HEALER_TEST_NOW=100099
rc=0
out="$(run_once "$STATE" "$TAPE")" || rc=$?
ac_assert_eq "$rc" "0" "AC1b must exit 0, got $rc: $out"
ac_assert_eq "$(notify_count)" "0" "AC1b no message before the window elapses"

ac_log "AC1c: window elapsed, condition still there → exactly one message"
export HEALER_TEST_NOW=100100
rc=0
out="$(run_once "$STATE" "$TAPE")" || rc=$?
ac_assert_eq "$rc" "0" "AC1c must exit 0, got $rc: $out"
ac_assert_eq "$(notify_count)" "1" "AC1c exactly one message, got: $(cat "$NOTIFY_LOG")"
msg="$(head -n 1 "$NOTIFY_LOG")"
case "$msg" in
  *"$JOB_COND"*) ;;
  *) ac_fail "AC1c message must name ${JOB_COND}, got: $msg" ;;
esac
case "$msg" in
  *"Restarted forgejo"*) ;;
  *) ac_fail "AC1c message must name the restart, got: $msg" ;;
esac
case "$msg" in
  *reminder:*) ac_fail "AC1c first message must not be a reminder: $msg" ;;
esac
printf '%s\n' "$out" | grep -q "notified owner: ${JOB_COND}" \
  || ac_fail "AC1c must log the notify, got: $out"

ac_log "AC1d: further ticks inside the remind window → no second message"
export HEALER_TEST_NOW=100149
rc=0
out="$(run_once "$STATE" "$TAPE")" || rc=$?
ac_assert_eq "$rc" "0" "AC1d must exit 0, got $rc: $out"
ac_assert_eq "$(notify_count)" "1" "AC1d no reminder inside the window, got: $(cat "$NOTIFY_LOG")"

ac_log "AC1e: remind window elapsed → one reminder"
export HEALER_TEST_NOW=100150
rc=0
out="$(run_once "$STATE" "$TAPE")" || rc=$?
ac_assert_eq "$rc" "0" "AC1e must exit 0, got $rc: $out"
ac_assert_eq "$(notify_count)" "2" "AC1e one reminder, got: $(cat "$NOTIFY_LOG")"
rem="$(tail -n 1 "$NOTIFY_LOG")"
case "$rem" in
  "disinto: reminder: ${JOB_COND} "*) ;;
  *) ac_fail "AC1e reminder must name the condition, got: $rem" ;;
esac
case "$rem" in
  *"Restarted forgejo"*) ;;
  *) ac_fail "AC1e reminder must name the restart, got: $rem" ;;
esac

# ── 2. unfixable is messaged on that tick, without waiting ──────────────────
ac_log "AC2: unfixable recorded → one message on that tick, no wait"
STATE="$WORK/st-2"
TAPE="$WORK/tp-2"
STUB_LOG="$WORK/nm-2.log"
: > "$STUB_LOG"
reset_notify
write_registered '["forgejo","woodpecker","edge"]'
export HEALER_TEST_PUBLIC_URLS="$FORGE_URL"
export HEALER_TEST_ESCALATE_AFTER_SECS=1800
export HEALER_TEST_REMIND_SECS=86400
export HEALER_TEST_COOLDOWN_SECS=1800
export HEALER_TEST_NOW=200000
set_probe_code forge 502
set_probe_code forgejo 200
clear_probe_code ci
clear_probe_code woodpecker

i=0
while [ "$i" -lt 3 ]; do
  i=$((i + 1))
  rc=0
  out="$(run_once "$STATE" "$TAPE")" || rc=$?
  ac_assert_eq "$rc" "0" "AC2 tick ${i} must exit 0, got $rc: $out"
done
ac_assert_eq "$(notify_count)" "0" "AC2 no message before unfixable, got: $(cat "$NOTIFY_LOG")"
if jq -e --arg u "$FORGE_URL" '(.unfixable // {}) | has($u)' "$STATE/state.json" >/dev/null 2>&1; then
  ac_fail "AC2 unfixable must not be recorded before the cooldown tick"
fi

rc=0
out="$(run_once "$STATE" "$TAPE")" || rc=$?
ac_assert_eq "$rc" "0" "AC2 unfixable tick must exit 0, got $rc: $out"
ac_assert_eq "$(notify_count)" "1" "AC2 exactly one message on the unfixable tick, got: $(cat "$NOTIFY_LOG")"
jq -e --arg u "$FORGE_URL" '(.unfixable // {}) | has($u)' "$STATE/state.json" >/dev/null \
  || ac_fail "AC2 state must record unfixable, got: $(cat "$STATE/state.json")"
msg="$(head -n 1 "$NOTIFY_LOG")"
case "$msg" in
  *"$FORGE_COND"*) ;;
  *) ac_fail "AC2 message must name ${FORGE_COND}, got: $msg" ;;
esac
case "$msg" in
  *"Restarted edge"*) ;;
  *) ac_fail "AC2 message must name the edge restart, got: $msg" ;;
esac
case "$msg" in
  *cloudflared*) ;;
  *) ac_fail "AC2 message must name the step the healer cannot take, got: $msg" ;;
esac
case "$msg" in
  *"forgejo healthy"*) ;;
  *) ac_fail "AC2 message must say the backend is healthy, got: $msg" ;;
esac

ac_log "AC2b: a later tick inside the remind window does not send again"
rc=0
out="$(run_once "$STATE" "$TAPE")" || rc=$?
ac_assert_eq "$rc" "0" "AC2b must exit 0, got $rc: $out"
ac_assert_eq "$(notify_count)" "1" "AC2b no second message, got: $(cat "$NOTIFY_LOG")"

# ── 3. Resolved only if a message was sent ──────────────────────────────────
ac_log "AC3: condition clears after a message → one resolved line"
# The service episode lives in st-1. AC2 reused STATE/TAPE for the endpoint.
STATE="$WORK/st-1"
TAPE="$WORK/tp-1"
export HEALER_TEST_NOW=100160
export HEALER_TEST_PUBLIC_URLS=""
write_registered '["forgejo","edge","woodpecker"]'
before="$(notify_count)"
rc=0
out="$(run_once "$STATE" "$TAPE")" || rc=$?
ac_assert_eq "$rc" "0" "AC3 must exit 0, got $rc: $out"
ac_assert_eq "$(notify_count)" "$((before + 1))" "AC3 one resolved message, got: $(cat "$NOTIFY_LOG")"
res="$(tail -n 1 "$NOTIFY_LOG")"
printf '%s\n' "$res" | grep -Eq \
  '^disinto: resolved: service-unregistered:forgejo \(down [0-9dhms]+\)$' \
  || ac_fail "AC3 resolved line mismatch: $res"
if jq -e --arg c "$JOB_COND" '.episodes[$c]' "$STATE/state.json" >/dev/null 2>&1; then
  ac_fail "AC3 episode must be dropped after resolved, got: $(cat "$STATE/state.json")"
fi

ac_log "AC3b: a condition that clears before any message sends none"
STATE="$WORK/st-3"
TAPE="$WORK/tp-3"
STUB_LOG="$WORK/nm-3.log"
: > "$STUB_LOG"
reset_notify
write_registered '["edge","woodpecker"]'
export HEALER_TEST_PUBLIC_URLS=""
export HEALER_TEST_ESCALATE_AFTER_SECS=100
export HEALER_TEST_COOLDOWN_SECS=999999
export HEALER_TEST_NOW=300000
rc=0
out="$(run_once "$STATE" "$TAPE")" || rc=$?
ac_assert_eq "$rc" "0" "AC3b action tick must exit 0, got $rc: $out"
ac_assert_eq "$(notify_count)" "0" "AC3b no message before the window"
write_registered '["forgejo","edge","woodpecker"]'
export HEALER_TEST_NOW=300010
rc=0
out="$(run_once "$STATE" "$TAPE")" || rc=$?
ac_assert_eq "$rc" "0" "AC3b clear tick must exit 0, got $rc: $out"
ac_assert_eq "$(notify_count)" "0" "AC3b a clear before any message sends none, got: $(cat "$NOTIFY_LOG")"

# ── 4. Not configured: loop continues, state is kept ────────────────────────
ac_log "AC4: telegram not configured → loop continues, state is kept"
STATE="$WORK/st-4"
TAPE="$WORK/tp-4"
STUB_LOG="$WORK/nm-4.log"
: > "$STUB_LOG"
reset_notify
export NOTIFY_MODE=unconfigured
write_registered '["forgejo","woodpecker","edge"]'
export HEALER_TEST_PUBLIC_URLS="$FORGE_URL"
export HEALER_TEST_ESCALATE_AFTER_SECS=1800
export HEALER_TEST_REMIND_SECS=86400
export HEALER_TEST_COOLDOWN_SECS=1800
export HEALER_TEST_NOW=400000
set_probe_code forge 502
set_probe_code forgejo 200

i=0
while [ "$i" -lt 4 ]; do
  i=$((i + 1))
  rc=0
  out="$(run_once "$STATE" "$TAPE")" || rc=$?
  ac_assert_eq "$rc" "0" "AC4 tick ${i} must exit 0 even when not configured, got $rc: $out"
done
ac_assert_eq "$(notify_count)" "1" "AC4 attempted the send once, got: $(cat "$NOTIFY_LOG")"
printf '%s\n' "$out" | grep -q 'WARNING: notify: not configured' \
  || ac_fail "AC4 must log not configured, got: $out"
jq -e --arg u "$FORGE_URL" '(.unfixable // {}) | has($u)' "$STATE/state.json" >/dev/null \
  || ac_fail "AC4 unfixable must survive a not-configured send: $(cat "$STATE/state.json")"
jq -e '.cooldown.edge != null' "$STATE/state.json" >/dev/null \
  || ac_fail "AC4 cooldown must survive a not-configured send: $(cat "$STATE/state.json")"
jq -e --arg c "$FORGE_COND" '.episodes[$c].sent == 0' "$STATE/state.json" >/dev/null \
  || ac_fail "AC4 must not mark the episode sent when not configured: $(cat "$STATE/state.json")"
kept_acted="$(jq -r --arg c "$FORGE_COND" '.episodes[$c].acted_at' "$STATE/state.json")"
kept_since="$(jq -r --arg c "$FORGE_COND" '.episodes[$c].since' "$STATE/state.json")"
kept_unf="$(jq -r --arg u "$FORGE_URL" '.unfixable[$u]' "$STATE/state.json")"

ac_log "AC4b: the next tick does not drop what the failed send recorded"
rc=0
out="$(run_once "$STATE" "$TAPE")" || rc=$?
ac_assert_eq "$rc" "0" "AC4b loop must go on, got $rc: $out"
ac_assert_eq "$(notify_count)" "1" "AC4b no retry inside 10 minutes, got: $(cat "$NOTIFY_LOG")"
ac_assert_eq "$(jq -r --arg c "$FORGE_COND" '.episodes[$c].acted_at' "$STATE/state.json")" \
  "$kept_acted" "AC4b acted_at must be unchanged"
ac_assert_eq "$(jq -r --arg c "$FORGE_COND" '.episodes[$c].since' "$STATE/state.json")" \
  "$kept_since" "AC4b since must be unchanged"
ac_assert_eq "$(jq -r --arg u "$FORGE_URL" '.unfixable[$u]' "$STATE/state.json")" \
  "$kept_unf" "AC4b unfixable epoch must be unchanged"
jq -e --arg c "$FORGE_COND" '.episodes[$c].sent == 0' "$STATE/state.json" >/dev/null \
  || ac_fail "AC4b episode must still be unsent"

ac_log "AC4c: once the channel works, the kept episode is still sent"
export NOTIFY_MODE=ok
export HEALER_TEST_NOW=400600
rc=0
out="$(run_once "$STATE" "$TAPE")" || rc=$?
ac_assert_eq "$rc" "0" "AC4c must exit 0, got $rc: $out"
ac_assert_eq "$(notify_count)" "2" "AC4c the kept escalation is sent, got: $(cat "$NOTIFY_LOG")"
jq -e --arg c "$FORGE_COND" '.episodes[$c].sent == 1' "$STATE/state.json" >/dev/null \
  || ac_fail "AC4c episode must record the send: $(cat "$STATE/state.json")"

# ── 5. A failed send is a WARNING and is retried after 10 minutes ───────────
ac_log "AC5: failed send logs WARNING, retries after 10 minutes, loop continues"
STATE="$WORK/st-5"
TAPE="$WORK/tp-5"
STUB_LOG="$WORK/nm-5.log"
: > "$STUB_LOG"
reset_notify
export NOTIFY_MODE=fail
write_registered '["edge","woodpecker"]'
export HEALER_TEST_PUBLIC_URLS=""
export HEALER_TEST_ESCALATE_AFTER_SECS=100
export HEALER_TEST_REMIND_SECS=86400
export HEALER_TEST_COOLDOWN_SECS=999999
export HEALER_TEST_NOW=500000
rc=0
out="$(run_once "$STATE" "$TAPE")" || rc=$?
ac_assert_eq "$rc" "0" "AC5 action tick must exit 0, got $rc: $out"
export HEALER_TEST_NOW=500100
rc=0
out="$(run_once "$STATE" "$TAPE")" || rc=$?
ac_assert_eq "$rc" "0" "AC5 failed send must not stop the loop, got $rc: $out"
ac_assert_eq "$(notify_count)" "1" "AC5 one attempt, got: $(cat "$NOTIFY_LOG")"
printf '%s\n' "$out" | grep -q 'WARNING: notify failed' \
  || ac_fail "AC5 must log WARNING for a failed send, got: $out"
jq -e --arg c "$JOB_COND" '.episodes[$c].sent == 0' "$STATE/state.json" >/dev/null \
  || ac_fail "AC5 must keep the episode unsent: $(cat "$STATE/state.json")"

export HEALER_TEST_NOW=500699
rc=0
out="$(run_once "$STATE" "$TAPE")" || rc=$?
ac_assert_eq "$rc" "0" "AC5b must exit 0, got $rc: $out"
ac_assert_eq "$(notify_count)" "1" "AC5b no retry before 10 minutes, got: $(cat "$NOTIFY_LOG")"

export HEALER_TEST_NOW=500700
rc=0
out="$(run_once "$STATE" "$TAPE")" || rc=$?
ac_assert_eq "$rc" "0" "AC5c retry tick must exit 0, got $rc: $out"
ac_assert_eq "$(notify_count)" "2" "AC5c retries once the 10 minutes have passed, got: $(cat "$NOTIFY_LOG")"

ac_pass
