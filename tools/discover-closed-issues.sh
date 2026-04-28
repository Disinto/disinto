#!/usr/bin/env bash
# =============================================================================
# tools/discover-closed-issues.sh — extract issue numbers a merge closes.
#
# Reads text from stdin (typically the merge commit message + the closing PR's
# body, concatenated) and emits a JSON array of integer issue numbers that are
# explicitly closed by closing keywords. Used by the post-merge acceptance
# pipeline (.woodpecker/acceptance-tests.yml, #851).
#
# Usage:
#   printf '%s' "$msg" | tools/discover-closed-issues.sh
#
# Output:
#   A single line of JSON: e.g. `[844, 851]` (sorted, de-duplicated). If no
#   closing references are found, emits `[]`.
#
# Recognised closing keywords (case-insensitive):
#   close, closes, closed, fix, fixes, fixed, resolve, resolves, resolved.
# A closing reference is one of those keywords followed by a `#NNN` (with at
# most one space, optional colon, optional repeat-keyword for `Closes: #844`).
# Bare `#NNN` *without* a keyword is NOT considered closing — that's used in
# discussion / context references and would cause every PR to "close" its own
# PR number from a `(#NNN)` merge subject.
#
# The script is deliberately strict about what counts as "closing": false
# positives result in spurious comments + label thrashing on unrelated issues.
# False negatives just mean a closed issue doesn't get a CI comment, which is
# strictly safer (the human fallback still works).
# =============================================================================
set -euo pipefail

# Read all stdin into one buffer.
text="$(cat)"

# Extract closing references. The regex matches:
#   (close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)
#   optional ':' or whitespace
#   '#'
#   one or more digits
# The capture group grabs the digits.
#
# Use perl rather than grep -P to keep the script portable across BSD/GNU
# (Alpine's busybox grep doesn't support -P; perl is in the alpine:3 image
# we install in CI, and on dev boxes it's universally present).
issues="$(printf '%s' "$text" \
  | perl -nle 'while (/(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s*:?\s*#(\d+)/ig) { print $1 }' \
  | sort -un)"

if [ -z "$issues" ]; then
  echo "[]"
  exit 0
fi

# Emit as a JSON array of integers. `-R -s` slurps stdin as a raw string,
# split on newlines, drop blanks, convert each to a number.
printf '%s\n' "$issues" \
  | jq -c -R -s 'split("\n") | map(select(length > 0) | tonumber)'
