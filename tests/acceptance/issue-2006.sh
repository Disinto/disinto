#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2006.sh
#
# Issue #2006: tools/xai-login.sh signs one dsh agent's DSH_HOME into xAI by
# device code, writing the OAuth grant as record `llm-pi-ai/xai` in
# <dsh_home>/.credentials.yaml. It must never overwrite an existing grant and
# must never print grant or token values.
#
# Acceptance (hermetic: a stub `docker` on PATH stands in for the daemon; no
# forge, no nomad, no docker daemon, no network):
#   1. An existing .credentials.yaml -> exit 1, the file is unchanged, and the
#      stub was never called.
#   2. A missing dsh_home dir -> exit 1.
#   3. A successful run -> .credentials.yaml exists with mode 600 and parses to
#      version: 1 plus records["llm-pi-ai/xai"] = {kind: grant, payload: <fake
#      grant>}; .grant.json is gone; neither stdout nor stderr contains the
#      fake secret values.
#   4. node --check tools/xai-login.mjs passes and shellcheck
#      tools/xai-login.sh is clean.
#
# CI runs acceptance tests in disinto/agents:local, which has python3 but no
# PyYAML (issue-1500.sh): the PyYAML parse in AC 3 is an extra check when the
# module is importable; grep assertions cover the same invariants otherwise.
# The tool itself has the same fallback (JSON is a subset of YAML).
#
# Read-only outside mktemp. Run via: tools/run-acceptance.sh 2006
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash python3

TOOL="$REPO_ROOT/tools/xai-login.sh"
MJS="$REPO_ROOT/tools/xai-login.mjs"
ac_assert_file "$TOOL" "tools/xai-login.sh must exist"
ac_assert_file "$MJS" "tools/xai-login.mjs must exist"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STUB="$WORK/stub"
mkdir -p "$STUB"

# ── The docker stub ───────────────────────────────────────────────────────────
# Mimics `docker run ... -v <host>:/out ... disinto/agents:local /login.mjs
# /out/.grant.json <label>`: finds the host dir mounted at /out, writes a fake
# grant there, and leaves a marker so the test can tell the stub ran.
cat > "$STUB/docker" <<'STUB_EOF'
#!/usr/bin/env bash
host=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-v" ] && [ "${arg%:/out}" != "$arg" ]; then
    host="${arg%:/out}"
  fi
  prev="$arg"
done
if [ -z "$host" ]; then
  echo "stub docker: no -v <host>:/out argument" >&2
  exit 1
fi
printf '%s\n' '{"type":"oauth","access":"ACCESS-SECRET-1","refresh":"REFRESH-SECRET-2","expires":1}' > "$host/.grant.json"
touch "$(dirname "$0")/.ran"
exit 0
STUB_EOF
chmod +x "$STUB/docker"

# run_tool <dsh_home> [label] — runs the tool with the stub docker on PATH.
# Captures stdout+stderr into TOOL_OUT and the exit code into TOOL_STATUS.
run_tool() {
  rm -f "$STUB/.ran"
  TOOL_STATUS=0
  TOOL_OUT="$(PATH="$STUB:$PATH" "$TOOL" "$1" "${2:-test-agent}" 2>&1)" || TOOL_STATUS=$?
}

# ── AC 1: an existing .credentials.yaml is never overwritten ─────────────────
ac_log "AC 1: existing .credentials.yaml -> exit 1, file unchanged, stub never called"
H1="$WORK/home1"
mkdir -p "$H1"
printf 'version: 1\nrecords: {}\n' > "$H1/.credentials.yaml"
chmod 600 "$H1/.credentials.yaml"
BEFORE="$(cat "$H1/.credentials.yaml")"
run_tool "$H1"
ac_assert_eq "$TOOL_STATUS" "1" "exit 1 expected when .credentials.yaml already exists (got $TOOL_STATUS)"
AFTER="$(cat "$H1/.credentials.yaml")"
ac_assert_eq "$AFTER" "$BEFORE" ".credentials.yaml must be unchanged when the tool refuses"
if [ -e "$STUB/.ran" ]; then
  ac_fail "the docker stub must never run when a grant already exists"
