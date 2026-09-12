#!/usr/bin/env bash
# tools/seed-research-labels.sh — idempotently create the v0.6 research-kind
# labels (#1295) on an existing forge: experiment, run, artifact, judgment,
# waiting-on-compute. Colours are distinct from backlog / bug-report / vision
# (single source of truth: RESEARCH_LABELS in lib/forge-setup.sh).
#
# Usage:
#   tools/seed-research-labels.sh [repo_slug]   # seed (default: $FORGE_REPO)
#   tools/seed-research-labels.sh --list        # print the label table, no network
#
# Idempotent: pre-existing labels are never modified (name or color); missing
# ones are created. A second run is a no-op. Used by `disinto init`
# (lib/forge-setup.sh) and by humans seeding an existing forge.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=lib/forge-setup.sh
source "$FACTORY_ROOT/lib/forge-setup.sh"

if [ "${1:-}" = "--list" ]; then
  # Print "name color" lines — no network, no env beyond forge-setup.sh.
  # Used by tests/acceptance/issue-1295.sh.
  for _entry in "${RESEARCH_LABELS[@]}"; do
    echo "${_entry%%:*} ${_entry##*:}"
  done
  exit 0
fi

# shellcheck source=lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"

seed_research_labels "${1:-${FORGE_REPO:-}}"
