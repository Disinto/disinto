#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2053.sh
#
# Issue #2053: a direct remedy stops after 10 of its last 20 tries failed.
#
#   1. repair_suspended boom with 12 outcomes, 10 failed, the last failed,
#      newest proposal 1 h old: prints "10 12" and returns 0.
#   2. The last outcome cleared: rc 1. 9 failed of 12: rc 1. {"acted":0} is
#      counted but not failed. An outcome of another class is not counted.
#      {"regression_cleared":0} (no acted) is failed.
#   3. Suspended, newest proposal 8 days old: rc 2 (trial due). With
#      trial_days = 0: rc 0.
#   4. Pack missing, or suspend_at = ten: rc 1, nothing printed. No tape: rc 1.
#   5. repair_direct_dispatch (extracted, marker-writing script): a 0 from
#      repair_suspended skips the script and logs "suspended: boom-recipe (10
#      of last 12 tries failed)"; a 2 runs it and logs "trial: boom-recipe";
#      a 1 runs it and logs neither. Both files pass bash -n.
#
# Hermetic: no network. A temp TAPE_DIR with a hand-written tape.jsonl, a
# temp REPAIR_PACK_FILE, and SUPERVISOR_NOW fixed.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd jq awk date

LIB="$REPO_ROOT/lib/repair-suspend.sh"
TARGET="$REPO_ROOT/supervisor/supervisor-run.sh"
ac_assert_file "$LIB" "lib/repair-suspend.sh must exist"
ac_assert_file "$TARGET" "supervisor/supervisor-run.sh must exist"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Fixed clock and pack shared by every fixture.
NOW="$(date -u -d '2026-10-07T00:00:00Z' +%s)"
PACK="$TMP_DIR/repair.toml"
cat > "$PACK" <<'EOF'
window = 20
suspend_at = 10
trial_days = 7
EOF

# write_boom_tape DIR NEWEST_PROPOSAL_T [mode]
# Two boom proposals (the newest at NEWEST_PROPOSAL_T), 12 boom outcomes in
# tape order — 10 failed by default — plus two outcomes of another class and
# a torn final line. mode=cleared makes the last outcome cleared; mode=nine
# adds an extra cleared outcome, leaving 9 failed.
write_boom_tape() {
  local dir="$1" newest="$2" mode="${3:-base}" i
  {
    printf '{"type":"proposal","t":"2026-09-28T00:00:00Z","id":"p1","loop":"repair","class":"boom","context":{},"decision":"approve","ref":"r1"}\n'
    printf '{"type":"proposal","t":"%s","id":"p2","loop":"repair","class":"boom","context":{},"decision":"approve","ref":"r2"}\n' "$newest"
    printf '{"type":"proposal","t":"2026-10-04T00:00:00Z","id":"p9","loop":"repair","class":"noise","context":{},"decision":"approve","ref":"r9"}\n'
    for i in 1 2 3 4 5 6 7 8 9; do
      if [ "$mode" = "nine" ] && [ "$i" = 9 ]; then
        printf '{"type":"outcome","t":"2026-10-03T01:%02d:00Z","proposal_id":"p1","bits":{"acted":1,"cleared":1}}\n' "$i"
      else
        printf '{"type":"outcome","t":"2026-10-03T01:%02d:00Z","proposal_id":"p1","bits":{"acted":1,"cleared":0}}\n' "$i"
      fi
    done
    printf '{"type":"outcome","t":"2026-10-03T02:11:00Z","proposal_id":"p1","bits":{"acted":1,"cleared":1}}\n'
    printf '{"type":"outcome","t":"2026-10-03T02:12:00Z","proposal_id":"p1","bits":{"acted":0,"cleared":0}}\n'
    if [ "$mode" = "cleared" ]; then
      printf '{"type":"outcome","t":"2026-10-03T02:13:00Z","proposal_id":"p2","bits":{"acted":1,"cleared":1}}\n'
    else
      printf '{"type":"outcome","t":"2026-10-03T02:13:00Z","proposal_id":"p2","bits":{"acted":1,"cleared":0}}\n'
    fi
    printf '{"type":"outcome","t":"2026-10-03T02:14:00Z","proposal_id":"p9","bits":{"acted":1,"cleared":0}}\n'
    printf '{"type":"outcome","t":"2026-10-03T02:15:00Z","proposal_id":"p9","bits":{"acted":1,"cleared":0}}\n'
    printf '{"type":"outcome","t":"2026-10-03T02:16:00Z","proposal_id":"p1"\n'
  } > "$dir/tape.jsonl"
}

