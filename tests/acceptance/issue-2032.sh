#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2032.sh — the healer sends the owner-notice queue
#
# Issue #2032: lib/notice.sh (#2031) queues owner messages as files under
# ${TAPE_DIR}/notices/; bin/notices-drain.sh (host-side, like
# bin/notify-owner.sh) drains that queue and bin/healer.sh's tick calls it
# right after the escalate pass. AD-006: only the healer sends.
#
# Contract under test (bin/notices-drain.sh DIR):
#   * DIR missing: rc 0, nothing printed, nothing created.
#   * The plain *.txt files directly in DIR, oldest name first (sort), at
#     most ${NOTICES_MAX_PER_TICK:-5} per run, each sent as
#     "${HEALER_NOTIFY_CMD:?}" "$(cat "$file")" with stderr captured.
#   * rc 0 + stderr without "not configured": file moved to DIR/sent.
#   * rc 0 + stderr with "not configured": nothing moves, stderr says
#     "notices-drain: not configured (<count> waiting)", rc 0.
#   * any other rc: file stays, nothing else attempted, stderr says
#     "notices-drain: send failed (exit <rc>)", rc 1.
#   * Never prints a file's text or the sender's stderr beyond its first line.
#
# Hermetic: a temp DIR and a fake HEALER_NOTIFY_CMD that appends its argument
# to a log and behaves per $FAKE_MODE (ok | unconfigured | fail). No network,
# no live services.
#
# Acceptance:
#   AC1: 1-a.txt 2-b.txt 3-c.txt -> all three sent in that order, all moved
#        to DIR/sent/, rc 0.
#   AC2: seven files with NOTICES_MAX_PER_TICK=5 -> five sent, two left.
#   AC3: sender prints "notify-owner: not configured", rc 0 -> no file moves,
#        rc 0, stderr names "2 waiting".
#   AC4: sender exits 1 -> first file stays, nothing else attempted, rc 1.
#   AC5: DIR absent -> rc 0, nothing created.
#   AC6: bin/healer.sh has the drain call after the escalate_pass line;
#        bash -n passes on bin/notices-drain.sh and bin/healer.sh.
#
# Run via: tools/run-acceptance.sh 2032
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash find sort mktemp

ac_assert_file "$REPO_ROOT/bin/notices-drain.sh" "bin/notices-drain.sh is missing"
ac_assert_file "$REPO_ROOT/bin/healer.sh" "bin/healer.sh is missing"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# make_fake — write the fake sender into $TMP_DIR/fake. It appends its
# argument to $TMP_DIR/sent.log and behaves per FAKE_MODE:
#   ok          -> exit 0
#   unconfigured-> print "notify-owner: not configured" to stderr, exit 0
#   fail        -> exit 1
make_fake() {
  cat > "$TMP_DIR/fake" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
mode="${FAKE_MODE:-ok}"
printf '%s\n' "${1:-}" >> "$FAKE_LOG"
case "$mode" in
  ok) exit 0 ;;
  unconfigured) printf 'notify-owner: not configured\n' >&2; exit 0 ;;
  fail) exit 1 ;;
  *) printf 'fake: unknown mode %s\n' "$mode" >&2; exit 2 ;;
esac
FAKE
  chmod +x "$TMP_DIR/fake"
}
make_fake

# run_drain <dir> [max] [mode] — run notices-drain.sh against <dir> with the
# fake sender in <mode> (ok | unconfigured | fail). stdout -> $OUT,
# stderr -> $ERR, exit status -> $RC.
run_drain() {
  local dir="$1" max="${2:-}" mode="${3:-ok}"
  RC=0
  OUT=""
  ERR=""
  (
    HEALER_NOTIFY_CMD="$TMP_DIR/fake" FAKE_LOG="$TMP_DIR/sent.log" \
      FAKE_MODE="$mode" NOTICES_MAX_PER_TICK="${max:-5}" \
      "$REPO_ROOT/bin/notices-drain.sh" "$dir"
  ) >"$TMP_DIR/out" 2>"$TMP_DIR/err" || RC=$?
  OUT="$(cat "$TMP_DIR/out" 2>/dev/null)"
  ERR="$(cat "$TMP_DIR/err" 2>/dev/null)"
}

