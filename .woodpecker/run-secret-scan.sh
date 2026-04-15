#!/usr/bin/env bash
set -euo pipefail
# run-secret-scan.sh — CI wrapper for lib/secret-scan.sh
#
# Scans files changed in this PR for plaintext secrets.
# Exits non-zero if any secret is detected.

# shellcheck source=../lib/secret-scan.sh
source lib/secret-scan.sh

# Path patterns considered secret-adjacent
SECRET_PATH_PATTERNS=(
  '\.env'
  'tools/vault-.*\.sh'
  'nomad/'
  'vault/'
  'action-vault/'
  'lib/hvault\.sh'
  'lib/action-vault\.sh'
)

# Build a single regex from patterns
path_regex=$(printf '%s|' "${SECRET_PATH_PATTERNS[@]}")
path_regex="${path_regex%|}"

# Get files changed in this PR vs target branch
changed_files=$(git diff --name-only --diff-filter=ACMR "origin/${CI_COMMIT_TARGET_BRANCH}...HEAD" || true)

if [ -z "$changed_files" ]; then
  echo "secret-scan: no changed files found, skipping"
  exit 0
fi

# Filter to secret-adjacent paths only
target_files=$(printf '%s\n' "$changed_files" | grep -E "$path_regex" || true)

if [ -z "$target_files" ]; then
  echo "secret-scan: no secret-adjacent files changed, skipping"
  exit 0
fi

echo "secret-scan: scanning $(printf '%s\n' "$target_files" | wc -l) file(s):"
printf '  %s\n' "$target_files"

failures=0
while IFS= read -r file; do
  # Skip deleted files / non-existent
  [ -f "$file" ] || continue
  # Skip binary files
  file -b --mime-encoding "$file" 2>/dev/null | grep -q binary && continue

  content=$(cat "$file")
  if ! scan_for_secrets "$content"; then
    echo "FAIL: secret detected in $file"
    failures=$((failures + 1))
  fi
done <<< "$target_files"

if [ "$failures" -gt 0 ]; then
  echo ""
  echo "secret-scan: $failures file(s) contain potential secrets — merge blocked"
  echo "If these are false positives, verify patterns in lib/secret-scan.sh"
  exit 1
fi

echo "secret-scan: all files clean"