# run_suspended TAPE_DIR PACK — call repair_suspended boom in a fresh shell;
# stdout into OUT, exit status into RC.
run_suspended() {
  local dir="$1" pack="$2"
  RC=0
  OUT=""
  OUT="$(REPAIR_LIB="$LIB" TAPE_DIR="$dir" REPAIR_PACK_FILE="$pack" SUPERVISOR_NOW="$NOW" bash -c '
    # shellcheck disable=SC1091
    source "$REPAIR_LIB"
    repair_suspended boom
  ' 2>/dev/null)" || RC=$?
}

# ── AC 1: 10 failed of 12, the last failed, proposal 1 h old → "10 12", rc 0 ─
ac_log "AC 1: suspended (10 of last 12 failed) prints '10 12' and returns 0"
mkdir -p "$TMP_DIR/tape1"
write_boom_tape "$TMP_DIR/tape1" "2026-10-06T23:00:00Z"
run_suspended "$TMP_DIR/tape1" "$PACK"
ac_assert_eq "$RC" "0" "suspended must return 0 (got $RC): $OUT"
ac_assert_eq "$OUT" "10 12" "expected counts '10 12', got '$OUT'"

# ── AC 2: cleared last, 9 failed, acted:0, other class, regression_cleared ──
ac_log "AC 2: the last one failed is what keeps the suspension"

mkdir -p "$TMP_DIR/tape2a"
write_boom_tape "$TMP_DIR/tape2a" "2026-10-06T23:00:00Z" cleared
run_suspended "$TMP_DIR/tape2a" "$PACK"
ac_assert_eq "$RC" "1" "a cleared last outcome must lift the suspension (got $RC): $OUT"

mkdir -p "$TMP_DIR/tape2b"
write_boom_tape "$TMP_DIR/tape2b" "2026-10-06T23:00:00Z" nine
run_suspended "$TMP_DIR/tape2b" "$PACK"
ac_assert_eq "$RC" "1" "9 failed of 12 must not suspend (got $RC): $OUT"
ac_assert_eq "$OUT" "9 12" "expected counts '9 12', got '$OUT'"

# The base tape already carries one {"acted":0,"cleared":0} outcome: it is
# counted (12) but never failed (10) — AC 1 covered it.

# A pre-#1637 outcome carrying only regression_cleared:0 is failed.
mkdir -p "$TMP_DIR/tape2c"
{
  printf '{"type":"proposal","t":"2026-10-03T00:00:00Z","id":"p1","loop":"repair","class":"boom","context":{},"decision":"approve","ref":"r1"}\n'
  printf '{"type":"proposal","t":"2026-10-06T23:00:00Z","id":"p2","loop":"repair","class":"boom","context":{},"decision":"approve","ref":"r2"}\n'
  for i in 1 2 3 4 5 6 7 8 9; do
    printf '{"type":"outcome","t":"2026-10-03T01:%02d:00Z","proposal_id":"p1","bits":{"acted":1,"cleared":0}}\n' "$i"
  done
  printf '{"type":"outcome","t":"2026-10-03T02:10:00Z","proposal_id":"p2","bits":{"regression_cleared":0}}\n'
} > "$TMP_DIR/tape2c/tape.jsonl"
run_suspended "$TMP_DIR/tape2c" "$PACK"
ac_assert_eq "$RC" "0" "regression_cleared:0 with no acted must count as failed (got $RC): $OUT"
ac_assert_eq "$OUT" "10 10" "expected counts '10 10', got '$OUT'"

# ── AC 3: the trial ──────────────────────────────────────────────────────────
ac_log "AC 3: 8 days since the newest proposal gives the trial (rc 2); trial_days=0 keeps rc 0"
mkdir -p "$TMP_DIR/tape3"
write_boom_tape "$TMP_DIR/tape3" "2026-09-29T00:00:00Z"
run_suspended "$TMP_DIR/tape3" "$PACK"
ac_assert_eq "$RC" "2" "a suspended remedy 8 days past its proposal must get a trial (got $RC): $OUT"
ac_assert_eq "$OUT" "10 12" "expected counts '10 12', got '$OUT'"

cat > "$TMP_DIR/repair-zero.toml" <<'EOF'
window = 20
suspend_at = 10
trial_days = 0
EOF
run_suspended "$TMP_DIR/tape3" "$TMP_DIR/repair-zero.toml"
ac_assert_eq "$RC" "0" "trial_days = 0 means no trial: suspended only (got $RC): $OUT"

# ── AC 4: missing pack, unparsable pack, missing tape ────────────────────────
ac_log "AC 4: no pack, a non-integer suspend_at, or no tape: rc 1 and no output"
run_suspended "$TMP_DIR/tape1" "$TMP_DIR/no-such-pack.toml"
ac_assert_eq "$RC" "1" "a missing pack must return 1 (got $RC)"
ac_assert_eq "$OUT" "" "a missing pack must print nothing, got: $OUT"

