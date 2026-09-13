#!/usr/bin/env bats
# =============================================================================
# tests/hire-an-agent-research.bats — research kind allows one local-model
# agent (#1321)
#
# An 8 GiB research box fits one local-model agent job alongside Forgejo/CI;
# a second placement OOMs the box. hire-an-agent must refuse a second
# local-model hire when the project TOML's kind is research, with no side
# effects, while software (absent or explicit) stays unchanged.
#
# The gate lives in disinto_hire_an_agent() (before any Forge mutation), so
# the tests drive the full command in a subshell with FORGE_TOKEN unset:
# a refused hire must exit non-zero with the one-line research error, and a
# hire the gate lets through must die at the pre-existing FORGE_TOKEN check
# — which is what proves the gate passed without creating anything. The
# nomad CLI is stubbed: `job list` reports the inventory, `alloc list`
# reports a running allocation only for jobs in the running set.
# =============================================================================

setup_file() {
  export DISINTO_ROOT
  DISINTO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export HIRE_LIB="${DISINTO_ROOT}/lib/hire-agent.sh"
  [ -f "$HIRE_LIB" ] || {
    echo "hire-agent.sh not found: $HIRE_LIB" >&2
    return 1
  }
}

setup() {
  TMP="$(mktemp -d)"
  export TMP
  mkdir -p "$TMP/bin" "$TMP/factory/projects" "$TMP/factory/formulas"
  export FACTORY_ROOT="$TMP/factory"
  export PROJECT_NAME="lab"
  export FACTORY_PROJECTS_DIR="$TMP/factory/projects"
  touch "$TMP/factory/formulas/dev.toml"

  # The gate must never see a Forge credential: pass-through cases die at
  # the pre-existing FORGE_TOKEN check, refusal cases die before it.
  unset FORGE_TOKEN

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
  export PATH="$TMP/bin:$PATH"
  export NOMAD_INVENTORY="$TMP/inventory"
  export NOMAD_RUNNING="$TMP/running"
  : > "$NOMAD_INVENTORY"
  : > "$NOMAD_RUNNING"
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

# Write the project TOML. $1 = "" (no kind key) | research | software.
_write_kind_toml() {
  {
    echo 'name = "lab"'
    if [ -n "$1" ]; then
      printf 'kind = "%s"\n' "$1"
    fi
  } > "$TMP/factory/projects/lab.toml"
}

# Add a job to the inventory; $2 = "running" | "stopped".
_place_job() {
  echo "$1" >> "$NOMAD_INVENTORY"
  if [ "$2" = "running" ]; then
    echo "$1" >> "$NOMAD_RUNNING"
  fi
}

# Invoke the real disinto_hire_an_agent in a subshell so its `exit` cannot
# kill the test. Captures rc in $TMP/rc and combined output in $TMP/out.
_hire() {
  local rc=0
  (
    set +e
    # shellcheck source=/dev/null
    source "$HIRE_LIB" 2>/dev/null
    disinto_hire_an_agent tmpbot dev --local-model "http://127.0.0.1:8080"
  ) > "$TMP/out" 2>&1 || rc=$?
  echo "$rc" > "$TMP/rc"
  return 0
}

# ── refusal ─────────────────────────────────────────────────────────────────

@test "research kind refuses a second local-model hire" {
  _write_kind_toml research
  _place_job bot-dev-qwen running
  _hire
  [ "$(cat "$TMP/rc")" != "0" ]
  grep -q "research kind allows one local-model agent" "$TMP/out"
}

@test "research kind refusal is a single-line error and precedes any side effect" {
  _write_kind_toml research
  _place_job bot-dev-qwen running
  _hire
  # The one-line error is the only stderr line: the run never reached the
  # "Hiring agent" banner, let alone the Forge mutations.
  local err_lines
  err_lines="$(grep -c . "$TMP/out" || true)"
  [ "$err_lines" = "1" ]
  ! grep -q "Hiring agent" "$TMP/out"
  # And the gate wrote no agent section into the project TOML.
  ! grep -q "agents.tmpbot" "$TMP/factory/projects/lab.toml"
}

# ── pass-through (gate lets the hire proceed) ───────────────────────────────

@test "research kind allows the first local-model hire (zero placed jobs)" {
  _write_kind_toml research
  _hire
  [ "$(cat "$TMP/rc")" != "0" ]
  ! grep -q "research kind allows one local-model agent" "$TMP/out"
  # Proceeded past the gate to the pre-existing FORGE_TOKEN check.
  grep -q "FORGE_TOKEN not set" "$TMP/out"
}

@test "research kind: a placed job without running allocations does not block" {
  _write_kind_toml research
  _place_job bot-dev-qwen stopped
  _hire
  grep -q "FORGE_TOKEN not set" "$TMP/out"
}

@test "absent kind (default software) allows a second hire" {
  _write_kind_toml ""
  _place_job bot-dev-qwen running
  _hire
  grep -q "FORGE_TOKEN not set" "$TMP/out"
}

@test "explicit software kind allows a second hire" {
  _write_kind_toml software
  _place_job bot-dev-qwen running
  _hire
  grep -q "FORGE_TOKEN not set" "$TMP/out"
}

@test "stock agents-* jobs are not counted as hire-deployed jobs" {
  _write_kind_toml research
  _place_job agents-dev-qwen running
  _hire
  grep -q "FORGE_TOKEN not set" "$TMP/out"
}

# ── count helper ─────────────────────────────────────────────────────────────

@test "disinto_count_local_model_jobs counts only running bot-* jobs" {
  _place_job bot-dev-qwen running
  _place_job bot-review-qwen running
  _place_job agents-dev-qwen running
  _place_job bot-gardener-qwen stopped
  local count
  count="$(
    set +e
    # shellcheck source=/dev/null
    source "$HIRE_LIB" 2>/dev/null
    disinto_count_local_model_jobs
  )"
  [ "$count" = "2" ]
}

@test "disinto_count_local_model_jobs is 0 without the nomad CLI (compose box)" {
  _place_job bot-dev-qwen running
  local count
  count="$(
    set +e
    # shellcheck source=/dev/null
    source "$HIRE_LIB" 2>/dev/null
    PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v "^$TMP/bin$" | paste -sd: -)" \
      disinto_count_local_model_jobs
  )"
  [ "$count" = "0" ]
}
