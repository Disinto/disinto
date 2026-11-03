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
#         clone left on another branch at an older commit. After the extracted
#         ensure_ops_repo the clone is on main, at origin/main, packs/repair.toml
#         is present, and the return code is 0.
#   AC 3: same fixture with an unreachable origin: return code 0 and at least
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

# CI containers have no git identity (~/.gitconfig is empty), so every commit
# this fixture makes carries an explicit author through the git env vars.
export GIT_AUTHOR_NAME="acceptance-fixture"
export GIT_AUTHOR_EMAIL="acceptance-fixture@example.com"
export GIT_COMMITTER_NAME="acceptance-fixture"
export GIT_COMMITTER_EMAIL="acceptance-fixture@example.com"

TARGET="$REPO_ROOT/supervisor/supervisor-run.sh"
LIB="$REPO_ROOT/lib/formula-session.sh"
ac_assert_file "$TARGET" "supervisor/supervisor-run.sh must exist"
ac_assert_file "$LIB" "lib/formula-session.sh must exist"

# ── AC 1: the call is present, top level, and correctly placed ───────────────
ac_log "AC 1: checking the placement of the ensure_ops_repo call"
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
# every line before it is 0 (comment lines are ignored, and no line above the
# Guards block carries an unbalanced brace).
depth="$(awk -v n="$sync_line" '
  NR >= n { exit }
  /^[[:space:]]*#/ { next }
  {
    opens = gsub(/\{/, "", $0)
    closes = gsub(/\}/, "", $0)
    d += opens - closes
  }
  END { print d }
' "$TARGET")"
ac_assert_eq "$depth" "0" "AC 1: ensure_ops_repo at line $sync_line is nested inside a function body (brace depth $depth before it)"

# The helper must actually be in scope: supervisor-run.sh sources the lib that
# defines it.
grep -qF 'lib/formula-session.sh' "$TARGET" \
  || ac_fail "AC 1: supervisor-run.sh must source lib/formula-session.sh for ensure_ops_repo"

# ── Hermetic git fixture: bare origin + commits ──────────────────────────────
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ORIGIN_DIR="$TMP_DIR/origin"
git init -b main --bare "$ORIGIN_DIR"

WORK_DIR="$TMP_DIR/origin-work"
mkdir -p "$WORK_DIR/packs" "$WORK_DIR/incidents"
printf 'window = 20\nsuspend_at = 10\ntrial_days = 7\n' > "$WORK_DIR/packs/repair.toml"
printf '# ops config\n' > "$WORK_DIR/packs/ops-config.toml"
git -C "$WORK_DIR" init -b main
git -C "$WORK_DIR" config user.name "ops-test"
git -C "$WORK_DIR" config user.email "ops-test@example.com"
git -C "$WORK_DIR" add -A
git -C "$WORK_DIR" commit -m "initial ops commit"
git -C "$WORK_DIR" remote add origin "$ORIGIN_DIR"
git -C "$WORK_DIR" push --quiet origin main

# Advance origin/main by one commit (the pack gains a line).
advance_origin() {
  printf 'window = 30\n' >> "$WORK_DIR/packs/repair.toml"
  git -C "$WORK_DIR" add -A
  git -C "$WORK_DIR" commit -m "$1"
  git -C "$WORK_DIR" push --quiet origin main
}

# Fresh clone of the bare origin, left on a stale branch — the live-box shape.
new_stale_clone() {
  local dir="$1"
  git clone --quiet "$ORIGIN_DIR" "$dir"
  git -C "$dir" config user.name "ops-test"
  git -C "$dir" config user.email "ops-test@example.com"
  git -C "$dir" checkout -b planner/run-2026-08-06
  printf 'stale local note\n' > "$dir/stale-note.txt"
  git -C "$dir" add -A
  git -C "$dir" commit -m "stale branch commit"
}

# ── Driver: run the extracted ensure_ops_repo with log()/migrate_ops_repo stubbed
FN_SRC="$(ac_extract_fn ensure_ops_repo "$LIB")"
[ -n "$FN_SRC" ] || ac_fail "could not extract ensure_ops_repo() from $LIB"
FN_FILE="$TMP_DIR/fn.sh"
printf '%s\n' "$FN_SRC" > "$FN_FILE"

