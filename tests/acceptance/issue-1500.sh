#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1500.sh
#
# Issue #1500: wire dsh `reasoningEffort` through to llama.cpp
# `chat_template_kwargs` for a working "low" thinking gear.
#
# The live llamacpp route (docker/agents/dsh-settings-llamacpp.yaml) previously
# carried a hard-coded `enable_thinking: false` in `compat.chatTemplateKwargs`,
# so no matter what `reasoningEffort` the harness picked, the wire request
# never carried the template kwarg. The Bonsai embedded template defaulted to
# xhigh thinking, ~96% of session output tokens were reasoning, and the "low"
# gear was a no-op.
#
# This test proves the fix at the wire level, not by inspecting the settings
# file (that would pass even if dsh ignored the kwarg). It spawns a local
# mock llama-server (Python, stdlib only) that captures every request body to
# a JSONL file, points dsh at it, and asserts the captured requests carry the
# correct `chat_template_kwargs`:
#
#   reasoningEffort=low  -> chat_template_kwargs.enable_thinking == true
#                            chat_template_kwargs.reasoning_effort == "low"
#   reasoningEffort=off  -> chat_template_kwargs.enable_thinking == false
#                            (no reasoning_effort key: omitWhenOff: true)
#
# The mock responds with a minimal valid completion so dsh's agent loop
# can complete (we do not need a real model for wire-shape verification).
#
# Verifies:
#   1. dsh, python3, jq are available.
#   2. The settings file carries the $var wiring (static sanity).
#   3. A live dsh headless run against the mock produces at least one
#      request with enable_thinking: true + reasoning_effort: "low".
#   4. A second run with reasoningEffort: off produces
#      enable_thinking: false and no reasoning_effort key.
#
# Read-only (no forge, no nomad, no writes outside mktemp). Run via:
#   tools/run-acceptance.sh 1500
#
# Note: this test is hermetic — it does NOT depend on a live llama-server at
# 10.10.10.1:8081 or any other external endpoint. It works on any host that
# has dsh + python3 + jq.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash python3 jq dsh

# ── 1. Static sanity: the settings file carries the $var wiring ──────────────
ac_log "static sanity: settings file carries the \$var passthrough block"
SETTINGS="$REPO_ROOT/docker/agents/dsh-settings-llamacpp.yaml"
ac_assert_file "$SETTINGS" "dsh-settings-llamacpp.yaml is missing"

python3 - "$SETTINGS" <<'PYEOF'
import yaml, sys

with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)

c = data["llm-pi-ai"]["providers"]["llamacpp"]
ctk = c["compat"]

def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)

def assert_eq(actual, expected, desc):
    if actual != expected:
        print(f"FAIL: {desc}: expected {expected!r}, got {actual!r}", file=sys.stderr)
        sys.exit(1)
    print(f"OK: {desc}")

# thinkingFormat must be chat-template
assert_eq(ctk["thinkingFormat"], "chat-template", "thinkingFormat")

# chatTemplateKwargs must carry enable_thinking and reasoning_effort
kw = ctk["chatTemplateKwargs"]

# enable_thinking must be wired to the $var thinking.enabled
et = kw["enable_thinking"]
assert_eq(et["$var"], "thinking.enabled", "enable_thinking $var -> thinking.enabled")

# reasoning_effort must be wired to the $var thinking.effort with omitWhenOff
re_ = kw["reasoning_effort"]
assert_eq(re_["$var"], "thinking.effort", "reasoning_effort $var -> thinking.effort")
assert_eq(re_["omitWhenOff"], True, "reasoning_effort omitWhenOff == true")
PYEOF

ac_log "static sanity: PASS"

# ── 2. Live wire probe: dsh headless against a mock llama-server ─────────────
ac_log "spawning mock llama-server on a local ephemeral port"

TMP_DSH_HOME="$(mktemp -d)"
REQUEST_LOG="$TMP_DSH_HOME/reqlog.jsonl"
MOCK_PID=""
cleanup() {
  if [ -n "$MOCK_PID" ] && kill -0 "$MOCK_PID" 2>/dev/null; then
    kill "$MOCK_PID" 2>/dev/null
    wait "$MOCK_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_DSH_HOME"
}
trap cleanup EXIT

# Pick an ephemeral port
PORT="$(python3 -c '
import socket
s=socket.socket()
s.bind(("127.0.0.1",0))
print(s.getsockname()[1])
s.close()
')"

# ── Start the mock llama-server ───────────────────────────────────────────────
cat > "$TMP_DSH_HOME/mock_server.py" <<'PYEOF'
import http.server, json, sys, os

LOG_FILE = sys.argv[2]
PORT = int(sys.argv[1])

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8")
        with open(LOG_FILE, "a") as f:
            f.write(json.dumps({"path": self.path, "body": body}) + "\n")
        resp = json.dumps({
            "id": "mock-1",
            "object": "chat.completion",
            "created": 0,
            "model": "unsloth/Qwen3.8-27B",
            "choices": [{"index": 0,
                         "message": {"role": "assistant",
                                     "content": "OK",
                                     "reasoning_content": "OK"},
                         "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 10,
                      "completion_tokens": 10,
                      "total_tokens": 20}
        })
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(resp)))
        self.end_headers()
        self.wfile.write(resp.encode())
    def log_message(self, *args):
        pass

http.server.HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
PYEOF

python3 "$TMP_DSH_HOME/mock_server.py" "$PORT" "$REQUEST_LOG" >/dev/null 2>&1 &
MOCK_PID=$!

# Give the mock server a moment to start listening
sleep 1

