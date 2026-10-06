#!/usr/bin/env bash
# sidecar-agent.sh — one agent session for the reproduce/triage/verify
# sidecars: dsh against the local model, with the Playwright MCP server from
# dsh-playwright.patch.yml. Sourced by entrypoint-reproduce.sh.
#
# sidecar_agent_run PROMPT OUT_FILE TIMEOUT_S
#   Runs `dsh --profile headless` once and writes its final answer to OUT_FILE.
#   Returns dsh's exit code (124 = TIMEOUT_S reached). Returns 1 without
#   running anything when DSH_BASE_URL is empty. Needs DISINTO_DIR and LOGFILE.
#   dsh is called directly, not via agent_run: the caller reads the final
#   answer, which agent_run does not return.
sidecar_agent_run() {
  local prompt="$1" out_file="$2" timeout_s="$3" rc=0
  if [ -z "${DSH_BASE_URL:-}" ]; then
    printf 'ERROR: DSH_BASE_URL not set — no agent session ran\n' > "$out_file"
    return 1
  fi
  export LLAMACPP_API_KEY="${LLAMACPP_API_KEY:-sk-no-key-required}"
  export DSH_HOME="${DSH_HOME:-/tmp/dsh-sidecar}"
  # shellcheck source=lib/dsh-seed.sh
  source "${DISINTO_DIR}/lib/dsh-seed.sh"
  dsh_seed_home || return 1
  DSH_PERMISSION_MODE=danger-full-access \
    timeout -k 10 "$timeout_s" \
    dsh --profile headless \
      --patch "${DISINTO_DIR}/docker/reproduce/dsh-playwright.patch.yml" \
      "$prompt" > "$out_file" 2>>"$LOGFILE" || rc=$?
  return "$rc"
}
