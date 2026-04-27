#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-882.sh — verifies second-turn voice works end-to-end
#
# Issue #882: `live_session.receive()` exits the generator after one turn
# (server_content.turn_complete=True), so the bridge's async-for loop ended
# after turn 1. This test connects to the voice WS, sends two turns, and
# asserts both produce non-empty transcripts.
#
# Acceptance:
#   1. Turn 1 returns a non-empty transcript.
#   2. Turn 2 returns a non-empty transcript (the regression from #860).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source "$(dirname "$0")/../lib/acceptance-helpers.sh"

# ── Find a running edge alloc ────────────────────────────────────────────────

ac_log "finding a running edge alloc"

if ! command -v nomad >/dev/null 2>&1; then
  echo "SKIP: nomad CLI not on PATH — skipping live acceptance test"
  exit 0
fi

ALLOC="$(nomad job allocs -t \
  '{{range .}}{{if eq .ClientStatus "running"}}{{.ID}}{{end}}{{end}}' edge 2>/dev/null \
  | head -c 36)"
[ -n "$ALLOC" ] || {
  echo "SKIP: no running edge alloc — skipping live acceptance test"
  exit 0
}

# ── Write the Python WS harness to a temp file (avoids heredoc-in-$()
#    which confuses ShellCheck's parser). ────────────────────────────────────

HARNESS="$(mktemp)"
trap 'rm -f "$HARNESS"' EXIT

cat > "$HARNESS" <<'PY'
import asyncio, json, uuid, websockets

async def main():
    conv = uuid.uuid4().hex[:12]
    async with websockets.connect(
        "ws://127.0.0.1:8090/voice/ws", subprotocols=["voice-stream-v1"]
    ) as ws:
        await ws.send(json.dumps({"type": "hello", "conversation_id": conv}))
        outputs = []

        async def reader():
            async for msg in ws:
                if isinstance(msg, str):
                    d = json.loads(msg)
                    if d.get("type") == "transcript" and d.get("source") == "output":
                        outputs.append(d.get("text", ""))

        t = asyncio.create_task(reader())
        await asyncio.sleep(2)

        # Turn 1
        await ws.send(json.dumps({
            "type": "text",
            "content": "How many backlog issues are there?",
        }))
        await asyncio.sleep(15)
        t1 = "".join(outputs)
        outputs.clear()

        # Turn 2
        await ws.send(json.dumps({
            "type": "text",
            "content": "And how many are in progress?",
        }))
        await asyncio.sleep(15)
        t2 = "".join(outputs)

        t.cancel()
        try:
            await t
        except Exception:
            pass

        print(f"TURN1={t1}")
        print(f"TURN2={t2}")

asyncio.run(main())
PY

# ── Run the WS harness inside the edge container ─────────────────────────────

ac_log "running 2-turn voice harness inside alloc $ALLOC"

out="$(nomad alloc exec -task caddy "$ALLOC" \
  /opt/voice-venv/bin/python3 "$HARNESS")"

t1="$(echo "$out" | grep '^TURN1=' | sed 's/^TURN1=//')"
t2="$(echo "$out" | grep '^TURN2=' | sed 's/^TURN2=//')"

# ── Assertions ───────────────────────────────────────────────────────────────

[ -n "$t1" ] \
  || { echo "FAIL: turn 1 returned no transcript ($out)"; exit 1; }

[ -n "$t2" ] \
  || { echo "FAIL: turn 2 returned no transcript — receive() loop fix not in place ($out)"; exit 1; }

echo "PASS turn1=$t1"
echo "PASS turn2=$t2"
echo PASS
