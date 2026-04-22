#!/usr/bin/env bash
# =============================================================================
# commit-incidents.sh — Commit and push incident markdown files to ops repo
#
# Scans ${OPS_REPO_ROOT}/incidents/ for new .md files, commits them, and
# pushes to the remote. Runs at end of supervisor tick if incidents were
# written.
#
# Usage:
#   bash "$(dirname "$0")/commit-incidents.sh"
#
# Expects: OPS_REPO_ROOT set in environment (from supervisor-run.sh)
# =============================================================================
set -euo pipefail

# commit-incidents.sh — no SCRIPT_DIR needed

INCIDENTS_DIR="${OPS_REPO_ROOT}/incidents"

if [ ! -d "$INCIDENTS_DIR" ]; then
  exit 0
fi

# ── Collect incident filenames ─────────────────────────────────────────────
shopt -s nullglob
incident_files=("${INCIDENTS_DIR}"/*.md)
shopt -u nullglob

if [ "${#incident_files[@]}" -eq 0 ]; then
  exit 0
fi

# ── Build commit summary from incident names ───────────────────────────────
summaries=()
for f in "${incident_files[@]}"; do
  basename_f=$(basename "$f" .md)
  summaries+=("$basename_f")
done

summary_msg="incident: $(printf '%s, ' "${summaries[@]}")"
# Strip trailing ", "
summary_msg="${summary_msg%, }"

# ── Git commit and push ────────────────────────────────────────────────────
cd "$OPS_REPO_ROOT"

# Stage only new incident files (avoid journal churn)
git add incidents/

# Skip if nothing to commit (e.g., already committed)
if ! git diff --cached --quiet; then
  git commit -m "$summary_msg"

  # Push — supervisor container already has git configured via entrypoint
  git push origin main 2>/dev/null || echo "commit-incidents: push failed (may be network issue or no remote)" >&2
fi
