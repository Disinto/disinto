#!/usr/bin/env bash
# tests/role-cli-nomad-layout.sh — role CLI reads/writes the runtime state dir (#1067)
#
# Replicates the Nomad box layout from the issue:
#
#   baked tree   — where the CLI is installed (bin/ + lib/ + state/). On the
#                  box this is /opt/disinto; it holds only a stale
#                  .supervisor-active flag (as observed in the issue).
#   live clone   — ${DISINTO_PROJECT_REPOS}/_factory, with lib/env.sh (so
#                  bootstrap_factory_repo's switch condition fires) and ALL
#                  six role flags — i.e. flags only in the live clone.
#
# Asserts:
#   1. `role status` resolves to (and prints) the live state dir, reports the
#      live flags, and reports the effective AGENT_ROLES gate from a running
#      Nomad job (via a fake `nomad` on PATH).
#   2. `role status` reports the disagreement between the live and baked
#      state dirs and names both.
#   3. `role enable|disable` write to the live dir (where the runtime reads)
#      and never touch the baked copy.
#   4. Without a live clone, the CLI falls back to the baked state dir.
#   5. Without the nomad CLI, status degrades gracefully (no gate section).
#   6. An unknown subcommand prints the usage text cleanly — the heredoc
#      must not trigger command substitution (no `command not found` noise,
#      the backticked `status` renders literally).
#
# Hermetic — no Nomad, no network, no sudo.
# Required tools: bash, jq, sed, coreutils.

set -euo pipefail

FACTORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILED=0
TMPROOT=$(mktemp -d -t role-cli-nomad-layout.XXXXXX)

fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }
pass() { printf 'PASS: %s\n' "$*"; }

cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 1; }

# ── Stage the baked tree (CLI install location) ──────────────────────────────
BAKED="${TMPROOT}/baked"
mkdir -p "$BAKED/state"
cp -r "$FACTORY_ROOT/bin" "$BAKED/"
cp -r "$FACTORY_ROOT/lib" "$BAKED/"
[ -f "$FACTORY_ROOT/VERSION" ] && cp "$FACTORY_ROOT/VERSION" "$BAKED/" || true
# The stale flag observed on the real box — present in the baked copy only.
touch "$BAKED/state/.supervisor-active"
DISINTO="$BAKED/bin/disinto"
[ -x "$DISINTO" ] || { echo "baked disinto not executable: $DISINTO" >&2; exit 1; }

# ── Stage the live clone at the project-repos host path ──────────────────────
PROJECT_REPOS="${TMPROOT}/project-repos"
LIVE="${PROJECT_REPOS}/_factory"
mkdir -p "$LIVE/lib" "$LIVE/state"
# The condition bootstrap_factory_repo() checks (entrypoint.sh:370).
cp "$FACTORY_ROOT/lib/env.sh" "$LIVE/lib/env.sh"
# All six role flags live-only — the issue's observed layout.
for r in dev reviewer gardener architect planner predictor; do
  touch "$LIVE/state/.${r}-active"
done
export DISINTO_PROJECT_REPOS="$PROJECT_REPOS"

# ── Fake nomad: one running agent job with AGENT_ROLES=dev ───────────────────
FAKEBIN="${TMPROOT}/fakebin"
mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/nomad" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "job list")
    cat <<'JSON'
[
  {"Name": "agents-dev-qwen", "Status": "running"},
  {"Name": "forgejo", "Status": "running"},
  {"Name": "agents-stopped", "Status": "stopped"}
]
JSON
    ;;
  "job status")
    case "${3:-}" in
      agents-dev-qwen)
        cat <<'JSON'
{"Job": {"TaskGroups": [{"Tasks": [{"Name": "agents", "Env": {"AGENT_ROLES": "dev"}}]}]}}
JSON
        ;;
      forgejo)
        cat <<'JSON'
{"Job": {"TaskGroups": [{"Tasks": [{"Name": "forgejo", "Env": {}}]}]}}
JSON
        ;;
      *)
        echo "Error responding to request: job not found" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "unknown command: $*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$FAKEBIN/nomad"
export PATH="$FAKEBIN:${PATH}"

