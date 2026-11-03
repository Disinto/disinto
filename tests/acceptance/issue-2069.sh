#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2069.sh — sync the ops clone at the start of every run
#
# Issue #2069: supervisor-run.sh reads deployment config out of the ops clone at
# $OPS_REPO_ROOT — the stop rule's pack packs/repair.toml (#2053) and the
# incidents directory — but nothing in it ever updates that clone.
# ensure_ops_repo is sourced (lib/formula-session.sh) yet never called, so a
# supervisor container can run for weeks against a stale branch and the stop
# rule silently sees no pack. The fix is one top-level ensure_ops_repo call in
# the Guards block, between acquire_run_lock and the run-start log line, exactly
# as the gardener does (#1653).
#
# Acceptance:
#   AC 1: supervisor-run.sh contains a line that is exactly `ensure_ops_repo`,
#         at top level (brace depth 0), after
#         `acquire_run_lock "/tmp/supervisor-run.lock"` and before
#         `log "--- Supervisor run start ---"`.
#   AC 2: hermetic sync: a bare origin whose main holds packs/repair.toml and a
#         clone stranded on another branch at an older commit. After the
#         extracted ensure_ops_repo the clone is on main, at origin/main,
#         packs/repair.toml is present, and the return code is 0.
#   AC 3: the same clone with an unreachable origin: return code 0 and at least
#         one "WARNING: ops repo" line logged.
#   AC 4: bash -n supervisor/supervisor-run.sh passes.
#   AC 5: tests/acceptance/issue-1653.sh (which covers ensure_ops_repo itself)
#         still passes.
#
# Hermetic: a local bare origin (a file path, never $FORGE_URL) and a clone; no
# network, no live box.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash git awk grep tail cat mktemp

# CI containers ship git with no identity (~/.gitconfig is empty), so every
# fixture commit below carries an author through the git environment.
export GIT_AUTHOR_NAME="acceptance-fixture"
export GIT_AUTHOR_EMAIL="acceptance-fixture@example.com"
export GIT_COMMITTER_NAME="acceptance-fixture"
export GIT_COMMITTER_EMAIL="acceptance-fixture@example.com"

TARGET="$REPO_ROOT/supervisor/supervisor-run.sh"
LIB="$REPO_ROOT/lib/formula-session.sh"
ac_assert_file "$TARGET" "supervisor/supervisor-run.sh must exist"
ac_assert_file "$LIB" "lib/formula-session.sh must exist"

# ── AC 1: the call is present, top level, and correctly placed ───────────────
ac_log "AC 1: checking where the ensure_ops_repo call sits"
lock_line="$(grep -nF 'acquire_run_lock "/tmp/supervisor-run.lock"' "$TARGET" | head -n 1 | cut -d: -f1 || true)"
start_line="$(grep -nF 'log "--- Supervisor run start ---"' "$TARGET" | head -n 1 | cut -d: -f1 || true)"
sync_line="$(grep -nxF 'ensure_ops_repo' "$TARGET" | head -n 1 | cut -d: -f1 || true)"
[ -n "$lock_line" ] || ac_fail "AC 1: acquire_run_lock \"/tmp/supervisor-run.lock\" not found in supervisor-run.sh"
[ -n "$start_line" ] || ac_fail "AC 1: the run-start log line not found in supervisor-run.sh"
[ -n "$sync_line" ] || ac_fail "AC 1: supervisor-run.sh must call ensure_ops_repo on its own line"
[ "$sync_line" -gt "$lock_line" ] \
  || ac_fail "AC 1: ensure_ops_repo (line $sync_line) must come after acquire_run_lock (line $lock_line)"
[ "$sync_line" -lt "$start_line" ] \
  || ac_fail "AC 1: ensure_ops_repo (line $sync_line) must come before the run-start log line (line $start_line)"

# The call must sit at top level, not inside a function body: the brace depth of
# every line above it is 0 (comment-only lines are skipped, and nothing in the
# preamble carries an unbalanced brace).
depth="$(awk -v stop="$sync_line" '
  NR >= stop { exit }
  /^[[:space:]]*#/ { next }
  { opens = gsub(/\{/, "", $0); closes = gsub(/\}/, "", $0); depth += opens - closes }
  END { print depth }
' "$TARGET")"
ac_assert_eq "$depth" "0" "AC 1: line $sync_line is nested in a function body (brace depth $depth above it)"

# ensure_ops_repo is only in scope because the script sources the lib that
# defines it.
grep -qF 'lib/formula-session.sh' "$TARGET" \
  || ac_fail "AC 1: supervisor-run.sh must source lib/formula-session.sh for ensure_ops_repo"

# ── Hermetic git fixture: a bare origin and a seed tree ──────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SEED="$WORK/seed"
ORIGIN="$WORK/origin.git"

git init --bare --initial-branch=main "$ORIGIN"
mkdir -p "$SEED/packs" "$SEED/incidents"
cat > "$SEED/packs/repair.toml" <<'SEED_PACK'
window = 20
suspend_at = 10
trial_days = 7
SEED_PACK
printf '%s\n' '# ops config' > "$SEED/packs/ops-config.toml"
git -C "$SEED" init --initial-branch=main
git -C "$SEED" remote add origin "$ORIGIN"
git -C "$SEED" add -A
git -C "$SEED" commit -m "seed the ops pack"
git -C "$SEED" push origin main

