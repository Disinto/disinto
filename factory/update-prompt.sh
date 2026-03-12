#!/usr/bin/env bash
# update-prompt.sh — Append a lesson learned to PROMPT.md
#
# Usage:
#   ./factory/update-prompt.sh "### Title" "Body text describing the lesson"
#   ./factory/update-prompt.sh --from-file /tmp/lesson.md
#
# Called by claude -p when it learns something new during a fix.
# Commits and pushes the update to the dark-factory repo.

source "$(dirname "$0")/../lib/env.sh"

PROMPT_FILE="${FACTORY_ROOT}/factory/PROMPT.md"

if [ "$1" = "--from-file" ] && [ -f "$2" ]; then
  LESSON=$(cat "$2")
elif [ -n "$1" ] && [ -n "$2" ]; then
  LESSON="$1
$2"
else
  echo "Usage: update-prompt.sh 'Title' 'Body' OR update-prompt.sh --from-file path" >&2
  exit 1
fi

# Append to PROMPT.md under Best Practices
echo "" >> "$PROMPT_FILE"
echo "$LESSON" >> "$PROMPT_FILE"

cd "$FACTORY_ROOT"
git add factory/PROMPT.md
git commit -m "factory: update supervisor best practices" --no-verify 2>/dev/null
git push origin main 2>/dev/null

log "PROMPT.md updated with new lesson"
