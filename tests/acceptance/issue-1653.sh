#!/usr/bin/env bash
# issue-1653 — sync the ops clone at the start of every gardener run.
#
# ACs:
#   AC 1: a clone one commit behind a local bare origin: after ensure_ops_repo
#         its HEAD == the origin's main (and it is on main).
#   AC 2: a clone left on another branch: after the call it is back on main.
#   AC 3: a clone whose origin does not exist: the call returns 0 and logs
#         "WARNING: ops repo fetch failed".
#   AC 4: in gardener/gardener-run.sh, the ensure_ops_repo call comes after
#         acquire_run_lock and before the precondition checks.
#
# Hermetic: a local bare origin (file path, never $FORGE_URL) + a clone; the
# clone path of ensure_ops_repo is never taken, only the [ -d .git ] path.
# The function is extracted via ac_extract_fn and run in a subshell with
# log() and migrate_ops_repo() stubbed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash git awk mktemp tail grep cut head cat
LIB_FILE="$REPO_ROOT/lib/formula-session.sh"
ac_assert_file "$LIB_FILE" "lib/formula-session.sh must exist"
GARDENER_RUN="$REPO_ROOT/gardener/gardener-run.sh"
ac_assert_file "$GARDENER_RUN" "gardener/gardener-run.sh must exist"

# ── Extract the function under test ────────────────────────────────────────────
FN_SRC="$(ac_extract_fn ensure_ops_repo "$LIB_FILE")"
[ -n "$FN_SRC" ] || ac_fail "could not extract ensure_ops_repo() from $LIB_FILE"

# ── Hermetic git fixture: bare origin + commits + per-AC clones ─────────────
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ORIGIN_DIR="$TMP_DIR/origin"
git init -b main --bare "$ORIGIN_DIR"

WORK_DIR="$TMP_DIR/origin-work"
mkdir -p "$WORK_DIR/packs"
printf '# ops config\n' > "$WORK_DIR/packs/ops-config.toml"
git -C "$WORK_DIR" init -b main
git -C "$WORK_DIR" config user.name "ops-test"
git -C "$WORK_DIR" config user.email "ops-test@example.com"
git -C "$WORK_DIR" add -A
git -C "$WORK_DIR" commit -m "initial ops commit"
git -C "$WORK_DIR" remote add origin "$ORIGIN_DIR"
git -C "$WORK_DIR" push --quiet origin main

# Advance the origin by one commit (append a line, commit, push).
advance_origin() {
  local appended="$1" msg="$2"
  printf '\n%s\n' "$appended" >> "$WORK_DIR/packs/ops-config.toml"
  git -C "$WORK_DIR" add -A
  git -C "$WORK_DIR" commit -m "$msg"
  git -C "$WORK_DIR" push --quiet origin main
}

# Fresh local clone of the bare origin (on main, at origin's current HEAD).
new_clone() {
  git clone --quiet "$ORIGIN_DIR" "$TMP_DIR/$1"
}

# ── Driver: run the extracted ensure_ops_repo against a clone, stubbed ─────
cat > "$TMP_DIR/ops-driver.sh" <<'DRIVER'
set -u
OPS_ROOT="$1"
export OPS_REPO_ROOT="$OPS_ROOT"
# Stubs: the test asserts git-sync behavior (fetch/checkout/pull + branch
# state), not the post-sync seed/push. log() appends to LOGFILE; rc is the
# return value of ensure_ops_repo, written to RCFILE.
log() { printf '%s\n' "$*" >> "${LOGFILE:-/dev/null}"; }
migrate_ops_repo() { :; }
eval "$(cat "$FN_FILE")"
ensure_ops_repo
rc=$?
printf '%s' "$rc" > "$RCFILE"
DRIVER
chmod +x "$TMP_DIR/ops-driver.sh"
FN_FILE="$TMP_DIR/fn.sh"
printf '%s\n' "$FN_SRC" > "$FN_FILE"

