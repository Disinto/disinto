#!/usr/bin/env bash
# classify.sh — Blast-radius classification engine
#
# Reads the ops-repo policy.toml and prints the tier for a given formula.
# An optional blast_radius override (from the action TOML) takes precedence.
#
# Usage: classify.sh <formula-name> [blast_radius_override]
# Output: prints "low", "medium", or "high" to stdout; exits 0
#
# Source lib/env.sh directly (not vault-env.sh) to avoid circular dependency:
# vault-env.sh calls classify.sh, so classify.sh must not source vault-env.sh.
# The only variable needed here is OPS_REPO_ROOT, which comes from lib/env.sh.
# shellcheck source=../lib/env.sh
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

formula="${1:-}"
override="${2:-}"

if [ -z "$formula" ]; then
  echo "Usage: classify.sh <formula-name> [blast_radius_override]" >&2
  exit 1
fi

# If the action TOML provides a blast_radius override, use it directly
if [[ "$override" =~ ^(low|medium|high)$ ]]; then
  echo "$override"
  exit 0
fi

# Read tier from ops-repo policy.toml
policy_file="${OPS_REPO_ROOT}/vault/policy.toml"

if [ -f "$policy_file" ]; then
  # Parse: look for `formula_name = "tier"` under [tiers]
  # Escape regex metacharacters in formula name for safe grep
  escaped_formula=$(printf '%s' "$formula" | sed 's/[].[*^$\\]/\\&/g')
  tier=$(sed -n '/^\[tiers\]/,/^\[/{/^\[tiers\]/d;/^\[/d;p}' "$policy_file" \
    | grep -E "^${escaped_formula}[[:space:]]*=" \
    | sed -E 's/^[^=]+=[[:space:]]*"([^"]+)".*/\1/' \
    | head -n1)

  if [[ "$tier" =~ ^(low|medium|high)$ ]]; then
    echo "$tier"
    exit 0
  fi
fi

# Default-deny: unknown formulas are high
echo "high"
exit 0