# ── 1/6 status resolves the live state dir + reports AGENT_ROLES ─────────────
echo "=== 1/6 role status uses the live clone state dir ==="
rc=0
out=$("$DISINTO" role status 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then
  pass "role status exited 0"
else
  fail "role status exited $rc"
  printf '%s\n' "$out" >&2
fi

if printf '%s\n' "$out" | grep -qF "State dir: ${LIVE}/state"; then
  pass "status names the live state dir"
else
  fail "status did not name the live state dir (${LIVE}/state)"
  printf '%s\n' "$out" >&2
fi

if printf '%s\n' "$out" | grep -qE '^dev +enabled$'; then
  pass "status reports dev enabled (live flags visible)"
else
  fail "status does not report live flags as enabled"
  printf '%s\n' "$out" >&2
fi

if printf '%s\n' "$out" | grep -qF "Nomad AGENT_ROLES gate" \
   && printf '%s\n' "$out" | grep -qF "agents-dev-qwen: dev"; then
  pass "status reports the AGENT_ROLES gate from the running job"
else
  fail "status did not report the AGENT_ROLES gate"
  printf '%s\n' "$out" >&2
fi

if printf '%s\n' "$out" | grep -q 'forgejo:'; then
  fail "status reported a non-agent job (forgejo) as an agent gate"
else
  pass "status ignored jobs without AGENT_ROLES / stopped jobs"
fi

# ── 2/6 disagreement between live and baked state dirs is reported ───────────
echo "=== 2/6 status reports live-vs-baked disagreement, naming both ==="
if printf '%s\n' "$out" | grep -q 'state dirs disagree'; then
  pass "status reports the disagreement"
else
  fail "status did not report the disagreement"
  printf '%s\n' "$out" >&2
fi

if printf '%s\n' "$out" | grep -qF "live (runtime): ${LIVE}/state" \
   && printf '%s\n' "$out" | grep -qF "baked (image):  ${BAKED}/state"; then
  pass "disagreement names both state dirs"
else
  fail "disagreement does not name both state dirs"
  printf '%s\n' "$out" >&2
fi

# ── 3/6 enable/disable write the live dir, never the baked copy ──────────────
echo "=== 3/6 enable/disable target the live state dir ==="
rm -f "$LIVE/state/.planner-active"

rc=0
out=$("$DISINTO" role enable planner 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && [ -f "$LIVE/state/.planner-active" ] \
   && [ ! -f "$BAKED/state/.planner-active" ]; then
  pass "enable wrote the live dir only"
else
  fail "enable did not write the live dir (rc=$rc)"
  printf '%s\n' "$out" >&2
fi

if printf '%s\n' "$out" | grep -qF "State dir: ${LIVE}/state" \
   && printf '%s\n' "$out" | grep -qE '^  nomad job stop agents-dev-qwen$'; then
  pass "enable names the live state dir and a copy-pasteable nomad job stop command"
else
  fail "enable output missing state dir or nomad job stop note"
  printf '%s\n' "$out" >&2
fi

rc=0
out=$("$DISINTO" role disable planner 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && [ ! -f "$LIVE/state/.planner-active" ]; then
  pass "disable removed the live flag"
else
  fail "disable did not remove the live flag (rc=$rc)"
  printf '%s\n' "$out" >&2
fi

if [ "$(ls -A "$BAKED/state")" = ".supervisor-active" ]; then
  pass "baked state dir was never touched"
else
  fail "baked state dir was modified: $(ls -A "$BAKED/state")"
fi

# ── 4/6 without a live clone, the baked state dir is used ────────────────────
echo "=== 4/6 no live clone falls back to the baked state dir ==="
rc=0
out=$(env DISINTO_PROJECT_REPOS="${TMPROOT}/no-such-project-repos" \
  "$DISINTO" role status 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qF "State dir: ${BAKED}/state"; then
  pass "status falls back to the baked state dir"
else
  fail "status did not fall back to the baked state dir (rc=$rc)"
  printf '%s\n' "$out" >&2
fi

if printf '%s\n' "$out" | grep -q 'state dirs disagree'; then
  fail "status reported a disagreement when only one dir is in use"
else
  pass "no disagreement reported when live == baked"
fi

# ── 5/6 without the nomad CLI, status degrades gracefully ────────────────────
echo "=== 5/6 no nomad CLI → no gate section, still exits 0 ==="
rc=0
out=$(env PATH="/usr/local/bin:/usr/bin:/bin" "$DISINTO" role status 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | grep -q 'Nomad AGENT_ROLES gate'; then
  pass "status degrades gracefully without nomad"
else
  fail "status with no nomad: rc=$rc"
  printf '%s\n' "$out" >&2
fi

# ── 6/6 usage path: unknown subcommand → clean usage, no command substitution ─
echo "=== 6/6 unknown subcommand prints clean usage (no command not found) ==="
rc=0
out=$("$DISINTO" role bogus 2>&1) || rc=$?
if [ "$rc" -eq 1 ]; then
  pass "unknown subcommand exits 1"
else
  fail "unknown subcommand exited $rc (want 1)"
  printf '%s\n' "$out" >&2
fi

if printf '%s\n' "$out" | grep -qi 'command not found'; then
  fail "usage path emitted command-substitution noise (unescaped backticks?)"
  printf '%s\n' "$out" >&2
else
  pass "usage path emits no command-substitution noise"
fi

# The backticked `status` must render literally — catches both a missing
# `status` binary (word eaten) and one present on PATH (output spliced in).
if printf '%s\n' "$out" | grep -qF '`status` and by enable/disable as "State dir:").'; then
  pass "usage text renders the backticked status literally"
else
  fail 'usage text did not render the backticked status line verbatim'
  printf '%s\n' "$out" >&2
fi

if printf '%s\n' "$out" | grep -qF 'Usage: disinto role <subcommand>'; then
  pass "usage path prints the usage header"
else
  fail "usage path missing the usage header"
  printf '%s\n' "$out" >&2
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
if [ "$FAILED" -ne 0 ]; then
  echo "=== ROLE-CLI-NOMAD-LAYOUT TEST FAILED ==="
  exit 1
fi
echo "=== ROLE-CLI-NOMAD-LAYOUT TEST PASSED ==="
