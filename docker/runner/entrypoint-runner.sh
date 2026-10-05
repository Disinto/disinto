#!/usr/bin/env bash
# entrypoint-runner.sh — Vault runner entrypoint
#
# Receives an action-id, reads the vault action TOML to get the formula name,
# then dispatches to the appropriate executor:
#   - formulas/<name>.sh  → bash (mechanical operations like release)
#   - formulas/<name>.toml → agent_run, dsh harness (lib/agent-sdk.sh; needs DSH_BASE_URL)
#
# Usage: entrypoint-runner.sh <action-id>
#
# Expects:
#   OPS_REPO_ROOT  — path to the ops repo (mounted by compose)
#   FACTORY_ROOT   — path to disinto code (default: /home/agent/disinto)
#
# Part of #516.

set -euo pipefail

FACTORY_ROOT="${FACTORY_ROOT:-/home/agent/disinto}"
OPS_REPO_ROOT="${OPS_REPO_ROOT:-/home/agent/ops}"

# Vault-held SSH keys (file secrets under /secrets/ssh/) — before any formula
# that might ssh. No-op when SSH_KEY was not declared for this action.
if [ -f "${FACTORY_ROOT}/lib/vault-ssh.sh" ]; then
  # shellcheck source=lib/vault-ssh.sh
  source "${FACTORY_ROOT}/lib/vault-ssh.sh"
  vault_ssh_install "${NOMAD_SECRETS_DIR:-/secrets}" "${HOME:-/home/agent}"
fi

log() {
  printf '[%s] runner: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

# Configure git credential helper so formulas can clone/push without
# needing tokens embedded in remote URLs (#604).
if [ -f "${FACTORY_ROOT}/lib/git-creds.sh" ]; then
  # shellcheck source=lib/git-creds.sh
  source "${FACTORY_ROOT}/lib/git-creds.sh"
  # shellcheck disable=SC2119  # no args intended — uses defaults
  configure_git_creds
fi

# ── Argument parsing ─────────────────────────────────────────────────────

action_id="${1:-}"
if [ -z "$action_id" ]; then
  log "ERROR: action-id argument required"
  echo "Usage: entrypoint-runner.sh <action-id>" >&2
  exit 1
fi

# ── Read vault action TOML ───────────────────────────────────────────────

action_toml="${OPS_REPO_ROOT}/vault/actions/${action_id}.toml"
if [ ! -f "$action_toml" ]; then
  log "ERROR: vault action TOML not found: ${action_toml}"
  exit 1
fi

# Extract formula name from TOML
formula=$(grep -E '^formula\s*=' "$action_toml" \
  | sed -E 's/^formula\s*=\s*"(.*)"/\1/' | tr -d '\r')

if [ -z "$formula" ]; then
  log "ERROR: no 'formula' field found in ${action_toml}"
  exit 1
fi

# Extract context for logging
context=$(grep -E '^context\s*=' "$action_toml" \
  | sed -E 's/^context\s*=\s*"(.*)"/\1/' | tr -d '\r')

log "Action: ${action_id}, formula: ${formula}, context: ${context:-<none>}"

# Export action TOML path so formula scripts can use it directly
export VAULT_ACTION_TOML="$action_toml"

# ── Dispatch: .sh (mechanical) vs .toml (agent_run, dsh) ──────────────

formula_sh="${FACTORY_ROOT}/formulas/${formula}.sh"
formula_toml="${FACTORY_ROOT}/formulas/${formula}.toml"

if [ -f "$formula_sh" ]; then
  # Mechanical operation — run directly
  log "Dispatching to shell script: ${formula_sh}"
  exec bash "$formula_sh" "$action_id"

elif [ -f "$formula_toml" ]; then
  # Reasoning task — run the formula as a prompt through agent_run (dsh)
  if [ -z "${DSH_BASE_URL:-}" ]; then
    log "ERROR: DSH_BASE_URL not set — cannot run formula ${formula}"
    exit 1
  fi

  log "Dispatching to agent_run (dsh) with formula: ${formula_toml}"

  # The runner uses only dsh, whatever AGENT_HARNESS says. The agents image
  # bakes the seed at /opt/dsh, but this entrypoint is bash (not
  # docker/agents/entrypoint.sh), so DSH_HOME is seeded here.
  export AGENT_HARNESS=dsh
  export LLAMACPP_API_KEY="${LLAMACPP_API_KEY:-sk-no-key-required}"
  export DSH_HOME="${DSH_HOME:-/tmp/dsh-runner}"

  seed="${DSH_SEED_DIR:-/opt/dsh}"
  if [ ! -f "$DSH_HOME/profiles/headless.json" ]; then
    mkdir -p "$DSH_HOME/profiles"
    cp "$seed/profiles/headless.json" "$DSH_HOME/profiles/headless.json"
  fi
  if [ ! -f "$DSH_HOME/settings.yaml" ]; then
    mkdir -p "$DSH_HOME"
    sed "s|__DSH_BASE_URL__|${DSH_BASE_URL}|" \
      "$seed/settings-llamacpp.yaml" > "$DSH_HOME/settings.yaml"
  fi

  # Consumed by agent_run (lib/agent-sdk.sh); this script does not read them.
  # shellcheck disable=SC2034
  LOGFILE=/dev/stderr
  # shellcheck disable=SC2034
  SID_FILE="/tmp/vault-runner-${action_id}.sid"
  # shellcheck disable=SC2034
  LOG_AGENT=vault-runner
  # shellcheck source=lib/agent-sdk.sh
  source "${FACTORY_ROOT}/lib/agent-sdk.sh"

  formula_content=$(cat "$formula_toml")
  action_context=$(cat "$action_toml")

  prompt="You are a vault runner executing a formula-based operational task.

## Vault action
\`\`\`toml
${action_context}
\`\`\`

## Formula
\`\`\`toml
${formula_content}
\`\`\`

## Instructions
Execute the steps defined in the formula above. The vault action context provides
the specific parameters for this run. Execute each step in order, verifying
success before proceeding to the next.

FACTORY_ROOT=${FACTORY_ROOT}
OPS_REPO_ROOT=${OPS_REPO_ROOT}
"

  rc=0
  agent_run "$prompt" || rc=$?
  if [ -n "${_AGENT_LAST_OUTPUT:-}" ]; then
    printf '%s\n' "$_AGENT_LAST_OUTPUT"
  fi
  exit "$rc"

else
  log "ERROR: no formula found for '${formula}' — checked ${formula_sh} and ${formula_toml}"
  exit 1
fi
