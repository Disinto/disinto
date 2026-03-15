#!/usr/bin/env bash
# update-prompt.sh — Append a lesson to a best-practices file
#
# Usage:
#   ./factory/update-prompt.sh "best-practices/memory.md" "### Title\nBody text"
#   ./factory/update-prompt.sh --from-file "best-practices/memory.md" /tmp/lesson.md
#
# Called by claude -p when it learns something during a fix.
# Commits and pushes the update to the disinto repo.

source "$(dirname "$0")/../lib/env.sh"

TARGET_FILE="${FACTORY_ROOT}/factory/$1"
shift

if [ "$1" = "--from-file" ] && [ -f "$2" ]; then
  LESSON=$(cat "$2")
elif [ -n "$1" ]; then
  LESSON="$1"
else
  echo "Usage: update-prompt.sh <relative-path> '<lesson text>'" >&2
  echo "   or: update-prompt.sh <relative-path> --from-file <path>" >&2
  exit 1
fi

if [ ! -f "$TARGET_FILE" ]; then
  echo "Target file not found: $TARGET_FILE" >&2
  exit 1
fi

# Append under "Lessons Learned" section if it exists, otherwise at end
if grep -q "## Lessons Learned" "$TARGET_FILE"; then
  echo "" >> "$TARGET_FILE"
  echo "$LESSON" >> "$TARGET_FILE"
else
  echo "" >> "$TARGET_FILE"
  echo "## Lessons Learned" >> "$TARGET_FILE"
  echo "" >> "$TARGET_FILE"
  echo "$LESSON" >> "$TARGET_FILE"
fi

cd "$FACTORY_ROOT"
git add "factory/$1" 2>/dev/null || git add "$TARGET_FILE"
git commit -m "factory: learned — $(echo "$LESSON" | head -1 | sed 's/^#* *//')" --no-verify 2>/dev/null
git push origin main 2>/dev/null

log "Updated $(basename "$TARGET_FILE") with new lesson"
