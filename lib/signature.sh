#!/usr/bin/env bash
# =============================================================================
# lib/signature.sh — rubric signature lookup (generic, loop-agnostic)
#
# Outcome records may carry a rubric *signature* so the work/world attribution
# the design requires can be written. This mechanism is generic: the rubric is
# *content* in disinto-ops, and this lib must not name any loop or signature.
# A caller passes a loop (as a path component) and a reason; this lib resolves
# the reason to its signature in the loop's rubric TOML and is done. It knows
# no loop, no reason, no signature — none are named here.
#
# Sourced from the caller:
#   source "$(dirname "$0")/signature.sh"
#
# Storage (env-overridable, the test seam):
#   $RUBRICS_DIR   — rubric TOML dir; default
#       ${OPS_REPO_ROOT:-/home/agent/repos/_factory/disinto-ops}/rubrics
#   $OPS_REPO_ROOT — ops repo clone (fallback location for the default dir)
#
# Rubric format (documented here so the ops-side writers stay in sync):
#   [map]
#     <reason> = "<signature>"
#   [<signature>]
#     attribution = "work" | "world" | "proposal"
#
#   [map] maps a reason string to a signature — the only table signature_for
#   reads. The [ <signature> ] tables carry `attribution`:
#     work     — the failure is agent-owned (inside its own loop).
#     world    — the failure is environmental (CI, compute, network, disk).
#     proposal — the issue could not be done as written and the agent rejected
#                it.
#   [ <signature> ] tables are metadata for the calibration reader;
#   signature_for does not consult them when resolving a reason.
#
# Function:
#   signature_for REASON LOOP
#     -> prints the signature that <rubrics>/<LOOP>.toml's [map] table maps
#        REASON to; prints nothing when the file is missing/unreadable, [map]
#        is absent, or REASON is not a key of [map]. Always rc 0 — the caller
#        decides what a null (empty) output means (e.g. omit the signature
#        field from the outcome). Hermetic: no network, no agent; python3
#        (tomllib) only.
#
# Return codes (reader): 0 — succeeded, whether or not a signature was printed.
# This is a reader, not a writer: a missing rubric is a null result, not an
# error; the caller decides whether to fall back.
# =============================================================================
set -euo pipefail

# signature_for REASON LOOP
# Prints the reason's signature from the loop's rubric, or nothing. Always rc 0.
signature_for() {
  local reason="${1:-}" loop="${2:-}"
  local rubrics_dir toml_file
  rubrics_dir="${RUBRICS_DIR:-${OPS_REPO_ROOT:-/home/agent/repos/_factory/disinto-ops}/rubrics}"
  toml_file="${rubrics_dir}/${loop}.toml"

  local sig=""
  if [ -n "$reason" ] && [ -n "$loop" ] && [ -r "$toml_file" ] \
     && command -v python3 >/dev/null 2>&1; then
    sig="$(TOML_FILE="$toml_file" REASON="$reason" python3 -c '
import os, sys, tomllib
try:
    with open(os.environ["TOML_FILE"], "rb") as f:
        data = tomllib.load(f)
except Exception:
    sys.exit(0)
m = data.get("map")
if isinstance(m, dict):
    v = m.get(os.environ["REASON"])
    if isinstance(v, str) and v:
        sys.stdout.write(v)
' 2>/dev/null)" || sig=""
  fi
  if [ -n "$sig" ]; then
    printf '%s\n' "$sig"
  fi
  return 0
}
