#!/usr/bin/env bash
# issue-2088 — ensure_ops_repo is not actually never-fatal: migrate_ops_repo
# can abort the run under set -e.
#
# ACs:
#   AC 1: lib/formula-session.sh guards the migrate_ops_repo call inside
#         ensure_ops_repo (|| log "WARNING: ops repo migration failed") so a
#         failing migration cannot trip the caller's set -e.
#   AC 2: lib/ops-setup.sh wraps `git add -A` inside migrate_ops_repo with an
#         `if ! ...; then` guard, so a stray .git/index.lock logs a warning
#         and migrate_ops_repo returns 1 instead of aborting the run.
#   AC 3: hermetic run — bare origin + clone with a stray .git/index.lock:
#         ensure_ops_repo (with the REAL migrate_ops_repo) returns 0 under
#         set -euo pipefail and logs "WARNING: ops repo migration failed".
#   AC 4: the same fixture without the stray lock still succeeds (rc 0, no
#         migration warning) and seeds the canonical structure — the guard
#         must not break the happy path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash git awk mktemp tail grep cat printf
SESSION_LIB="$REPO_ROOT/lib/formula-session.sh"
OPS_LIB="$REPO_ROOT/lib/ops-setup.sh"
ac_assert_file "$SESSION_LIB" "lib/formula-session.sh must exist"
ac_assert_file "$OPS_LIB" "lib/ops-setup.sh must exist"

# ── AC 1: the migration call is guarded in formula-session.sh ─────────────────
# shellcheck disable=SC2016  # literal shell source, not a command to expand
grep -qF 'migrate_ops_repo "$ops_root" "${PRIMARY_BRANCH}" || log "WARNING: ops repo migration failed"' \
  "$SESSION_LIB" \
  || ac_fail "AC 1: ensure_ops_repo must guard migrate_ops_repo with '|| log \"WARNING: ops repo migration failed\"'"

# ── AC 2: git add -A inside migrate_ops_repo is wrapped ───────────────────────
grep -qF 'if ! git add -A 2>/dev/null; then' "$OPS_LIB" \
  || ac_fail "AC 2: migrate_ops_repo must wrap 'git add -A' in an 'if ! ...; then' guard"

# ── Extract the functions under test ──────────────────────────────────────────
ENSURE_SRC="$(ac_extract_fn ensure_ops_repo "$SESSION_LIB")"
[ -n "$ENSURE_SRC" ] || ac_fail "could not extract ensure_ops_repo() from $SESSION_LIB"
MIGRATE_SRC="$(ac_extract_fn migrate_ops_repo "$OPS_LIB")"
[ -n "$MIGRATE_SRC" ] || ac_fail "could not extract migrate_ops_repo() from $OPS_LIB"
LEDGER_SRC="$(ac_extract_fn _ops_ledger_layout_current "$OPS_LIB")"
[ -n "$LEDGER_SRC" ] || ac_fail "could not extract _ops_ledger_layout_current() from $OPS_LIB"

# ── Hermetic git fixture: bare origin + commits ───────────────────────────────
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
ac_git_ops_origin "$TMP_DIR"

new_clone() {
  git clone --quiet "$ORIGIN_DIR" "$TMP_DIR/$1"
}

# ── Driver: run the REAL ensure_ops_repo (migrate not stubbed) ────────────────
cat > "$TMP_DIR/ops-driver.sh" <<'DRIVER'
set -euo pipefail
OPS_ROOT="$1"
export OPS_REPO_ROOT="$OPS_ROOT"
# log() appends to LOGFILE; reaching the final echo proves the run was NOT
# aborted by set -e mid-function.
log() { printf '%s\n' "$*" >> "${LOGFILE:-/dev/null}"; }
eval "$(cat "$ENSURE_FN_FILE")"
eval "$(cat "$OPS_FN_FILE")"
ensure_ops_repo
echo "REACHED-END rc=$?"
DRIVER
chmod +x "$TMP_DIR/ops-driver.sh"

ENSURE_FN_FILE="$TMP_DIR/ensure-fn.sh"
OPS_FN_FILE="$TMP_DIR/ops-fn.sh"
printf '%s\n' "$ENSURE_SRC" > "$ENSURE_FN_FILE"
printf '%s\n' "$MIGRATE_SRC" > "$OPS_FN_FILE"
printf '%s\n' "$LEDGER_SRC" >> "$OPS_FN_FILE"

