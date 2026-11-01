#!/usr/bin/env bash
# served-model.sh — the model id the local model server reports (#2013)
#
# The local llama.cpp server ignores the model name in the request, so
# CLAUDE_MODEL can name a model that no longer runs. Both the proposal-loop
# tape (formula_tape_agent, #2012) and dev-poll's proposal context (#2014)
# need the id the server itself reports at GET $DSH_BASE_URL/models — this
# is the single home for that lookup.
#
# Requires: curl, jq.
#
# served_model_id
#   When ${AGENT_HARNESS:-dsh} is dsh, ${DSH_PROVIDER:-llamacpp} is
#   llamacpp, and DSH_BASE_URL is non-empty: print the first id of
#   curl -sf -m 5 "${DSH_BASE_URL%/}/models" (jq -r '.data[0].id // empty').
#   Otherwise, or on any curl/jq failure: print nothing. Always returns 0.

set -euo pipefail

# served_model_id — see the file header.
served_model_id() {
  local served=""
  if [ "${AGENT_HARNESS:-dsh}" = dsh ] \
    && [ "${DSH_PROVIDER:-llamacpp}" = llamacpp ] \
    && [ -n "${DSH_BASE_URL:-}" ]; then
    served=$(curl -sf -m 5 "${DSH_BASE_URL%/}/models" 2>/dev/null \
      | jq -r '.data[0].id // empty' 2>/dev/null) || served=""
  fi
  if [ -n "$served" ]; then
    printf '%s\n' "$served"
  fi
  return 0
}
