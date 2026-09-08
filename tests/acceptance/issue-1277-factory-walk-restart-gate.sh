#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1277-factory-walk-restart-gate.sh
#
# Issue #1277: during the 2026-09-08 crash-loop both agent allocs exited 1
# every 30 minutes for ~26h while the factory walk reported OK every 40
# minutes — the logs were still fresh (entrypoint wait messages), so the
# log-freshness gates saw nothing wrong. The walk now gates on the Nomad
# per-alloc "Total Restarts" counter (bin/factory-walk.sh) and must page the
# walk queue when an alloc gains >= 2 restarts between walks, and page
# nothing during a quiet period.
#
# This test simulates Nomad with a fake `nomad` on PATH (restart counts and
# alloc ids are driven from env vars) and drives bin/factory-walk.sh against
# temp state and queue dirs:
#   1. first walk (baseline, 0 restarts)      -> no walk-queue item
#   2. single restart since last walk (+1)    -> no walk-queue item
#                                              (below threshold 2)
#   3. double restart since last walk (+2)    -> exactly one walk-queue item
#   4. quiet period (no new restarts)         -> no new walk-queue item
#   5. alloc replaced (redeploy, counter 0)   -> re-baseline, no false page
#   6. crash-loop continues on the new alloc   -> pages again at threshold
#
# Read-only with respect to live systems: all state lives in a temp dir and
# the fake nomad never touches the real Nomad, the live state dir, or the
# live walk queue.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk
ac_require_cmd sort

GATE="$REPO_ROOT/bin/factory-walk.sh"
ac_assert_file "$GATE" "bin/factory-walk.sh must exist"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Fake nomad ──────────────────────────────────────────────────────────────
# Emulates the two commands the gate uses:
#   nomad alloc list -latest <job>   -> one table row with the alloc id
#   nomad alloc status <alloc>       -> a task block with "Total Restarts: N"
# FAKE_ALLOC_<JOB> / FAKE_RESTARTS_<JOB> control the simulation.
cat > "$TMP/nomad" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  "alloc list")
    job="$4"
    echo "ID  Node ID  Task Group  Node Pool  Desired  Created"
    case "$job" in
      agents-dev-qwen)
        echo "${FAKE_ALLOC_DEV:-0a8f19be580b7c7d66b5502b6ce7d0bb}  node-1  agents  default  running  17h" ;;
      agents-review-qwen)
        echo "${FAKE_ALLOC_REVIEW:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}  node-1  agents  default  running  17h" ;;
      *)
        exit 3 ;;
    esac
    ;;
  "alloc status")
    alloc="$3"
    n="${FAKE_RESTARTS_DEV:-0}"
    case "$alloc" in
      bbbb*) n="${FAKE_RESTARTS_REVIEW:-0}" ;;
    esac
    cat <<EOS
ID                        $alloc
Name                      fake.agents[0]
Task States
Task: agents
  State:           running
  Exit Code:      1
  Total Restarts:  $n
EOS
    ;;
  *)
    exit 2 ;;
esac
EOF
chmod +x "$TMP/nomad"

# run_walk — one walk interval: run the gate against the fake Nomad with
# temp state/queue dirs.
run_walk() {
  PATH="$TMP:$PATH" \
  WALK_STATE_DIR="$TMP/state" \
  WALK_QUEUE_DIR="$TMP/queue" \
  NOMAD_BIN=nomad \
    bash "$GATE"
}

# queue_count — number of walk-queue item files so far.
queue_count() {
  if [ -d "$TMP/queue" ]; then
    find "$TMP/queue" -maxdepth 1 -type f | wc -l | tr -d '[:space:]'
  else
    printf '0'
  fi
}

# ── 1. First walk: baseline, nothing paged ──────────────────────────────────
export FAKE_RESTARTS_DEV=0 FAKE_RESTARTS_REVIEW=0
run_walk
ac_assert_eq "$(queue_count)" "0" \
  "first walk (baseline) must page nothing"
[ -f "$TMP/state/agents-dev-qwen.restarts" ] \
  || ac_fail "state file for agents-dev-qwen not written to WALK_STATE_DIR"
[ -f "$TMP/state/agents-review-qwen.restarts" ] \
  || ac_fail "state file for agents-review-qwen not written to WALK_STATE_DIR"
grep -q '^alloc=' "$TMP/state/agents-dev-qwen.restarts" \
  || ac_fail "state file must record the alloc id"
grep -q '^restarts=' "$TMP/state/agents-dev-qwen.restarts" \
  || ac_fail "state file must record the restart count"

# ── 2. +1 restart since the previous walk: below threshold ─────────────────
FAKE_RESTARTS_DEV=1
run_walk
ac_assert_eq "$(queue_count)" "0" \
  "a single restart between walks must not page (threshold is 2)"

# ── 3. +2 restarts since the previous walk: page ───────────────────────────
FAKE_RESTARTS_DEV=3
run_walk
ac_assert_eq "$(queue_count)" "1" \
  "a double restart between walks must page exactly one walk-queue item"
item="$(find "$TMP/queue" -maxdepth 1 -type f | head -n 1)"
[ -n "$item" ] || ac_fail "no walk-queue item file found after double restart"
grep -q 'agents-dev-qwen' "$item" \
  || ac_fail "walk-queue item must name the job (agents-dev-qwen)"
grep -q 'delta +2' "$item" \
  || ac_fail "walk-queue item must record the restart delta (+2)"
grep -q 'restarts: 3 (previous walk: 1' "$item" \
  || ac_fail "walk-queue item must record current and previous restart counts"

# ── 4. Quiet period: same counters, next walk pages nothing new ────────────
run_walk
ac_assert_eq "$(queue_count)" "1" \
  "a quiet period (no new restarts) must page nothing"

# ── 5. Alloc replaced (redeploy): counter resets, no false page ───────────
FAKE_RESTARTS_DEV=0
export FAKE_ALLOC_DEV=cccccccccccccccccccccccccccccccc
run_walk
ac_assert_eq "$(queue_count)" "1" \
  "an alloc replacement (counter resets to 0) must re-baseline, not page"
grep -q '^alloc=cccccccccccccccccccccccccccccccc' \
  "$TMP/state/agents-dev-qwen.restarts" \
  || ac_fail "state must re-baseline on the new alloc id"

# ── 6. Crash-loop continues on the new alloc: pages again ──────────────────
FAKE_RESTARTS_DEV=2
run_walk
ac_assert_eq "$(queue_count)" "2" \
  "restarts on the new alloc must page again once they hit the threshold"
grep -q "alloc:    cccccccccccccccccccccccccccccccc" "$TMP/queue"/* \
  || ac_fail "second walk-queue item must reference the new alloc id"

ac_pass