# ── Seed a temp DSH_HOME with settings pointing at the mock ──────────────────
cat > "$TMP_DSH_HOME/settings.yaml" <<YAMLEOF
llm-pi-ai:
  providers:
    llamacpp:
      displayName: llama.cpp local
      apiKeyEnv: LLAMACPP_API_KEY
      api: openai-completions
      baseURL: http://127.0.0.1:${PORT}/v1
      compat:
        supportsDeveloperRole: false
        maxTokensField: max_tokens
        thinkingFormat: chat-template
        chatTemplateKwargs:
          enable_thinking:
            \$var: thinking.enabled
          reasoning_effort:
            \$var: thinking.effort
            omitWhenOff: true
      models:
        - id: unsloth/Qwen3.8-27B
          name: Qwen3.8 27B IQ4_XS (local)
          contextWindow: 100000
          maxTokens: 32768
          input: [text, image]
          reasoningEfforts:
            low: low
            medium: medium
            high: high
            off: off

agent-default-model:
  provider: llamacpp
  model: unsloth/Qwen3.8-27B
  reasoningEffort: low
YAMLEOF

# ── Probe A: reasoningEffort=low (default) ────────────────────────────────────
ac_log "probe A: dsh headless with reasoningEffort=low (default)"
: > "$REQUEST_LOG"  # start with a clean log

DSH_HOME="$TMP_DSH_HOME" \
  DSH_BASE_URL="http://127.0.0.1:${PORT}/v1" \
  LLAMACPP_API_KEY="acceptance-test" \
  dsh --profile headless "Say hello in one word" 2>/dev/null \
  || true

LAST_BODY_LOW="$(tail -n1 "$REQUEST_LOG" 2>/dev/null | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["body"])' 2>/dev/null || echo '')"
if [ -z "$LAST_BODY_LOW" ]; then
  ac_fail "dsh sent no requests to the mock for the low-effort run (log has $(wc -l <"$REQUEST_LOG") lines)"
fi

# Verify the wire kwargs using python (jq has issues with $var keys)
python3 - "$LAST_BODY_LOW" <<'PYEOF'
import json, sys

body = json.loads(sys.argv[1])
ctk = body.get("chat_template_kwargs")

def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)

def assert_eq(actual, expected, desc):
    if actual != expected:
        print(f"FAIL: {desc}: expected {expected!r}, got {actual!r}", file=sys.stderr)
        sys.exit(1)
    print(f"OK: {desc}")

if ctk is None:
    fail("no chat_template_kwargs in low-effort wire request (keys: " + str(list(body.keys())) + ")")

assert_eq(ctk.get("enable_thinking"), True, "enable_thinking == true")
assert_eq(ctk.get("reasoning_effort"), "low", "reasoning_effort == low")
PYEOF

ac_log "probe A: PASS — wire request carries chat_template_kwargs.{enable_thinking: true, reasoning_effort: low}"

# ── Probe B: reasoningEffort=off ──────────────────────────────────────────────
ac_log "probe B: dsh headless with reasoningEffort=off"
: > "$REQUEST_LOG"  # truncate for the off run

# Override the settings to set reasoningEffort: off
sed -i 's/^  reasoningEffort: low$/  reasoningEffort: off/' "$TMP_DSH_HOME/settings.yaml"

DSH_HOME="$TMP_DSH_HOME" \
  DSH_BASE_URL="http://127.0.0.1:${PORT}/v1" \
  LLAMACPP_API_KEY="acceptance-test" \
  dsh --profile headless "Say hello in one word" 2>/dev/null \
  || true

LAST_BODY_OFF="$(tail -n1 "$REQUEST_LOG" 2>/dev/null | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["body"])' 2>/dev/null || echo '')"
if [ -z "$LAST_BODY_OFF" ]; then
  ac_fail "dsh sent no requests to the mock for the off-effort run (log has $(wc -l <"$REQUEST_LOG") lines)"
fi

# Verify the wire kwargs using python
python3 - "$LAST_BODY_OFF" <<'PYEOF'
import json, sys

body = json.loads(sys.argv[1])
ctk = body.get("chat_template_kwargs")

def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)

def assert_eq(actual, expected, desc):
    if actual != expected:
        print(f"FAIL: {desc}: expected {expected!r}, got {actual!r}", file=sys.stderr)
        sys.exit(1)
    print(f"OK: {desc}")

if ctk is None:
    fail("no chat_template_kwargs in off-effort wire request (keys: " + str(list(body.keys())) + ")")

assert_eq(ctk.get("enable_thinking"), False, "enable_thinking == false")

# omitWhenOff: true means reasoning_effort must be absent when effort is off
if "reasoning_effort" in ctk:
    fail(f"off-effort wire request carries reasoning_effort={ctk['reasoning_effort']!r} (expected omitted: omitWhenOff: true)")
print("OK: reasoning_effort absent (omitWhenOff)")
PYEOF

ac_log "probe B: PASS — wire request carries chat_template_kwargs.{enable_thinking: false} with no reasoning_effort"

# ── 4. Token-count comparison (informational, not a gate) ────────────────────
ac_log "token counts (informational)"
ac_log "  low-effort wire kwargs: enable_thinking=true, reasoning_effort=low"
ac_log "  off-effort  wire kwargs: enable_thinking=false"
ac_log "note: on the Bonsai embedded template reasoning_effort is instruction-"
ac_log "wording only, so token counts are comparable across efforts. The kwarg"
ac_log "wiring is correct even where this template does not cap the budget"
ac_log "(issue #1500). To measure a real reduction, deploy a template that"
ac_log "honours reasoning_effort as a token budget."

ac_pass