cat > "$TMP_DIR/driver.sh" <<'DRIVER'
set -u
export OPS_REPO_ROOT="$1"
# Stubs: the test asserts the git sync and the never-fatal contract, not the
# post-sync seed/push that migrate_ops_repo performs against the live forge.
log() { printf '%s\n' "$*" >> "${LOGFILE:-/dev/null}"; }
migrate_ops_repo() { :; }
eval "$(cat "$FN_FILE")"
ensure_ops_repo
printf '%s' "$?" > "$RCFILE"
DRIVER

# run_sync <ops-root> — runs the extracted ensure_ops_repo against <ops-root>
# with PRIMARY_BRANCH=main; sets RC to its return code and LOG_FILE_OUT to the
# stubbed log file.
run_sync() {
  local ops_root="$1" driver_rc
  RCFILE="$TMP_DIR/rc.txt"
  LOG_FILE_OUT="$TMP_DIR/log.txt"
  : > "$LOG_FILE_OUT"
  if PRIMARY_BRANCH="main" LOGFILE="$LOG_FILE_OUT" RCFILE="$RCFILE" FN_FILE="$FN_FILE" \
      bash "$TMP_DIR/driver.sh" "$ops_root" 2>"$TMP_DIR/driver-err.txt"; then
    driver_rc=0
  else
    driver_rc=$?
  fi
  if [ "$driver_rc" -ne 0 ]; then
    ac_fail "ops-driver exited ${driver_rc}; stderr: $(cat "$TMP_DIR/driver-err.txt")"
  fi
  RC="$(cat "$RCFILE" 2>/dev/null || true)"
  [ -n "$RC" ] || ac_fail "ops-driver wrote no rc file (stderr: $(cat "$TMP_DIR/driver-err.txt"))"
}

# ── AC 2: a stale clone ends on main at origin/main, pack present, rc 0 ──────
ac_log "AC 2: syncing a clone left on a stale branch at an older commit"
CLONE="$TMP_DIR/ac2-clone"
new_stale_clone "$CLONE"
advance_origin "pack bump"
run_sync "$CLONE"
ac_assert_eq "$RC" "0" "AC 2: ensure_ops_repo must return 0 (rc=${RC})"
clone_branch="$(git -C "$CLONE" rev-parse --abbrev-ref HEAD)"
ac_assert_eq "$clone_branch" "main" "AC 2: clone is on '$clone_branch' after sync, expected main"
clone_head="$(git -C "$CLONE" rev-parse HEAD)"
origin_head="$(git -C "$ORIGIN_DIR" rev-parse main)"
ac_assert_eq "$clone_head" "$origin_head" "AC 2: clone HEAD $clone_head != origin/main $origin_head"
ac_assert_file "$CLONE/packs/repair.toml" "AC 2: packs/repair.toml missing from the synced clone"
grep -qF 'WARNING: ops repo ' "$LOG_FILE_OUT" \
  && ac_fail "AC 2: a successful sync must not log a warning (log: $(cat "$LOG_FILE_OUT"))"

# ── AC 3: unreachable origin → rc 0 and at least one warning ─────────────────
ac_log "AC 3: an unreachable origin must not abort the run"
CLONE3="$TMP_DIR/ac3-clone"
new_stale_clone "$CLONE3"
git -C "$CLONE3" remote set-url origin /nonexistent
run_sync "$CLONE3"
ac_assert_eq "$RC" "0" "AC 3: ensure_ops_repo must return 0 with an unreachable origin (rc=${RC})"
grep -qF 'WARNING: ops repo ' "$LOG_FILE_OUT" \
  || ac_fail "AC 3: expected at least one 'WARNING: ops repo' line (log: $(cat "$LOG_FILE_OUT"))"

# ── AC 4: the supervisor script still parses ─────────────────────────────────
ac_log "AC 4: bash -n supervisor/supervisor-run.sh"
rc=0
bash -n "$TARGET" || rc=$?
ac_assert_eq "$rc" "0" "AC 4: supervisor-run.sh must parse (bash -n rc=$rc)"

# ── AC 5: the existing ensure_ops_repo test still passes ─────────────────────
ac_log "AC 5: running tests/acceptance/issue-1653.sh"
rc=0
out="$(bash "$REPO_ROOT/tests/acceptance/issue-1653.sh" 2>&1)" || rc=$?
last="$(printf '%s\n' "$out" | tail -n 1)"
if [ "$rc" -ne 0 ] || [ "$last" != "PASS" ]; then
  ac_fail "AC 5: issue-1653.sh must still pass (rc=$rc): $out"
fi

ac_pass