# seed <dir> <names...> — create "$name".txt in dir, content "text-<name>".
seed() {
  local dir="$1" name
  shift
  for name in "$@"; do
    printf 'text-%s' "$name" > "$dir/$name"
  done
}

# txt_count <dir> — number of *.txt files directly in dir.
txt_count() {
  find "$1" -maxdepth 1 -name '*.txt' 2>/dev/null | wc -l | tr -d ' '
}

# sent_count <dir> — number of files in dir/sent (0 when the dir is absent).
sent_count() {
  find "$1/sent" -maxdepth 1 -name '*.txt' 2>/dev/null | wc -l | tr -d ' '
}

# ── AC1: three files, all sent in name order, all moved to DIR/sent ────────
ac_log "AC1: three notices are drained oldest-name-first into DIR/sent"
DIR="$TMP_DIR/queue1"
mkdir -p "$DIR"
: > "$TMP_DIR/sent.log"
seed "$DIR" 1-a.txt 2-b.txt 3-c.txt
run_drain "$DIR"
[ "$RC" -eq 0 ] || ac_fail "AC1: drain must exit 0, got $RC"
[ -z "$OUT" ] || ac_fail "AC1: drain must print nothing to stdout"
[ -z "$ERR" ] || ac_fail "AC1: a healthy drain must print nothing to stderr"
[ "$(txt_count "$DIR")" -eq 0 ] || ac_fail "AC1: the queue must be empty after a successful drain"
[ "$(sent_count "$DIR")" -eq 3 ] || ac_fail "AC1: DIR/sent must hold all three notices"
if [ "$(cat "$TMP_DIR/sent.log")" != "$(printf 'text-1-a.txt\ntext-2-b.txt\ntext-3-c.txt')" ]; then
  ac_fail "AC1: notices must be sent in oldest-name order (1-a, 2-b, 3-c)"
fi

# ── AC2: seven files, NOTICES_MAX_PER_TICK=5 — five sent, two left ──────────
ac_log "AC2: the per-tick cap sends the first five and leaves the rest"
DIR="$TMP_DIR/queue2"
mkdir -p "$DIR"
: > "$TMP_DIR/sent.log"
seed "$DIR" 1.txt 2.txt 3.txt 4.txt 5.txt 6.txt 7.txt
run_drain "$DIR" 5
[ "$RC" -eq 0 ] || ac_fail "AC2: drain must exit 0, got $RC"
[ "$(wc -l < "$TMP_DIR/sent.log" | tr -d ' ')" -eq 5 ] || ac_fail "AC2: exactly five notices must be sent per tick"
[ "$(txt_count "$DIR")" -eq 2 ] || ac_fail "AC2: the two newest notices must wait for the next tick"
if [ "$(cat "$TMP_DIR/sent.log")" != "$(printf 'text-1.txt\ntext-2.txt\ntext-3.txt\ntext-4.txt\ntext-5.txt')" ]; then
  ac_fail "AC2: the five oldest notices must be the ones sent"
fi

# ── AC3: sender "not configured" — nothing moves, rc 0, stderr names 2 ──────
ac_log "AC3: an unconfigured sender leaves the queue in place and reports it"
DIR="$TMP_DIR/queue3"
mkdir -p "$DIR"
: > "$TMP_DIR/sent.log"
seed "$DIR" 1-a.txt 2-b.txt
run_drain "$DIR" 5 unconfigured
[ "$RC" -eq 0 ] || ac_fail "AC3: a missing channel must not fail the drain (rc $RC)"
[ -z "$OUT" ] || ac_fail "AC3: the drain must print nothing to stdout"
[ "$(txt_count "$DIR")" -eq 2 ] || ac_fail "AC3: not configured must leave every notice in DIR"
[ "$(sent_count "$DIR")" -eq 0 ] || ac_fail "AC3: nothing may reach DIR/sent when nothing was sent"
printf '%s\n' "$ERR" | grep -q 'notices-drain: not configured (2 waiting)' \
  || ac_fail "AC3: stderr must say 'notices-drain: not configured (2 waiting)'"

