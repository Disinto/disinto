#!/usr/bin/env bash
# =============================================================================
# tools/run-acceptance.sh — runner for tests/acceptance/issue-<N>.sh
#
# Locates tests/acceptance/issue-<N>.sh, sources the daemon's env (so tests can
# hit forge / nomad without the operator wiring secrets by hand), executes the
# test, captures stdout+stderr+exit code, and emits either human text or JSON.
#
# Usage:
#   tools/run-acceptance.sh <issue-number>
#   tools/run-acceptance.sh --format json <issue-number>
#   tools/run-acceptance.sh --format text <issue-number>   # default
#
# Env sourcing precedence (first hit wins):
#   1. RUN_ACCEPTANCE_ENV_FILE  — explicit override, useful in CI
#   2. /etc/disinto/acceptance.env  — operator-provisioned drop-in
#   3. /proc/<pid>/environ of snapshot-daemon.sh — pulled live from the daemon
#   4. inherit current environment unchanged
#
# Exit code mirrors the underlying test's exit code so the runner is composable
# (CI, watchdogs, ad-hoc shells can chain it).
#
# Read-only convention: the runner deliberately does NOT sandbox tests. Tests
# must be read-only by convention (no issue filing, no nomad job dispatch, no
# state mutation); reviewer-agent rejects mutating tests.
# =============================================================================
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 [--format text|json] <issue-number>

Runs tests/acceptance/issue-<N>.sh. Exit code mirrors the test's.

Options:
  --format text  Human-readable output (default).
  --format json  Single-line JSON: {issue, exit, result, output, duration_secs}.
  -h, --help     Show this help.
EOF
}

FORMAT="text"
ISSUE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --format)
      shift
      [ $# -gt 0 ] || { echo "error: --format requires an argument" >&2; exit 2; }
      FORMAT="$1"
      shift
      ;;
    --format=*)
      FORMAT="${1#--format=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "error: unknown flag: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [ -z "$ISSUE" ]; then
        ISSUE="$1"
      else
        echo "error: unexpected argument: $1" >&2
        usage >&2
        exit 2
      fi
      shift
      ;;
  esac
done

if [ -z "$ISSUE" ]; then
  echo "error: issue number required" >&2
  usage >&2
  exit 2
fi

case "$ISSUE" in
  ''|*[!0-9]*)
    echo "error: issue must be a positive integer, got: $ISSUE" >&2
    exit 2
    ;;
esac

case "$FORMAT" in
  text|json) ;;
  *)
    echo "error: --format must be 'text' or 'json', got: $FORMAT" >&2
    exit 2
    ;;
esac

# Resolve repo root from this script's location: tools/ → repo root.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_FILE="$REPO_ROOT/tests/acceptance/issue-${ISSUE}.sh"

if [ ! -f "$TEST_FILE" ]; then
  echo "error: acceptance test not found: $TEST_FILE" >&2
  exit 2
fi

# ── Env sourcing ─────────────────────────────────────────────────────────────
# Build a clean env file that contains FORGE_URL/NOMAD_ADDR/FACTORY_FORGE_PAT/
# NOMAD_TOKEN (and friends) so the test inherits them. We tolerate any of the
# four sources missing — fall through to the next one.

ACCEPTANCE_ENV_KEYS=(
  FORGE_URL FORGE_API FORGE_REPO
  NOMAD_ADDR NOMAD_TOKEN
  FACTORY_FORGE_PAT FACTORY_ROOT
  SNAPSHOT_PATH INBOX_ROOT
)

# Returns 0 if it filled $TMP_ENV, 1 otherwise. Caller decides what to do next.
load_env_from_file() {
  local src="$1"
  [ -f "$src" ] && [ -r "$src" ] || return 1
  # shellcheck disable=SC1090
  set -a; . "$src"; set +a
  return 0
}

load_env_from_proc() {
  # Find a snapshot-daemon.sh process; pull its environ (NUL-separated).
  local pid
  pid="$(pgrep -f 'snapshot-daemon\.sh' 2>/dev/null | head -n1 || true)"
  [ -n "$pid" ] && [ -r "/proc/$pid/environ" ] || return 1
  local key val line
  while IFS= read -r -d '' line; do
    key="${line%%=*}"
    val="${line#*=}"
    # Only export the keys we care about — don't leak the daemon's full env.
    for k in "${ACCEPTANCE_ENV_KEYS[@]}"; do
      if [ "$key" = "$k" ]; then
        export "$key=$val"
        break
      fi
    done
  done < "/proc/$pid/environ"
  return 0
}

ENV_SOURCE="inherited"
if [ -n "${RUN_ACCEPTANCE_ENV_FILE:-}" ] && load_env_from_file "$RUN_ACCEPTANCE_ENV_FILE"; then
  ENV_SOURCE="$RUN_ACCEPTANCE_ENV_FILE"
elif load_env_from_file /etc/disinto/acceptance.env; then
  ENV_SOURCE="/etc/disinto/acceptance.env"
elif load_env_from_proc; then
  ENV_SOURCE="snapshot-daemon /proc/<pid>/environ"
fi

# Self-invocation guard: tests may invoke the runner recursively (the issue-850
# self-test does, to prove the runner is wired up). Bump a depth counter so the
# test can detect re-entry and skip the recursive call.
RUN_ACCEPTANCE_DEPTH="$(( ${RUN_ACCEPTANCE_DEPTH:-0} + 1 ))"
export RUN_ACCEPTANCE_DEPTH

# Bound recursion defensively — a runaway test should not fork forever.
if [ "$RUN_ACCEPTANCE_DEPTH" -gt 4 ]; then
  echo "error: RUN_ACCEPTANCE_DEPTH=$RUN_ACCEPTANCE_DEPTH exceeds limit (4) — aborting to prevent runaway recursion" >&2
  exit 2
fi

# ── Execute ──────────────────────────────────────────────────────────────────
START_TS="$(date +%s)"
OUTPUT_FILE="$(mktemp)"
trap 'rm -f "$OUTPUT_FILE"' EXIT

set +e
bash "$TEST_FILE" >"$OUTPUT_FILE" 2>&1
TEST_EXIT=$?
set -e

END_TS="$(date +%s)"
DURATION=$(( END_TS - START_TS ))

if [ "$TEST_EXIT" -eq 0 ]; then
  RESULT="PASS"
else
  RESULT="FAIL"
fi

case "$FORMAT" in
  text)
    echo "issue:    $ISSUE"
    echo "test:     tests/acceptance/issue-${ISSUE}.sh"
    echo "env:      $ENV_SOURCE"
    echo "duration: ${DURATION}s"
    echo "result:   $RESULT (exit=$TEST_EXIT)"
    echo "── output ──"
    cat "$OUTPUT_FILE"
    ;;
  json)
    # Use jq -Rs to safely encode the captured output as a JSON string.
    OUTPUT_JSON="$(jq -Rs . <"$OUTPUT_FILE")"
    printf '{"issue":%d,"exit":%d,"result":"%s","output":%s,"duration_secs":%d}\n' \
      "$ISSUE" "$TEST_EXIT" "$RESULT" "$OUTPUT_JSON" "$DURATION"
    ;;
esac

exit "$TEST_EXIT"
