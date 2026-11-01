#!/usr/bin/env bash
# =============================================================================
# tools/xai-login.sh — sign one dsh agent's DSH_HOME into xAI (#2006)
#
# Runs tools/xai-login.mjs inside disinto/agents:local via docker, performs a
# device-code login (a human opens the printed URL and approves the code),
# and stores the resulting OAuth grant as record `llm-pi-ai/xai` in
# <dsh_home>/.credentials.yaml — the file dsh reads for its LLM credentials.
#
# Each agent needs its own grant: a refresh may rotate it, so grants must
# never be copied between agents. The tool refuses to touch an existing
# .credentials.yaml and never prints grant or token values.
#
# Usage:
#   tools/xai-login.sh <dsh_home> [label]
#
# Exit codes:
#   0  grant signed and written
#   1  <dsh_home> is not a directory, .credentials.yaml already exists, or
#      the login/conversion failed
#   2  usage error
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<EOF
Usage: $0 <dsh_home> [label]

Signs the dsh agent whose DSH_HOME is <dsh_home> into xAI by device code.
Prints a verification URL and code for a human to approve, then writes the
grant to <dsh_home>/.credentials.yaml (mode 0600). Refuses to overwrite an
existing .credentials.yaml. The optional 'label' only decorates the printed lines.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  usage >&2
  exit 2
fi
DSH_HOME="$1"
LABEL="${2:-disinto}"

CREDS="$DSH_HOME/.credentials.yaml"
GRANT="$DSH_HOME/.grant.json"

# ── Pre-flight ───────────────────────────────────────────────────────────────

if [ ! -d "$DSH_HOME" ]; then
  die "dsh_home is not a directory: $DSH_HOME"
fi
if [ -e "$CREDS" ]; then
  die "$CREDS already exists — refusing to overwrite an existing grant"
fi
command -v docker >/dev/null 2>&1 || die "docker is required on PATH"
command -v python3 >/dev/null 2>&1 || die "python3 is required on PATH"

# ── 1. Device-code login; the grant lands in <dsh_home>/.grant.json ──────────

docker run --rm --entrypoint node --user 1000:1000 \
  -v "$DSH_HOME:/out" \
  -v "$REPO_ROOT/tools/xai-login.mjs:/login.mjs:ro" \
  disinto/agents:local /login.mjs /out/.grant.json "$LABEL"

[ -f "$GRANT" ] || die "login produced no grant at $GRANT"

# ── 2. Convert the grant JSON into <dsh_home>/.credentials.yaml ──────────────
# Created exclusively (O_CREAT|O_EXCL) with mode 0600. The grant content is
# never echoed — only the file path is mentioned.
python3 - "$GRANT" "$CREDS" <<'PY' || die "failed to write $CREDS"
import json, os, sys

grant_path, cred_path = sys.argv[1], sys.argv[2]
with open(grant_path) as fh:
    grant = json.load(fh)
doc = {"version": 1, "records": {"llm-pi-ai/xai": {"kind": "grant", "payload": grant}}}
try:
    import yaml
    text = yaml.safe_dump(doc, sort_keys=False)
except ImportError:
    # The agents image ships no PyYAML (#1500). JSON is a subset of YAML, so
    # the document still parses; keep the top-level keys in YAML flow form.
    text = "version: 1\nrecords:\n  llm-pi-ai/xai:\n    kind: grant\n    payload: " + json.dumps(grant) + "\n"
fd = os.open(cred_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
with os.fdopen(fd, "w") as fh:
    fh.write(text)
PY

# ── 3. Best-effort ownership, then drop the raw grant ────────────────────────
chown 1000:1000 "$CREDS" 2>/dev/null || true
rm -f "$GRANT"
echo "grant written to $CREDS"
