#!/usr/bin/env bash
# =============================================================================
# lib/forge-api-fallback.sh — quiet forge_api curl fallback for tools that do
# not inherit the gardener's forge_api() function (lib/env.sh).
#
# The gardener's shell defines forge_api() via lib/env.sh, but a tool invoked
# as a subprocess does not inherit the function; hermetic tests put a stub
# command on PATH instead. When neither a function nor a command provides
# forge_api, define a quiet curl fallback from FORGE_API / FORGE_TOKEN.
#
# Sourced by tools/sprint-due.sh (#1675), tools/claims-report.sh (#1645),
# tools/sprint-outcomes.sh (#1676) and tools/tape-rejections.sh (#1631) so
# they do not each copy the same
# fallback. The fallback is quiet (returns 1 without printing) so the calling
# tool logs its own single diagnostic line. The URL check is the part of
# validate_url this call needs (http(s), no credential injection); sourcing
# lib/env.sh would re-read .env.
#
# Defining forge_api() at top level (not nested in a function) keeps it
# reachable under shellcheck. Safe to source more than once: it only defines
# forge_api when no function or command already provides it.
# =============================================================================

if ! declare -F forge_api >/dev/null 2>&1 && ! command -v forge_api >/dev/null 2>&1; then
  forge_api() {
    local method="$1" path="$2"
    shift 2
    case "${FORGE_API:-}" in
      http://*|https://*) ;;
      *) return 1 ;;
    esac
    if [[ "${FORGE_API}" =~ ^https?://[^@]+@ ]]; then
      return 1
    fi
    if [ -z "${FORGE_TOKEN:-}" ]; then
      return 1
    fi
    command -v curl >/dev/null 2>&1 || return 1
    curl -sf -X "$method" -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" --url "${FORGE_API}${path}" "$@"
  }
fi