fi
if printf '%s' "$TOOL_OUT" | grep -q 'ACCESS-SECRET-1\|REFRESH-SECRET-2'; then
  ac_fail "the tool leaked secret values in its output"
fi
ac_log "AC 1 OK"

# ── AC 2: a missing dsh_home dir -> exit 1 ───────────────────────────────────
ac_log "AC 2: missing dsh_home dir -> exit 1"
run_tool "$WORK/does-not-exist"
ac_assert_eq "$TOOL_STATUS" "1" "exit 1 expected when dsh_home is not a directory (got $TOOL_STATUS)"
if [ -e "$STUB/.ran" ]; then
  ac_fail "the docker stub must never run for a missing dsh_home"
fi
ac_log "AC 2 OK"

# ── AC 3: a successful run writes .credentials.yaml and drops .grant.json ────
ac_log "AC 3: successful run -> credentials written, grant removed, no secret leak"
H3="$WORK/home3"
mkdir -p "$H3"
run_tool "$H3" "dev-agent"
ac_assert_eq "$TOOL_STATUS" "0" "exit 0 expected for a successful run (got $TOOL_STATUS)"
if [ ! -e "$STUB/.ran" ]; then
  ac_fail "the docker stub was never called on the successful run"
fi
ac_assert_file "$H3/.credentials.yaml" "the successful run must create .credentials.yaml"
if [ -e "$H3/.grant.json" ]; then
  ac_fail ".grant.json must be removed after conversion"
fi
MODE="$(stat -c '%a' "$H3/.credentials.yaml")"
ac_assert_eq "$MODE" "600" ".credentials.yaml must have mode 600 (got $MODE)"
if printf '%s' "$TOOL_OUT" | grep -q 'ACCESS-SECRET-1\|REFRESH-SECRET-2'; then
  ac_fail "stdout/stderr must not contain the grant's token values"
fi

if python3 -c 'import yaml' 2>/dev/null; then
  ac_log "AC 3: parsing .credentials.yaml with PyYAML"
  python3 - "$H3/.credentials.yaml" <<'PY' || ac_fail "PyYAML structural check of .credentials.yaml failed"
import sys, yaml

doc = yaml.safe_load(open(sys.argv[1]))
assert isinstance(doc, dict), "top level must be a mapping"
assert doc["version"] == 1, "version must be 1"
rec = doc["records"]["llm-pi-ai/xai"]
assert rec["kind"] == "grant", "record kind must be grant"
assert rec["payload"] == {
    "type": "oauth",
    "access": "ACCESS-SECRET-1",
    "refresh": "REFRESH-SECRET-2",
    "expires": 1,
}, "payload must be exactly the grant the stub wrote"
PY
  ac_log "AC 3: PyYAML parse OK"
else
  ac_warn "PyYAML unavailable in this container — grep assertions cover the structure"
  grep -q '^version: 1' "$H3/.credentials.yaml" \
    || ac_fail ".credentials.yaml must declare version: 1"
  grep -q 'llm-pi-ai/xai' "$H3/.credentials.yaml" \
    || ac_fail ".credentials.yaml must carry record llm-pi-ai/xai"
  grep -q 'kind: grant' "$H3/.credentials.yaml" \
    || ac_fail "the record kind must be grant"
fi
ac_log "AC 3 OK"

# ── AC 4: syntax checks ──────────────────────────────────────────────────────
ac_log "AC 4: node --check and shellcheck on the new tool files"
if command -v node >/dev/null 2>&1; then
  node --check "$MJS" || ac_fail "node --check tools/xai-login.mjs failed"
  ac_log "AC 4: node --check OK"
else
  ac_warn "node not available in this container — skipping node --check"
fi
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$TOOL" || ac_fail "shellcheck reported issues on tools/xai-login.sh"
  ac_log "AC 4: shellcheck OK"
else
  ac_warn "shellcheck not available in this container — skipping"
fi

ac_pass
