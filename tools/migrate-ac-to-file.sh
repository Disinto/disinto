#!/usr/bin/env bash
# =============================================================================
# tools/migrate-ac-to-file.sh — migrate inline AC commands to test files
#
# Usage: tools/migrate-ac-to-file.sh <issue-number>
#
# For each issue:
#   1. Fetch the issue body from Forge API.
#   2. Extract the `## Acceptance test` section (shell commands).
#   3. Generate tests/acceptance/issue-<N>.sh from the extracted commands.
#   4. PATCH the issue body to replace the section with a file reference.
#
# Idempotent: skips if the test file already exists.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Usage ────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
Usage: $0 <issue-number> [--yes|-y]

Migrates inline acceptance-test commands from an issue body into a
tests/acceptance/issue-<N>.sh file, then PATCHes the issue body to reference
the file path instead.

Idempotent: skips if the test file already exists.

Flags:
  --yes, -y     skip the PATCH confirmation prompt (useful for automation)

Requires: FORGE_TOKEN, FORGE_API (from lib/env.sh).
EOF
}

# ── Pre-flight ───────────────────────────────────────────────────────────────

if [ $# -lt 1 ]; then
  usage >&2
  exit 2
fi

# ── Parse flags ──────────────────────────────────────────────────────────────

YES=false
for arg in "$@"; do
  case "$arg" in
    --yes|-y) YES=true ;;
  esac
done

ISSUE_NUM="$1"

# Resolve env.sh (must be sourced for FORGE_TOKEN / FORGE_API).
# shellcheck source=lib/env.sh
source "$REPO_ROOT/lib/env.sh"

TEST_FILE="$REPO_ROOT/tests/acceptance/issue-${ISSUE_NUM}.sh"

# Idempotent guard: skip if test file already exists.
if [ -f "$TEST_FILE" ]; then
  echo "SKIP: test file already exists: $TEST_FILE"
  exit 0
fi

# ── Fetch issue body ─────────────────────────────────────────────────────────

echo "Fetching issue #${ISSUE_NUM} ..."
ISSUE_JSON=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
  "${FORGE_API}/issues/${ISSUE_NUM}") || {
  echo "FAIL: could not fetch issue #${ISSUE_NUM}" >&2
  exit 1
}

ISSUE_BODY=$(printf '%s' "$ISSUE_JSON" | jq -r '.body // ""')
ISSUE_TITLE=$(printf '%s' "$ISSUE_JSON" | jq -r '.title // ""')

# ── Extract Acceptance test section ──────────────────────────────────────────

# Extract everything between "## Acceptance test" and the next "## " header or EOF.
# Uses awk for reliable multi-line extraction.
AC_SECTION=$(printf '%s\n' "$ISSUE_BODY" | awk '
  /^## Acceptance test$/ { found=1; next }
  found && /^## / { exit }
  found { print }
')

if [ -z "$AC_SECTION" ]; then
  echo "WARN: no ## Acceptance test section found in issue #${ISSUE_NUM}" >&2
  echo "Nothing to migrate."
  exit 0
fi

# ── Generate test file ───────────────────────────────────────────────────────

# Convert each shell command line into an ac_log + check block.
# Lines that are empty or comments are skipped.
generate_test_file() {
  local issue_num="$1"
  local issue_title="$2"
  local ac_section="$3"

  cat <<HEADER
#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-${issue_num}.sh — migrated acceptance test for #${issue_num}
#
# Issue #${issue_num}: ${issue_title}
#
# Migrated from inline ## Acceptance test section via tools/migrate-ac-to-file.sh.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="\$(cd "\$SCRIPT_DIR/../.." && pwd)"
cd "\$REPO_ROOT"

# shellcheck disable=SC1091
source "\$(dirname "\$0")/../lib/acceptance-helpers.sh"
HEADER

  # Convert each command line into a check block.
  while IFS= read -r line; do
    # Skip blank lines and comments.
    [[ -z "${line// /}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    # Trim leading whitespace.
    local cmd
    cmd="$(printf '%s' "$line" | sed 's/^[[:space:]]*//')"

    # Skip if it looks like a header marker (e.g. "---").
    [[ "$cmd" =~ ^---+$ ]] && continue

    # Use the command text as the check description.
    # Escape single quotes for the FAIL message.
    local desc
    desc="$(printf '%s' "$cmd" | sed "s/'/\\\\\\\\'/g" | head -c 80)"

    cat <<CHECK
ac_log "checking: ${desc}"
${cmd} || ac_fail "${desc}"

CHECK
  done <<< "$ac_section"

  echo 'echo PASS'
}

generate_test_file "$ISSUE_NUM" "$ISSUE_TITLE" "$AC_SECTION" > "${TEST_FILE}.tmp"
mv "${TEST_FILE}.tmp" "$TEST_FILE"
chmod +x "$TEST_FILE"

echo "Generated: $TEST_FILE"

# ── Build new body ───────────────────────────────────────────────────────────

# Replace the ## Acceptance test section with a file reference.
NEW_BODY=$(printf '%s\n' "$ISSUE_BODY" | awk -v ref="tests/acceptance/issue-${ISSUE_NUM}.sh" '
  /^## Acceptance test$/ {
    print "## Acceptance test"
    print "Acceptance test: `" ref "`"
    skip=1; next
  }
  skip && /^## / { skip=0 }
  !skip { print }
')

# ── Prompt before PATCH ──────────────────────────────────────────────────────

printf '\n--- Preview of new issue body (Acceptance test section) ---\n'
printf '%s\n' "$NEW_BODY" | grep -A2 '## Acceptance test' || true
printf '--- end preview ---\n\n'

# Skip prompt if --yes/-y flag or MIGRATE_AC_YES env var is set.
if [[ "$YES" != true ]] && [[ "${MIGRATE_AC_YES:-}" != true ]]; then
  read -r -p "PATCH issue #${ISSUE_NUM} body? [y/N] " confirm
  if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
    echo "Aborted. Test file was generated but issue body was NOT updated."
    exit 0
  fi
fi

# ── PATCH the issue body ────────────────────────────────────────────────────

TMPBODY=$(mktemp)
printf '%s' "$NEW_BODY" > "$TMPBODY"

HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
  -X PATCH \
  -H "Authorization: token ${FORGE_TOKEN}" \
  -H "Content-Type: application/json" \
  "${FORGE_API}/issues/${ISSUE_NUM}" \
  -d "{\"body\": $(jq -Rs '.' < "$TMPBODY") }")

rm -f "$TMPBODY"

if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "201" ]; then
  echo "WARN: PATCH returned HTTP ${HTTP_CODE} — body may not have been updated." >&2
  echo "Test file was generated; manual PATCH may be needed."
  exit 1
fi

echo "PATCHED issue #${ISSUE_NUM} (HTTP ${HTTP_CODE})."
echo "DONE: issue #${ISSUE_NUM} migrated to tests/acceptance/issue-${ISSUE_NUM}.sh"
