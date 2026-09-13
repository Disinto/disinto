#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1321.sh
#
# Issue #1321: hire-an-agent refuses a second local model when kind=research.
#
# An 8 GiB research box fits one local-model agent job alongside Forgejo/CI;
# a second placement OOMs the box. When the project TOML's top-level `kind`
# is research (absent kind = software), disinto_hire_an_agent must count the
# bot-* Nomad jobs this script deploys that have running allocations and,
# with one or more already placed, exit non-zero with a one-line error —
# before any side effect. Software projects (absent or explicit kind) are
# unchanged: a second hire is not refused.
#
# Verifies (all checks read-only — no forge mutation, no job dispatch):
#   1. The stock dogfood jobs keep their memory requests:
#      nomad/jobs/agents-dev-qwen.hcl and agents-review-qwen.hcl still
#      request 2048 MiB (dogfood stays 2048).
#   2. The generated hire jobspec in lib/hire-agent.sh still requests
#      1024 MiB.
#   3. Behaviour with a stubbed nomad CLI in a throwaway subshell (Forge
#      token unset, so a hire the gate lets through dies at the pre-existing
#      FORGE_TOKEN check — proving the gate passed with zero side effects):
#      a. kind=research + one running bot-* job  -> refused, one-line error
#      b. kind=research + zero running bot-* jobs -> gate passes
#      c. absent kind (default software) + one running job -> gate passes
#      d. kind=research + only a stock agents-* job -> gate passes
#   4. Live probe (informational, never fails): the real read-only
#      disinto_count_local_model_jobs() against this box's Nomad cluster,
#      when the nomad CLI is present.
#
# Run via: tools/run-acceptance.sh 1321
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash python3 awk grep

HIRE_LIB="$REPO_ROOT/lib/hire-agent.sh"
ac_assert_file "$HIRE_LIB" "lib/hire-agent.sh is missing"

# ── 1+2. Memory requests untouched (dogfood stays 2048, generated stays 1024)
ac_assert_file "$REPO_ROOT/nomad/jobs/agents-dev-qwen.hcl" "nomad/jobs/agents-dev-qwen.hcl is missing"
ac_assert_file "$REPO_ROOT/nomad/jobs/agents-review-qwen.hcl" "nomad/jobs/agents-review-qwen.hcl is missing"
grep -q 'memory = 2048' "$REPO_ROOT/nomad/jobs/agents-dev-qwen.hcl" \
  || ac_fail "nomad/jobs/agents-dev-qwen.hcl no longer requests 2048 MiB"
grep -q 'memory = 2048' "$REPO_ROOT/nomad/jobs/agents-review-qwen.hcl" \
  || ac_fail "nomad/jobs/agents-review-qwen.hcl no longer requests 2048 MiB"
grep -q 'memory = 1024' "$HIRE_LIB" \
  || ac_fail "generated hire jobspec no longer requests 1024 MiB"
ac_log "memory: dogfood HCL still 2048, generated jobspec still 1024"

# ── 3. Gate behaviour (stubbed nomad, temp FACTORY_ROOT, no forge) ─────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/factory/projects" "$TMP/factory/formulas"
touch "$TMP/factory/formulas/dev.toml"

# Stub nomad: `job list` prints the inventory file (one job ID per line, as
# the real CLI's ID column would), `alloc list <job> -status=running -json`
# prints one allocation for jobs in the running set, else [].
cat > "$TMP/bin/nomad" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "job list")
    if [ -n "${NOMAD_INVENTORY:-}" ] && [ -f "${NOMAD_INVENTORY:-}" ]; then
      cat "$NOMAD_INVENTORY"
    fi
    exit 0
    ;;
  "alloc list")
    job="${3:-}"
    if [ -n "${NOMAD_RUNNING:-}" ] && grep -qx "$job" "${NOMAD_RUNNING:-}" 2>/dev/null; then
      printf '[{"ID":"stub-alloc","JobID":"%s","Status":"running"}]\n' "$job"
    else
      echo "[]"
    fi
    exit 0
    ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/nomad"

# Write the project TOML. $1 = "" (no kind key) | research | software.
write_toml() {
  {
    echo 'name = "lab"'
    if [ -n "$1" ]; then
      printf 'kind = "%s"\n' "$1"
    fi
  } > "$TMP/factory/projects/lab.toml"
}

