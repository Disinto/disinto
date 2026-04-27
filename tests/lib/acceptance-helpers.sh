#!/usr/bin/env bash
# =============================================================================
# tests/lib/acceptance-helpers.sh — shared utilities for acceptance tests
#
# Sourced by tests/acceptance/issue-<N>.sh. Provides curl wrappers for forge +
# nomad HTTP APIs, jq assertion helpers, and log-format helpers.
#
# Conventions:
#   - All helpers are read-only. They never POST, PUT, DELETE, or otherwise
#     mutate state. (Reviewer-agent rejects mutating acceptance tests.)
#   - Failures call `ac_fail "<reason>"` which prints `FAIL: <reason>` and
#     exits 1 — matching the contract that the last line of stdout is PASS or
#     FAIL: <reason>.
#   - All helpers respect the env loaded by tools/run-acceptance.sh (FORGE_URL,
#     NOMAD_ADDR, FACTORY_FORGE_PAT, NOMAD_TOKEN, etc.). When run outside the
#     runner, the operator must export these before sourcing.
# =============================================================================

# Idempotent guard — a test that sources the helpers twice (e.g. via nested
# sourcing) shouldn't redefine functions or re-run setup.
if [ -n "${ACCEPTANCE_HELPERS_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
ACCEPTANCE_HELPERS_LOADED=1

# ── Output helpers ───────────────────────────────────────────────────────────

# ac_log <msg> — human-readable progress to stdout.
ac_log() {
  echo ":: $*"
}

# ac_warn <msg> — warning to stderr (non-fatal).
ac_warn() {
  echo "WARN: $*" >&2
}

# ac_fail <reason> — print `FAIL: <reason>` and exit 1.
ac_fail() {
  echo "FAIL: $*"
  exit 1
}

# ac_pass — print PASS and exit 0. Optional in tests that want to be explicit.
ac_pass() {
  echo PASS
  exit 0
}

# ── Pre-flight ───────────────────────────────────────────────────────────────

# ac_require_cmd <cmd>... — fail if any command is missing.
ac_require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 \
      || ac_fail "required command not on PATH: $cmd"
  done
}

# ac_require_env <var>... — fail if any env var is unset or empty.
ac_require_env() {
  local var
  for var in "$@"; do
    if [ -z "${!var:-}" ]; then
      ac_fail "required env var not set: $var (run via tools/run-acceptance.sh or source /etc/disinto/acceptance.env)"
    fi
  done
}

# ── HTTP wrappers ────────────────────────────────────────────────────────────

# ac_forge_api <path> [curl-args...] — GET against $FORGE_URL/api/v1/<path>.
# Authenticates with $FACTORY_FORGE_PAT if set. Echoes the response body to
# stdout; returns curl's exit code (so callers can chain `|| ac_fail ...`).
ac_forge_api() {
  local path="$1"; shift
  ac_require_env FORGE_URL
  local url="${FORGE_URL%/}/api/v1/${path#/}"
  local auth=()
  if [ -n "${FACTORY_FORGE_PAT:-}" ]; then
    auth=(-H "Authorization: token $FACTORY_FORGE_PAT")
  fi
  curl -sf "${auth[@]}" "$@" "$url"
}

# ac_nomad_api <path> [curl-args...] — GET against $NOMAD_ADDR/v1/<path>.
# Authenticates with X-Nomad-Token if $NOMAD_TOKEN is set.
ac_nomad_api() {
  local path="$1"; shift
  ac_require_env NOMAD_ADDR
  local url="${NOMAD_ADDR%/}/v1/${path#/}"
  local auth=()
  if [ -n "${NOMAD_TOKEN:-}" ]; then
    auth=(-H "X-Nomad-Token: $NOMAD_TOKEN")
  fi
  curl -sf "${auth[@]}" "$@" "$url"
}

# ── jq assertion helpers ────────────────────────────────────────────────────

# ac_assert_jq <expr> <json-string> [reason] — fail if `jq -e <expr>` against
# the given JSON returns false/null/empty. Reason is appended to FAIL message.
ac_assert_jq() {
  local expr="$1"
  local json="$2"
  local reason="${3:-jq assertion failed: $expr}"
  echo "$json" | jq -e "$expr" >/dev/null 2>&1 \
    || ac_fail "$reason"
}

# ac_assert_eq <actual> <expected> [reason] — string equality assertion.
ac_assert_eq() {
  local actual="$1"
  local expected="$2"
  local reason="${3:-expected '$expected', got '$actual'}"
  [ "$actual" = "$expected" ] || ac_fail "$reason"
}

# ac_assert_file <path> [reason] — file exists and is readable.
ac_assert_file() {
  local path="$1"
  local reason="${2:-expected file not found or not readable: $path}"
  [ -r "$path" ] || ac_fail "$reason"
}