# Add a commit to origin/main so a clone made earlier is behind it.
bump_pack() {
  printf 'window = 30\n' >> "$SEED/packs/repair.toml"
  git -C "$SEED" commit -am "pack bump: $1"
  git -C "$SEED" push origin main
}

# A clone stranded on a stale branch at an older commit: the live-box shape.
stranded_clone() {
  local dest="$1"
  git clone -q "$ORIGIN" "$dest"
  git -C "$dest" checkout -q -b planner/run-2026-08-06
  printf 'stale local note\n' > "$dest/stale-note.txt"
  git -C "$dest" add -A
  git -C "$dest" commit -m "commit on the stale branch"
}

# ── Driver: the extracted ensure_ops_repo, run against one clone ─────────────
FN_SRC="$(ac_extract_fn ensure_ops_repo "$LIB")"
[ -n "$FN_SRC" ] || ac_fail "could not extract ensure_ops_repo() from $LIB"
printf '%s\n' "$FN_SRC" > "$WORK/fn.sh"
# log() is stubbed to a file the assertions grep; migrate_ops_repo() is stubbed
# because the fixture never touches the live forge seed/push path.
cat > "$WORK/driver.sh" <<'RUN_OPS_SYNC'
set -u
export OPS_REPO_ROOT="$1"
log() { printf '%s\n' "$*" >> "$LOGFILE"; }
migrate_ops_repo() { :; }
eval "$(cat "$FN_FILE")"
ensure_ops_repo
printf '%s' "$?" > "$RCFILE"
RUN_OPS_SYNC

RC=""
LOG=""
# run_sync CLONE — calls the extracted function with PRIMARY_BRANCH=main and
# OPS_REPO_ROOT=CLONE. Sets RC to its return code, LOG to the stubbed log file.
run_sync() {
  local clone="$1" driver_rc
  RC_FILE="$WORK/rc.txt"
  LOG="$WORK/log.txt"
  : > "$LOG"
  driver_rc=0
  PRIMARY_BRANCH=main LOGFILE="$LOG" RCFILE="$RC_FILE" FN_FILE="$WORK/fn.sh" \
    bash "$WORK/driver.sh" "$clone" 2>"$WORK/driver-err.txt" || driver_rc=$?
  if [ "$driver_rc" -ne 0 ]; then
    ac_fail "ops-driver exited ${driver_rc}: $(cat "$WORK/driver-err.txt")"
  fi
  RC="$(cat "$RC_FILE")"
  [ -n "$RC" ] || ac_fail "ops-driver wrote no rc file: $(cat "$WORK/driver-err.txt")"
}

# ── AC 2: the stranded clone ends on main at origin/main, pack present, rc 0 ──
ac_log "AC 2: syncing a clone stranded on a stale branch at an older commit"
CLONE="$WORK/ac2-clone"
stranded_clone "$CLONE"
bump_pack "the pack gains a line"
run_sync "$CLONE"
ac_assert_eq "$RC" "0" "AC 2: ensure_ops_repo must return 0 (rc=${RC})"
branch="$(git -C "$CLONE" rev-parse --abbrev-ref HEAD)"
ac_assert_eq "$branch" "main" "AC 2: the clone is on '$branch' after the sync, expected main"
ac_assert_eq "$(git -C "$CLONE" rev-parse HEAD)" "$(git -C "$ORIGIN" rev-parse main)" \
  "AC 2: the clone is still behind origin/main after the sync"
ac_assert_file "$CLONE/packs/repair.toml" "AC 2: packs/repair.toml missing from the synced clone"
grep -qF 'WARNING: ops repo ' "$LOG" \
  && ac_fail "AC 2: a clean sync must not warn (log: $(cat "$LOG"))"

# ── AC 3: an unreachable origin must not abort the run ───────────────────────
ac_log "AC 3: an unreachable origin returns 0 and logs a warning"
CLONE3="$WORK/ac3-clone"
stranded_clone "$CLONE3"
git -C "$CLONE3" remote set-url origin /nonexistent
run_sync "$CLONE3"
ac_assert_eq "$RC" "0" "AC 3: ensure_ops_repo must return 0 with an unreachable origin (rc=${RC})"
grep -qF 'WARNING: ops repo ' "$LOG" \
  || ac_fail "AC 3: expected at least one 'WARNING: ops repo' line (log: $(cat "$LOG"))"

# ── AC 4: the supervisor script still parses ─────────────────────────────────
ac_log "AC 4: bash -n supervisor/supervisor-run.sh"
parse_rc=0
bash -n "$TARGET" || parse_rc=$?
ac_assert_eq "$parse_rc" "0" "AC 4: supervisor-run.sh must parse (bash -n rc=$parse_rc)"

# ── AC 5: the existing ensure_ops_repo test still passes ─────────────────────
ac_log "AC 5: running tests/acceptance/issue-1653.sh"
rc=0
out="$(bash "$REPO_ROOT/tests/acceptance/issue-1653.sh" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] || [ "$(printf '%s\n' "$out" | tail -n 1)" != "PASS" ]; then
  ac_fail "AC 5: issue-1653.sh must still pass (rc=$rc): $out"
fi

ac_pass