# ── AC4: sender exits 1 — first file stays, nothing else attempted, rc 1 ────
ac_log "AC4: a failed send stops the tick with rc 1"
DIR="$TMP_DIR/queue4"
mkdir -p "$DIR"
: > "$TMP_DIR/sent.log"
seed "$DIR" 1-a.txt 2-b.txt 3-c.txt
run_drain "$DIR" 5 fail
[ "$RC" -eq 1 ] || ac_fail "AC4: a send failure must exit 1, got $RC"
[ -z "$OUT" ] || ac_fail "AC4: the drain must never print notice text to stdout"
[ "$(txt_count "$DIR")" -eq 3 ] || ac_fail "AC4: a failed send must leave every notice in DIR"
[ "$(wc -l < "$TMP_DIR/sent.log" | tr -d ' ')" -eq 1 ] \
  || ac_fail "AC4: the drain must stop after the first failed send"
printf '%s\n' "$ERR" | grep -q 'notices-drain: send failed (exit 1)' \
  || ac_fail "AC4: stderr must say 'notices-drain: send failed (exit 1)'"

# ── AC5: DIR absent — rc 0, nothing created ─────────────────────────────────
ac_log "AC5: a missing notices dir exits 0 and creates nothing"
run_drain "$TMP_DIR/absent-dir"
[ "$RC" -eq 0 ] || ac_fail "AC5: a missing DIR must exit 0, got $RC"
[ -z "$OUT" ] || ac_fail "AC5: a missing DIR must print nothing"
[ -z "$ERR" ] || ac_fail "AC5: a missing DIR must print nothing to stderr"
[ -e "$TMP_DIR/absent-dir" ] && ac_fail "AC5: the drain must not create the notices dir"

# ── AC6: healer wiring + syntax ─────────────────────────────────────────────
ac_log "AC6: healer_tick calls the drain right after the escalate pass"
esc_line="$(grep -n 'escalate_pass "[$]now" || log "WARNING: escalate pass failed"' "$REPO_ROOT/bin/healer.sh" | head -n 1 | cut -d: -f1)"
drain_line="$(grep -n 'notices-drain.sh' "$REPO_ROOT/bin/healer.sh" | head -n 1 | cut -d: -f1)"
[ -n "$esc_line" ] || ac_fail "AC6: bin/healer.sh must still call escalate_pass in the tick"
[ -n "$drain_line" ] || ac_fail "AC6: bin/healer.sh must call bin/notices-drain.sh in the tick"
[ "$drain_line" -gt "$esc_line" ] \
  || ac_fail "AC6: the drain line ($drain_line) must come after the escalate_pass line ($esc_line)"
grep -q 'HEALER_NOTICES_DRAIN:-[$]FACTORY_ROOT/bin/notices-drain.sh' "$REPO_ROOT/bin/healer.sh" \
  || ac_fail "AC6: the drain must default to FACTORY_ROOT/bin/notices-drain.sh"
grep -q '[$]{TAPE_DIR:-/srv/disinto/tape}/notices' "$REPO_ROOT/bin/healer.sh" \
  || ac_fail "AC6: the drain must read the notices dir under the tape volume"

bash -n "$REPO_ROOT/bin/notices-drain.sh" || ac_fail "AC6: bin/notices-drain.sh has a syntax error"
bash -n "$REPO_ROOT/bin/healer.sh" || ac_fail "AC6: bin/healer.sh has a syntax error"

ac_pass
