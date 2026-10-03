#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1673.sh
#
# Issue #1673: run a probe and read its number.
#
# Sprint effects and claim checks both run a probe from the ops repo and read
# one number from it. lib/probe.sh is the shared runner (no callers yet):
#
#   probe_value PATH
#     PATH must start with probes/ and hold no `..`; otherwise return 2
#     without running anything.
#     Run: timeout "${PROBE_TIMEOUT_S:-300}" bash "${OPS_REPO_ROOT}/PATH"
#     Exit 0 and a last stdout line that is a number (integer or decimal,
#     may be negative): print that number, return 0.
#     Anything else: print nothing on stdout, one reason line on stderr,
#     return 1.
#
# Hermetic: no network, no forge, no agent. Fixture probes live in a temp
# OPS_REPO_ROOT. The lib is sourced in a throwaway subshell (same pattern as
# issue-1629.sh).
#
# Acceptance: `bash tests/acceptance/issue-1673.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash timeout date
ac_assert_file "$REPO_ROOT/lib/probe.sh" "lib/probe.sh is missing"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

OPS_REPO_ROOT="$TMP_DIR/ops"
export OPS_REPO_ROOT
mkdir -p "$OPS_REPO_ROOT/probes" "$OPS_REPO_ROOT/other"

# A script that records that it ran. Bad-path calls must not create this.
RAN="$TMP_DIR/ran"
write_ran_probe() {
  local dest="$1"
  mkdir -p "$(dirname "$dest")"
  cat >"$dest" <<EOF
#!/usr/bin/env bash
echo ran > "$RAN"
echo 9
EOF
  chmod a-x "$dest"
}

# run_probe <path> — source lib/probe.sh in a throwaway subshell and call
# probe_value. stdout -> $OUT, stderr -> $ERR, exit status -> $RC.
# PROBE_TIMEOUT_S, when set in the parent, is inherited.
run_probe() {
  local path="$1"
  RC=0
  OUT=""
  ERR=""
  (
    # shellcheck disable=SC1091
    source "$REPO_ROOT/lib/probe.sh"
    probe_value "$path"
  ) >"$TMP_DIR/out" 2>"$TMP_DIR/err" || RC=$?
  OUT="$(cat "$TMP_DIR/out" 2>/dev/null || true)"
  ERR="$(cat "$TMP_DIR/err" 2>/dev/null || true)"
}

# stderr_lines — number of lines on the captured stderr (0 when empty).
stderr_lines() {
  if [ -z "$ERR" ]; then
    printf '0'
  else
    printf '%s\n' "$ERR" | wc -l | tr -d '[:space:]'
  fi
}

# ── AC1: last stdout line is the number; a negative decimal passes through ──
ac_log "AC1: a probe printing x then 5 prints 5; -0.25 prints -0.25"
cat >"$OPS_REPO_ROOT/probes/five.sh" <<'EOF'
#!/usr/bin/env bash
echo x
echo 5
EOF
chmod a-x "$OPS_REPO_ROOT/probes/five.sh"
run_probe "probes/five.sh"
ac_assert_eq "$OUT" "5" \
  "probe printing x then 5 must print 5 (got '$OUT') [stderr: $ERR]"
ac_assert_eq "$RC" "0" "probe printing 5 must return 0 (rc=$RC)"
[ -z "$ERR" ] || ac_fail "successful probe must not print stderr (got: $ERR)"
# The runner prints only the number, not the probe's earlier stdout.
ac_assert_eq "$(wc -l <"$TMP_DIR/out" | tr -d '[:space:]')" "1" \
  "successful probe must print exactly one stdout line"

cat >"$OPS_REPO_ROOT/probes/neg.sh" <<'EOF'
#!/usr/bin/env bash
echo -0.25
EOF
chmod a-x "$OPS_REPO_ROOT/probes/neg.sh"
run_probe "probes/neg.sh"
ac_assert_eq "$OUT" "-0.25" \
  "probe printing -0.25 must print -0.25 (got '$OUT') [stderr: $ERR]"
ac_assert_eq "$RC" "0" "probe printing -0.25 must return 0 (rc=$RC)"

