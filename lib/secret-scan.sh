#!/usr/bin/env bash
# secret-scan.sh — Detect secrets in text before it reaches issue bodies or comments
#
# Usage: source this file, then call scan_for_secrets.
#
# scan_for_secrets <text>
#   Returns: 0 = clean, 1 = secrets detected
#   Outputs: matched patterns to stderr (for logging)
#
# redact_secrets <text>
#   Outputs: text with detected secrets replaced by [REDACTED]

# Patterns that indicate embedded secrets (extended regex)
_SECRET_PATTERNS=(
  # Long hex strings (API keys, tokens): 32+ hex chars as a standalone token
  '[0-9a-fA-F]{32,}'
  # Bearer/token auth headers with actual values
  'Bearer [A-Za-z0-9_/+=-]{20,}'
  # Private keys (0x-prefixed 64+ hex)
  '0x[0-9a-fA-F]{64}'
  # URLs with embedded credentials (user:pass@host or api-key in path)
  'https?://[^[:space:]]*[0-9a-fA-F]{20,}'
  # AWS-style keys
  'AKIA[0-9A-Z]{16}'
  # Generic secret assignment patterns (KEY=<long value>)
  '(API_KEY|SECRET|TOKEN|PRIVATE_KEY|PASSWORD|INFURA|ALCHEMY)=[^[:space:]"]{16,}'
)

# Known safe patterns to exclude (env var references, not actual values)
_SAFE_PATTERNS=(
  # Shell variable references: $VAR, ${VAR}, ${VAR:-default}
  '\$\{?[A-Z_]+\}?'
  # Git SHAs in typical git contexts (commit refs, not standalone secrets)
  'commit [0-9a-f]{40}'
  'Merge [0-9a-f]{40}'
  # Codeberg/GitHub URLs with short hex (PR refs, commit links)
  'codeberg\.org/[^[:space:]]+'
  # ShellCheck directive codes
  'SC[0-9]{4}'
)

# scan_for_secrets — check text for potential secrets
# Args: text (via stdin or $1)
# Returns: 0 = clean, 1 = secrets found
# Outputs: matched patterns to stderr
scan_for_secrets() {
  local text="${1:-$(cat)}"
  local found=0

  # Strip known safe patterns before scanning
  local cleaned="$text"
  for safe in "${_SAFE_PATTERNS[@]}"; do
    cleaned=$(printf '%s' "$cleaned" | sed -E "s/${safe}/__SAFE__/g" 2>/dev/null || printf '%s' "$cleaned")
  done

  for pattern in "${_SECRET_PATTERNS[@]}"; do
    local matches
    matches=$(printf '%s' "$cleaned" | grep -oE "$pattern" 2>/dev/null || true)
    if [ -n "$matches" ]; then
      # Filter out short matches that are likely false positives (git SHAs in safe context)
      while IFS= read -r match; do
        # Skip if match is entirely the word __SAFE__ (already excluded)
        [ "$match" = "__SAFE__" ] && continue
        # Skip empty
        [ -z "$match" ] && continue
        printf 'secret-scan: detected potential secret matching pattern [%s]: %s\n' \
          "$pattern" "${match:0:8}...${match: -4}" >&2
        found=1
      done <<< "$matches"
    fi
  done

  return $found
}

# redact_secrets — replace detected secrets with [REDACTED]
# Args: text (via stdin or $1)
# Outputs: sanitized text
redact_secrets() {
  local text="${1:-$(cat)}"

  # Replace long hex strings (32+ chars) not preceded by $ (env var refs)
  text=$(printf '%s' "$text" | sed -E 's/([^$]|^)([0-9a-fA-F]{32,})/\1[REDACTED]/g')

  # Replace URLs with embedded long hex
  text=$(printf '%s' "$text" | sed -E 's|(https?://[^[:space:]]*)[0-9a-fA-F]{20,}|\1[REDACTED]|g')

  # Replace secret assignments (KEY=value)
  text=$(printf '%s' "$text" | sed -E 's/((API_KEY|SECRET|TOKEN|PRIVATE_KEY|PASSWORD|INFURA|ALCHEMY)=)[^[:space:]"]{16,}/\1[REDACTED]/g')

  # Replace Bearer tokens
  text=$(printf '%s' "$text" | sed -E 's/(Bearer )[A-Za-z0-9_/+=-]{20,}/\1[REDACTED]/g')

  printf '%s' "$text"
}
