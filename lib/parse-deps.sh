#!/usr/bin/env bash
set -euo pipefail
# parse-deps.sh — Extract dependency issue numbers from an issue body
#
# Usage:
#   echo "$ISSUE_BODY" | bash lib/parse-deps.sh
#
# Output: one dep number per line, sorted and deduplicated
#
# Matches:
#   - Sections: ## Dependencies / ## Depends on / ## Blocked by
#   - Inline: "depends on #NNN" / "blocked by #NNN" anywhere
#   - Ignores: ## Related (safe for sibling cross-references)

BODY=$(cat)

{
  # Extract #NNN from dependency sections
  echo "$BODY" | awk '
    BEGIN { IGNORECASE=1 }
    /^##? *(Depends on|Blocked by|Dependencies)/ { capture=1; next }
    capture && /^##? / { capture=0 }
    capture { print }
  ' | grep -oP '#\K[0-9]+' || true

  # Also check inline deps on same line as keyword
  echo "$BODY" | grep -iE '(depends on|blocked by)' | grep -oP '#\K[0-9]+' || true
} | sort -un