# run_hire <kind> <inventory: space-separated job IDs> <running: job IDs>
# Runs the real disinto_hire_an_agent in a hermetic subshell: stub nomad on
# PATH, temp FACTORY_ROOT, Forge token unset (so a gate pass-through dies at
# the pre-existing FORGE_TOKEN check, before any side effect). Sets HIRE_RC
# and HIRE_OUT (combined stdout+stderr).
run_hire() {
  local kind="$1" inventory="$2" running="$3"
  if [ -n "$inventory" ]; then
    # shellcheck disable=SC2086  # intentional word-splitting
    printf '%s\n' $inventory > "$TMP/inventory"
  else
    : > "$TMP/inventory"
  fi
  if [ -n "$running" ]; then
    # shellcheck disable=SC2086  # intentional word-splitting
    printf '%s\n' $running > "$TMP/running"
  else
    : > "$TMP/running"
  fi
  write_toml "$kind"
  HIRE_RC=0
  HIRE_OUT="$(
    export PATH="$TMP/bin:$PATH"
    export NOMAD_INVENTORY="$TMP/inventory"
    export NOMAD_RUNNING="$TMP/running"
    export FACTORY_ROOT="$TMP/factory"
    export PROJECT_NAME="lab"
    export FACTORY_PROJECTS_DIR="$TMP/factory/projects"
    unset FORGE_TOKEN FORGE_ADMIN_PAT
    # shellcheck source=/dev/null
    source "$HIRE_LIB"
    disinto_hire_an_agent tmpbot dev --local-model "http://127.0.0.1:8080" 2>&1
  )" || HIRE_RC=$?
}

# 3a. kind=research + one running local-model job -> refused, one-line error.
run_hire research "bot-dev-qwen" "bot-dev-qwen"
[ "$HIRE_RC" -ne 0 ] \
  || ac_fail "research kind, 1 running local-model job: hire did not exit non-zero"
grep -q "research kind allows one local-model agent" <<< "$HIRE_OUT" \
  || ac_fail "research kind, 1 running local-model job: missing one-line refusal (got: $HIRE_OUT)"
ac_log "gate: research kind + 1 running local-model job -> refused"

# 3b. kind=research + zero running local-model jobs -> gate passes.
run_hire research "" ""
[ "$HIRE_RC" -ne 0 ] || ac_fail "research kind, 0 running jobs: hire unexpectedly succeeded"
grep -q "FORGE_TOKEN not set" <<< "$HIRE_OUT" \
  || ac_fail "research kind, 0 running jobs: hire did not proceed past the gate"
ac_log "gate: research kind + 0 running local-model jobs -> proceeds"

# 3c. absent kind (default software) + one running job -> gate passes.
run_hire "" "bot-dev-qwen" "bot-dev-qwen"
[ "$HIRE_RC" -ne 0 ] || ac_fail "absent kind: hire unexpectedly succeeded"
grep -q "FORGE_TOKEN not set" <<< "$HIRE_OUT" \
  || ac_fail "absent kind: second local-model hire was refused by the research gate"
ac_log "gate: absent kind (software default) + 1 running job -> proceeds"

# 3d. kind=research + only a stock agents-* job running -> gate passes
# (stock dogfood jobs are not created by this script and must not count).
run_hire research "agents-dev-qwen" "agents-dev-qwen"
[ "$HIRE_RC" -ne 0 ] || ac_fail "research kind, stock job only: hire unexpectedly succeeded"
grep -q "FORGE_TOKEN not set" <<< "$HIRE_OUT" \
  || ac_fail "research kind: stock agents-* job was counted as a local-model hire job"
ac_log "gate: research kind + stock agents-* job only -> proceeds"

# ── 4. Live probe (informational only — read-only nomad status queries) ─────
# shellcheck source=/dev/null
source "$HIRE_LIB"
if command -v nomad >/dev/null 2>&1; then
  LIVE_COUNT="$(disinto_count_local_model_jobs 2>/dev/null || echo 0)"
  ac_log "live box: ${LIVE_COUNT} running local-model (bot-*) Nomad job(s)"
else
  ac_log "live box: nomad CLI absent (compose box) — live count skipped"
fi

ac_pass