cat > "$TMP_DIR/repair-bad.toml" <<'EOF'
window = 20
suspend_at = ten
trial_days = 7
EOF
run_suspended "$TMP_DIR/tape1" "$TMP_DIR/repair-bad.toml"
ac_assert_eq "$RC" "1" "a non-integer suspend_at must return 1 (got $RC)"
ac_assert_eq "$OUT" "" "an unparsable pack must print nothing, got: $OUT"

mkdir -p "$TMP_DIR/tape-empty"
run_suspended "$TMP_DIR/tape-empty" "$PACK"
ac_assert_eq "$RC" "1" "a missing tape.jsonl must return 1 (got $RC)"
ac_assert_eq "$OUT" "" "no tape must print nothing, got: $OUT"

# ── AC 5: the dispatch hook ──────────────────────────────────────────────────
ac_log "AC 5: repair_direct_dispatch consults repair_suspended before running the script"

grep -q '^source .*lib/repair-suspend\.sh' "$TARGET" \
  || ac_fail "supervisor-run.sh must source lib/repair-suspend.sh"
grep -qF -- 'repair_suspended "$name"' "$TARGET" \
  || ac_fail "supervisor-run.sh must call repair_suspended in repair_direct_dispatch"

DISPATCH_SRC="$(ac_extract_fn repair_direct_dispatch "$TARGET")"
[ -n "$DISPATCH_SRC" ] || ac_fail "could not extract repair_direct_dispatch() from supervisor-run.sh"

mkdir -p "$TMP_DIR/factory/supervisor/actions"
cat > "$TMP_DIR/factory/supervisor/actions/marker.sh" <<'EOF'
#!/usr/bin/env bash
touch "$MARKER_FILE"
EOF

RECIPE="$(jq -cn \
  --arg n boom-recipe \
  --arg s supervisor/actions/marker.sh \
  --arg e 'disk pressure' \
  '{"fired":[{"name":$n,"action":"direct","action_script":$s,"evidence":$e}]}')"

run_dispatch_case() {
  local mode="$1" label="$2"
  local marker="$TMP_DIR/marker-$mode"
  RC=0
  OUT=""
  OUT="$(
    set -euo pipefail
    FACTORY_ROOT="$TMP_DIR/factory"
    export FACTORY_ROOT
    export PROJECT_TOML="$FACTORY_ROOT/projects/disinto.toml"
    export MARKER_FILE="$marker"
    log() { printf '%s\n' "$*"; }
    tape_run() { return 0; }
    # #2054: the suspension arm calls notice_owner when it marks the
    # suspension; stub it so this hermetic test queues nothing.
    notice_owner() { :; }
    repair_tape_state_file() { printf '%s\n' "$TMP_DIR/no-such-state.json"; }
    emit_repair_proposal() { return 0; }
    if [ "$mode" = "0" ]; then
      repair_suspended() { echo "10 12"; return 0; }
    elif [ "$mode" = "2" ]; then
      repair_suspended() { echo "10 12"; return 2; }
    else
      repair_suspended() { echo "9 12"; return 1; }
    fi
    eval "$DISPATCH_SRC"
    repair_direct_dispatch "$RECIPE"
  )" || RC=$?
  ac_assert_eq "$RC" "0" "$label: the tick must still return 0 (got $RC): $OUT"
  case "$mode" in
    0)
      if [ -e "$marker" ]; then
        ac_fail "$label: a suspended remedy must not run its script, but the marker exists"
      fi
      case "$OUT" in
        *"suspended: boom-recipe (10 of last 12 tries failed)"*) ;;
        *) ac_fail "$label: expected 'suspended: boom-recipe (10 of last 12 tries failed)', got: $OUT" ;;
      esac
      ;;
    2)
      [ -e "$marker" ] || ac_fail "$label: the trial must run the script, marker missing"
      case "$OUT" in
        *"trial: boom-recipe"*) ;;
        *) ac_fail "$label: expected a 'trial: boom-recipe' log line, got: $OUT" ;;
      esac
      ;;
    1)
      [ -e "$marker" ] || ac_fail "$label: not suspended must run the script, marker missing"
      case "$OUT" in
        *"suspended: boom-recipe"*|*"trial: boom-recipe"*)
          ac_fail "$label: rc 1 must log neither suspended nor trial, got: $OUT" ;;
      esac
      ;;
  esac
}

run_dispatch_case 0 "rc 0 (suspended)"
run_dispatch_case 2 "rc 2 (trial)"
run_dispatch_case 1 "rc 1 (not suspended)"

# ── syntax ───────────────────────────────────────────────────────────────────
ac_log "syntax: bash -n on lib/repair-suspend.sh and supervisor/supervisor-run.sh"
bash -n "$LIB" || ac_fail "bash -n failed on lib/repair-suspend.sh"
bash -n "$TARGET" || ac_fail "bash -n failed on supervisor/supervisor-run.sh"

ac_pass
