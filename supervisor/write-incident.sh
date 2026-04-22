#!/usr/bin/env bash
# =============================================================================
# write-incident.sh — Write one markdown incident file per fired recipe
#
# Reads a JSON fired-recipe record (from evaluate-recipes.sh) and writes
# a markdown file under ${OPS_REPO_ROOT}/incidents/. Only fires for
# severity >= P2 (P0, P1, P2).
#
# Usage:
#   source "$(dirname "$0")/../lib/secret-scan.sh"
#   source "$(dirname "$0")/../lib/env.sh"
#   bash "$(dirname "$0")/write-incident.sh" '<json-record>' [preflight-section]
#
# JSON record fields (from evaluate-recipes.sh):
#   {"name":"disk-pressure","severity":"P1","evidence":"Disk: 85% used",
#    "action":"direct","action_script":"supervisor/actions/disk-pressure.sh"}
#
# Output: creates ${OPS_REPO_ROOT}/incidents/<iso-time>-<slug>.md
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

RECORD="${1:-}"
PREFLIGHT_SECTION="${2:-}"

if [ -z "$RECORD" ]; then
  echo "Usage: $0 '<json-record>' [preflight-section-text]" >&2
  exit 1
fi

# ── Severity gate: only P0–P2 ─────────────────────────────────────────────
severity=$(printf '%s' "$RECORD" | jq -r '.severity')
case "$severity" in
  P0|P1|P2) ;;
  *)
    echo "write-incident: skipping ${severity} (only P0-P2)" >&2
    exit 0 ;;
esac

name=$(printf '%s' "$RECORD" | jq -r '.name')
evidence=$(printf '%s' "$RECORD" | jq -r '.evidence')
action=$(printf '%s' "$RECORD" | jq -r '.action')
action_script=$(printf '%s' "$RECORD" | jq -r '.action_script // ""')

# ── Slug generation ────────────────────────────────────────────────────────
slug=$(echo "$name" | tr '[:upper:] ' '[:lower]-' | tr -cd 'a-z0-9-' | cut -c1-40)

# ── Timestamp and filename ─────────────────────────────────────────────────
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
FILENAME="${TIMESTAMP}-${slug}.md"

# ── Ensure incidents directory exists ──────────────────────────────────────
INCIDENTS_DIR="${OPS_REPO_ROOT}/incidents"
mkdir -p "$INCIDENTS_DIR"

# ── Redaction helper ───────────────────────────────────────────────────────
# Source secret-scan.sh if available; fall back to simple grep if not.
if [ -f "$FACTORY_ROOT/lib/secret-scan.sh" ]; then
  source "$FACTORY_ROOT/lib/secret-scan.sh"
  redact_fn() { redact_secrets "$1"; }
else
  redact_fn() {
    printf '%s' "$1" | grep -iv 'token\|password\|secret\|api_key\|bearer' || printf '%s' "$1"
  }
fi

# Redact evidence and preflight section
redacted_evidence=$(redact_fn "$evidence")
redacted_section=""
if [ -n "$PREFLIGHT_SECTION" ]; then
  redacted_section=$(redact_fn "$PREFLIGHT_SECTION")
fi

# ── Build action description ───────────────────────────────────────────────
case "$action" in
  direct)
    if [ -n "$action_script" ] && [ "$action_script" != "__MISSING__" ]; then
      action_desc="executed $(basename "$action_script")"
    else
      action_desc="auto-fixed"
    fi
    ;;
  llm)
    # session_id may be available from the supervisor context
    session_id="${SUPERVISOR_SESSION_ID:-unknown}"
    action_desc="escalated to LLM (session_id: ${session_id})"
    ;;
  vault)
    action_desc="filed vault item"
    ;;
  *)
    action_desc="pending operator review"
    ;;
esac

# ── Write incident markdown ────────────────────────────────────────────────
INCIDENT_FILE="${INCIDENTS_DIR}/${FILENAME}"

cat > "$INCIDENT_FILE" <<INCIDENT_EOF
# Incident: ${name} — ${severity}

- **Time**: ${TIMESTAMP}
- **Severity**: ${severity}
- **Recipe**: ${name}
- **Evidence**: ${redacted_evidence}

## System snapshot

\`\`\`
${redacted_section:-(no preflight section provided)}
\`\`\`

## Action taken

${action_desc}

## Outcome

pending operator review
INCIDENT_EOF

echo "$INCIDENT_FILE"