# ── AC2: non-zero exit, or a non-number, returns 1 and prints nothing ────────
ac_log "AC2: exit 1 or a non-number returns 1 and prints nothing on stdout"
cat >"$OPS_REPO_ROOT/probes/fail.sh" <<'EOF'
#!/usr/bin/env bash
echo 5
echo secret-stderr >&2
exit 1
EOF
run_probe "probes/fail.sh"
ac_assert_eq "$RC" "1" "probe exiting 1 must return 1 (rc=$RC)"
ac_assert_eq "$OUT" "" \
  "probe exiting 1 must print nothing on stdout (got '$OUT')"
ac_assert_eq "$(stderr_lines)" "1" \
  "probe exiting 1 must print one stderr reason line (got: $ERR)"
case "$ERR" in
  *secret-stderr*) ac_fail "probe stderr must not leak (got: $ERR)" ;;
esac

cat >"$OPS_REPO_ROOT/probes/abc.sh" <<'EOF'
#!/usr/bin/env bash
echo abc
EOF
run_probe "probes/abc.sh"
ac_assert_eq "$RC" "1" "probe printing abc must return 1 (rc=$RC)"
ac_assert_eq "$OUT" "" \
  "probe printing abc must print nothing on stdout (got '$OUT')"
ac_assert_eq "$(stderr_lines)" "1" \
  "probe printing abc must print one stderr reason line (got: $ERR)"

# ── AC3: a path that escapes probes/ returns 2 and the probe does not run ───
ac_log "AC3: ../x.sh and other/x.sh return 2 and the probe does not run"
write_ran_probe "$TMP_DIR/x.sh"
write_ran_probe "$OPS_REPO_ROOT/other/x.sh"
write_ran_probe "$OPS_REPO_ROOT/probes/decoy.sh"
rm -f "$RAN"

run_probe "../x.sh"
ac_assert_eq "$RC" "2" "../x.sh must return 2 (rc=$RC) [stderr: $ERR]"
ac_assert_eq "$OUT" "" "../x.sh must print nothing on stdout (got '$OUT')"
[ ! -e "$RAN" ] || ac_fail "../x.sh ran the probe (marker: $(cat "$RAN"))"

rm -f "$RAN"
run_probe "other/x.sh"
ac_assert_eq "$RC" "2" "other/x.sh must return 2 (rc=$RC) [stderr: $ERR]"
ac_assert_eq "$OUT" "" "other/x.sh must print nothing on stdout (got '$OUT')"
[ ! -e "$RAN" ] || ac_fail "other/x.sh ran the probe (marker: $(cat "$RAN"))"

# `..` inside an otherwise probes/ path is the same rule, and would run
# $TMP_DIR/x.sh if the runner only joined the path.
rm -f "$RAN"
run_probe "probes/../../x.sh"
ac_assert_eq "$RC" "2" "probes/../../x.sh must return 2 (rc=$RC)"
[ ! -e "$RAN" ] || ac_fail "probes/../../x.sh ran the probe"

# ── AC4: a probe that sleeps past PROBE_TIMEOUT_S returns 1 ─────────────────
ac_log "AC4: PROBE_TIMEOUT_S=1 with a probe sleeping 5s returns 1"
cat >"$OPS_REPO_ROOT/probes/slow.sh" <<EOF
#!/usr/bin/env bash
echo ran > "$RAN"
sleep 5
echo done > "$RAN"
echo 1
EOF
rm -f "$RAN"
start_ts="$(date -u +%s)"
PROBE_TIMEOUT_S=1
export PROBE_TIMEOUT_S
run_probe "probes/slow.sh"
elapsed="$(( $(date -u +%s) - start_ts ))"
unset PROBE_TIMEOUT_S
ac_assert_eq "$RC" "1" \
  "timed-out probe must return 1 (rc=$RC, elapsed=${elapsed}s) [stderr: $ERR]"
ac_assert_eq "$OUT" "" \
  "timed-out probe must print nothing on stdout (got '$OUT')"
ac_assert_eq "$(stderr_lines)" "1" \
  "timed-out probe must print one stderr reason line (got: $ERR)"
[ -e "$RAN" ] || ac_fail "timed-out probe never started"
ac_assert_eq "$(cat "$RAN")" "ran" \
  "timed-out probe must not have finished (marker: $(cat "$RAN"))"
# sleep 5 must not complete; 1s of timeout plus scheduling slack stays under 4.
if [ "$elapsed" -ge 4 ]; then
  ac_fail "probe was not stopped at PROBE_TIMEOUT_S=1 (elapsed=${elapsed}s)"
fi

ac_pass "issue #1673: run a probe and read its number"
