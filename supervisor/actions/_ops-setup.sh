#!/usr/bin/env bash
# supervisor/actions/_ops-setup.sh — OPS repo environment setup
#
# Sets up OPS_* variables for journal/vault/knowledge roots.
# Handles both full ops-repo and degraded (local) modes.
#
# Usage:
#   source "$SCRIPT_DIR/_common.sh"   # must be sourced first
#   source "$SCRIPT_DIR/_ops-setup.sh"  # then this

# ── OPS Repo Detection (mirrors supervisor-run.sh) ─────────────────────
if [ -z "${OPS_REPO_ROOT:-}" ] || [ ! -d "${OPS_REPO_ROOT}" ]; then
  export OPS_REPO_DEGRADED=1
  export OPS_KNOWLEDGE_ROOT="${FACTORY_ROOT}/knowledge"
  export OPS_JOURNAL_ROOT="${FACTORY_ROOT}/state/supervisor-journal"
  export OPS_VAULT_ROOT="${PROJECT_REPO_ROOT}/vault/pending"
  mkdir -p "$OPS_JOURNAL_ROOT" "$OPS_VAULT_ROOT" 2>/dev/null || true
else
  export OPS_REPO_DEGRADED=0
  export OPS_KNOWLEDGE_ROOT="${OPS_REPO_ROOT}/knowledge"
  export OPS_JOURNAL_ROOT="${OPS_REPO_ROOT}/journal/supervisor"
  export OPS_VAULT_ROOT="${OPS_REPO_ROOT}/vault/pending"
  mkdir -p "$OPS_JOURNAL_ROOT" "$OPS_VAULT_ROOT" 2>/dev/null || true
fi