# run_ops_sync <ops-root> — run ensure_ops_repo in a hermetic set -euo pipefail
# subshell. Sets RC to the subshell's exit code, OUT to its stdout, LOG to the
# stubbed log file.
run_ops_sync() {
  local ops_root="$1"
  LOG="$TMP_DIR/log.txt"
  : > "$LOG"
  RC=0
  OUT="$(PRIMARY_BRANCH="main" LOGFILE="$LOG" \
        ENSURE_FN_FILE="$ENSURE_FN_FILE" OPS_FN_FILE="$OPS_FN_FILE" \
        bash "$TMP_DIR/ops-driver.sh" "$ops_root" 2>"$TMP_DIR/driver-err.txt")" || RC=$?
  if [ "$RC" -ne 0 ]; then
    ac_fail "AC: ops-driver aborted with rc ${RC} (ensure_ops_repo is supposed to be never-fatal); stderr: $(cat "$TMP_DIR/driver-err.txt")"
  fi
}

# ── AC 3: stray .git/index.lock → ensure_ops_repo still returns 0 ─────────────
new_clone ac3-clone
head_before="$(git -C "$TMP_DIR/ac3-clone" rev-parse HEAD)"
printf 'stale-lock\n' > "$TMP_DIR/ac3-clone/.git/index.lock"
run_ops_sync "$TMP_DIR/ac3-clone"
grep -qF 'REACHED-END rc=0' <<<"$OUT" \
  || ac_fail "AC 3: ensure_ops_repo must reach its 'return 0' with a stray index.lock (stdout: $OUT)"
grep -qF 'WARNING: ops repo migration failed' "$LOG" \
  || ac_fail "AC 3: expected a 'WARNING: ops repo migration failed' log line (log: $(cat "$LOG"))"
head_after="$(git -C "$TMP_DIR/ac3-clone" rev-parse HEAD)"
ac_assert_eq "$head_after" "$head_before" "AC 3: a failed migration must not commit anything"

# ── AC 2 (behavioral): migrate_ops_repo alone returns 1 on a stray lock ──────
cat > "$TMP_DIR/migrate-driver.sh" <<'MIGR_DRIVER'
set -euo pipefail
eval "$(cat "$OPS_FN_FILE")"
rc=0
migrate_ops_repo "$1" "main" || rc=$?
echo "MIGRATE-RC=$rc"
MIGR_DRIVER
chmod +x "$TMP_DIR/migrate-driver.sh"
# Stray lock on a fresh clone (origin is still un-migrated, so the seeding
# actually runs and git add hits the lock): migrate must return 1, not abort.
new_clone ac2-clone
printf 'stale-lock\n' > "$TMP_DIR/ac2-clone/.git/index.lock"
migrate_rc=0
migrate_out="$(OPS_FN_FILE="$OPS_FN_FILE" bash "$TMP_DIR/migrate-driver.sh" "$TMP_DIR/ac2-clone" 2>"$TMP_DIR/migrate-err.txt")" || migrate_rc=$?
ac_assert_eq "$migrate_rc" "0" "AC 2: migrate_ops_repo must return, not abort, on a stray index.lock (stderr: $(cat "$TMP_DIR/migrate-err.txt"))"
grep -qF 'MIGRATE-RC=1' <<<"$migrate_out" \
  || ac_fail "AC 2: migrate_ops_repo must return 1 on a stray index.lock, got '$migrate_out'"
# Baseline: a clean clone still migrates successfully.
new_clone ac2b-clone
migrate_rc=0
migrate_out="$(OPS_FN_FILE="$OPS_FN_FILE" bash "$TMP_DIR/migrate-driver.sh" "$TMP_DIR/ac2b-clone" 2>"$TMP_DIR/migrate-err.txt")" || migrate_rc=$?
ac_assert_eq "$migrate_rc" "0" "AC 2: migrate-driver itself must not abort (stderr: $(cat "$TMP_DIR/migrate-err.txt"))"
grep -qF 'MIGRATE-RC=0' <<<"$migrate_out" \
  || ac_fail "AC 2: baseline migrate_ops_repo on a clean clone must succeed, got '$migrate_out'"

# ── AC 4: happy path still works — canonical structure seeded, no warning ────
new_clone ac4-clone
run_ops_sync "$TMP_DIR/ac4-clone"
grep -qF 'WARNING: ops repo migration failed' "$LOG" \
  && ac_fail "AC 4: unexpected migration warning on a clean clone (log: $(cat "$LOG"))"
ac_assert_file "$TMP_DIR/ac4-clone/knowledge/.gitkeep" "AC 4: migration must still seed the canonical structure on a clean clone"
ac_assert_file "$TMP_DIR/ac4-clone/runs/README.md" "AC 4: run-ledger layout must be seeded on a clean clone"

ac_pass