RC=""
LOGFILE_OUT=""
# run_ops_sync <ops-root> — run ensure_ops_repo in a hermetic subshell with
# PRIMARY_BRANCH=main, OPS_REPO_ROOT=<ops-root>, log()/migrate_ops_repo() stubbed.
# Sets RC to the function's return code and LOGFILE_OUT to the stubbed log.
run_ops_sync() {
  local ops_root="$1" rcfile logfile driver_rc
  rcfile="$TMP_DIR/rc.txt"
  logfile="$TMP_DIR/log.txt"
  : > "$logfile"
  if PRIMARY_BRANCH="main" \
      LOGFILE="$logfile" RCFILE="$rcfile" FN_FILE="$FN_FILE" \
      bash "$TMP_DIR/ops-driver.sh" "$ops_root" 2>"$TMP_DIR/driver-err.txt"; then
    driver_rc=0
  else
    driver_rc=$?
  fi
  if [ "$driver_rc" -ne 0 ]; then
    ac_fail "AC: ops-driver exited ${driver_rc}; stderr: $(cat "$TMP_DIR/driver-err.txt")"
  fi
  RC="$(cat "$rcfile" 2>/dev/null || true)"
  if [ -z "$RC" ]; then
    ac_fail "AC: ops-driver did not write rc file (stderr: $(cat "$TMP_DIR/driver-err.txt"))"
  fi
  LOGFILE_OUT="$logfile"
}

# ── AC 1: clone one commit behind origin → synced to origin's main ─────────
new_clone ac1-clone
advance_origin "second ops line" "second ops commit"
run_ops_sync "$TMP_DIR/ac1-clone"
ac_assert_eq "$RC" "0" "AC 1: ensure_ops_repo must return 0 (rc=${RC})"
clone_head="$(git -C "$TMP_DIR/ac1-clone" rev-parse HEAD)"
origin_head="$(git -C "$ORIGIN_DIR" rev-parse main)"
ac_assert_eq "$clone_head" "$origin_head" "AC 1: clone HEAD $clone_head != origin/main $origin_head"
ac_assert_eq "$(git -C "$TMP_DIR/ac1-clone" rev-parse --abbrev-ref HEAD)" \
  "main" "AC 1: clone not on main after sync"
grep -qF 'WARNING: ops repo ' "$LOGFILE_OUT" \
  && ac_fail "AC 1: unexpected WARNING on a successful sync (log: $(cat "$LOGFILE_OUT"))"

# ── AC 2: clone left on another branch → back on main ─────────────────────
new_clone ac2-clone
git -C "$TMP_DIR/ac2-clone" checkout -b dev
run_ops_sync "$TMP_DIR/ac2-clone"
ac_assert_eq "$RC" "0" "AC 2: ensure_ops_repo must return 0 (rc=${RC})"
ac_assert_eq "$(git -C "$TMP_DIR/ac2-clone" rev-parse --abbrev-ref HEAD)" \
  "main" "AC 2: expected main after sync, got '$(git -C "$TMP_DIR/ac2-clone" rev-parse --abbrev-ref HEAD)'"
grep -qF 'WARNING: ops repo ' "$LOGFILE_OUT" \
  && ac_fail "AC 2: unexpected WARNING on a successful sync (log: $(cat "$LOGFILE_OUT"))"

# ── AC 3: clone with no origin → returns 0 and logs a fetch warning ──────────
new_clone ac3-clone
git -C "$TMP_DIR/ac3-clone" remote remove origin
run_ops_sync "$TMP_DIR/ac3-clone"
ac_assert_eq "$RC" "0" "AC 3: ensure_ops_repo must return 0 when origin is missing (rc=${RC})"
grep -qF 'WARNING: ops repo fetch failed' "$LOGFILE_OUT" \
  || ac_fail "AC 3: expected a 'WARNING: ops repo fetch failed' line (log: $(cat "$LOGFILE_OUT"))"

# ── AC 4: gardener-run.sh calls ensure_ops_repo between lock and preconditions
# ─────────────────────────────────────────────────────────────────────────────────
lock_line=$(grep -n 'acquire_run_lock' "$GARDENER_RUN" | head -n 1 | cut -d: -f1 || true)
sync_line=$(grep -nE '^[[:space:]]*ensure_ops_repo[[:space:]]*$' "$GARDENER_RUN" | head -n 1 | cut -d: -f1 || true)
precond_line=$(grep -n 'Precondition checks' "$GARDENER_RUN" | head -n 1 | cut -d: -f1 || true)
[ -n "$lock_line" ] || ac_fail "AC 4: acquire_run_lock not found in gardener-run.sh"
[ -n "$sync_line" ] || ac_fail "AC 4: ensure_ops_repo not called in gardener-run.sh"
[ -n "$precond_line" ] || ac_fail "AC 4: precondition-checks marker not found in gardener-run.sh"
[ "$sync_line" -gt "$lock_line" ] \
  || ac_fail "AC 4: ensure_ops_repo (line $sync_line) must come after acquire_run_lock (line $lock_line)"
[ "$sync_line" -lt "$precond_line" ] \
  || ac_fail "AC 4: ensure_ops_repo (line $sync_line) must come before the precondition checks (line $precond_line)"

ac_pass