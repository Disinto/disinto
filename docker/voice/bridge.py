#!/usr/bin/env python3
"""
disinto-voice bridge — Gemini Live ↔ browser voice client ↔ `think` tool.

Part of the voice interface (parent issue #651, this PR implements #662).

Scope:
    * Expose a single WebSocket endpoint on 127.0.0.1:$VOICE_PORT.
      Caddy (nomad/jobs/edge.hcl) terminates TLS and forwards /voice/ws
      to us with X-Forwarded-User stamped by the forward_auth block
      (shared with /chat/* — same OAuth session cookie gate, #709).
    * For each accepted browser connection, open a Gemini Live session
      loaded with docs/voice/SOUL_VOICE.md as the system prompt.
    * Register a single `think` tool whose handler runs
          claude -r <session-id> -p <query> \
                 --system-prompt-file docs/voice/SOUL_THINK.md \
                 --output-format stream-json
      and returns the collected text to Gemini Live as the function
      response. Gemini speaks the reply verbatim (see SOUL_VOICE.md).
    * Proxy audio frames (opaque binary) between the browser and Gemini
      Live in both directions.

Session-id convention (reuses #649 chat-session plumbing):
    conv_id arrives from the browser in the first text frame:
        {"type": "hello", "conversation_id": "<12-hex>"}
    chat uses "<conv_id>-claude"; voice uses "<conv_id>-voice-claude"
    so text and voice are siblings under the same conv_id but have
    independent claude session memory. A client that passes the same
    id to both surfaces gets sibling contexts; a client that wants to
    share context can send "conversation_id": "<conv_id>-claude"
    (matching chat's derived id) — the bridge does not mangle the
    value, it only defaults the "-voice-claude" suffix when the
    browser does not provide one.

GEMINI_API_KEY handling:
    The Nomad edge.hcl template writes the key to /secrets/gemini-api-key
    (perms 0400, owned by the caddy task). entrypoint-edge.sh exports
    GEMINI_API_KEY_FILE=/secrets/gemini-api-key into the bridge's child
    env ONLY — the chat subprocess never sees the file path or the key
    (see docs/voice/README.md "Gemini API key" section).
"""

import argparse
import asyncio
import json
import os
import sys
import time
import uuid

try:
    import websockets
    from websockets.server import serve as ws_serve
except ImportError as exc:  # pragma: no cover — surface a readable error
    print(f"voice: missing websockets package: {exc}", file=sys.stderr)
    raise

try:
    from google import genai
    from google.genai import types as genai_types
except ImportError as exc:  # pragma: no cover
    print(f"voice: missing google-genai package: {exc}", file=sys.stderr)
    raise


# ── Configuration ────────────────────────────────────────────────────────────
HOST = os.environ.get("VOICE_HOST", "127.0.0.1")
PORT = int(os.environ.get("VOICE_PORT", "8090"))

CLAUDE_BIN = os.environ.get("CLAUDE_BIN", "/usr/local/bin/claude")

# Workspace directory for the `claude -p` child. Matches the chat
# subprocess default so /opt/disinto (the factory source) is the cwd
# when claude reads project files.
WORKSPACE_DIR = os.environ.get("CHAT_WORKSPACE_DIR", "/opt/disinto")

# SOUL_* prompts live in the repo clone inside the container. The repo
# is cloned to /opt/disinto by entrypoint-edge.sh before the bridge
# starts. Paths are overridable for local dev where the repo lives
# somewhere else.
SOUL_VOICE_PATH = os.environ.get(
    "SOUL_VOICE_PATH", os.path.join(WORKSPACE_DIR, "docs/voice/SOUL_VOICE.md")
)
SOUL_THINK_PATH = os.environ.get(
    "SOUL_THINK_PATH", os.path.join(WORKSPACE_DIR, "docs/voice/SOUL_THINK.md")
)

# Gemini Live model. Overridable so ops can swap without a code change.
GEMINI_MODEL = os.environ.get(
    "GEMINI_LIVE_MODEL", "gemini-2.0-flash-live-001"
)

# Claude model used for the `think` backing call. Tracks the chat subprocess
# (#648) so voice and text think with the same model family by default.
VOICE_CLAUDE_MODEL = os.environ.get(
    "VOICE_CLAUDE_MODEL",
    os.environ.get("CHAT_CLAUDE_MODEL", "claude-opus-4-7"),
)

# Allow subprotocol negotiation so the browser client can pin a version.
WEBSOCKET_SUBPROTOCOL = "voice-stream-v1"

# Max time to wait for a single `think` tool call. Voice latency budget
# is tight; longer thinks should be rare and will surface an error frame
# to the client so the voice model can acknowledge and move on.
THINK_TIMEOUT_SECS = int(os.environ.get("VOICE_THINK_TIMEOUT_SECS", "60"))


def _load_gemini_api_key():
    """Resolve GEMINI_API_KEY from env or from the Vault-rendered file.

    docs/voice/README.md pins the file-over-env contract: the Nomad task
    env MUST NOT carry GEMINI_API_KEY (the chat subprocess would inherit
    it). The bridge launcher reads GEMINI_API_KEY_FILE and scopes the
    key into its own child env only.
    """
    direct = os.environ.get("GEMINI_API_KEY", "").strip()
    if direct:
        return direct
    path = os.environ.get("GEMINI_API_KEY_FILE", "")
    if path and os.path.isfile(path):
        try:
            with open(path, "r", encoding="utf-8") as fh:
                return fh.read().strip()
        except OSError as exc:
            print(f"voice: failed to read {path}: {exc}", file=sys.stderr)
    return ""


def _load_file(path, label):
    """Read a SOUL_* markdown file; return empty string + warn on failure."""
    if not path or not os.path.isfile(path):
        print(f"voice: {label} not found at {path}", file=sys.stderr)
        return ""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read()
    except OSError as exc:
        print(f"voice: failed to read {label} at {path}: {exc}", file=sys.stderr)
        return ""


def _log(msg):
    print(f"[{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}] voice: {msg}",
          file=sys.stderr, flush=True)


# ── `think` tool: claude -r <session> -p <query> ─────────────────────────────

THINK_TOOL_DECLARATION = {
    "name": "think",
    "description": (
        "Delegate reasoning to the project's Claude-backed thinker. "
        "Call for anything requiring analysis, project knowledge, a "
        "recommendation, or a factual claim you are not certain of. "
        "Returns plain prose the voice layer speaks verbatim."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "query": {
                "type": "string",
                "description": (
                    "The transcribed user request, rewritten as a "
                    "self-contained question for the reasoning layer."
                ),
            }
        },
        "required": ["query"],
    },
}


def _parse_claude_stream_json(output):
    """Return the concatenated assistant text from a stream-json stdout."""
    parts = []
    for line in output.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        etype = event.get("type", "")
        if etype == "content_block_delta":
            delta = event.get("delta", {})
            if delta.get("type") == "text_delta":
                parts.append(delta.get("text", ""))
        elif etype == "assistant":
            content = event.get("content", "")
            if isinstance(content, str):
                parts.append(content)
            elif isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("text"):
                        parts.append(block["text"])
        elif etype == "result":
            # Some builds emit a final "result" with the full text.
            result_text = event.get("result", "")
            if isinstance(result_text, str) and result_text and not parts:
                parts.append(result_text)
    return "".join(parts).strip()


async def _run_think(query, claude_session_id):
    """Spawn `claude -r <session> -p <query>` and return the text reply."""
    if not os.path.exists(CLAUDE_BIN):
        return "The reasoning layer is unavailable: claude binary not found."

    args = [
        CLAUDE_BIN,
        "-r", claude_session_id,
        "-p", query,
        "--output-format", "stream-json",
        "--permission-mode", "acceptEdits",
        "--model", VOICE_CLAUDE_MODEL,
    ]
    if os.path.isfile(SOUL_THINK_PATH):
        args.extend(["--system-prompt-file", SOUL_THINK_PATH])

    _log(f"think: spawn claude -r {claude_session_id} (cwd={WORKSPACE_DIR})")

    try:
        proc = await asyncio.create_subprocess_exec(
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=WORKSPACE_DIR if os.path.isdir(WORKSPACE_DIR) else None,
        )
    except FileNotFoundError:
        return "The reasoning layer is unavailable: claude binary not found."

    try:
        stdout_b, stderr_b = await asyncio.wait_for(
            proc.communicate(), timeout=THINK_TIMEOUT_SECS
        )
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        return "The reasoning layer timed out. Try a narrower question."

    stdout = stdout_b.decode("utf-8", errors="replace") if stdout_b else ""
    stderr = stderr_b.decode("utf-8", errors="replace") if stderr_b else ""

    if proc.returncode != 0:
        _log(f"think: claude exit={proc.returncode} stderr={stderr[:400]}")
        return (
            "The reasoning layer returned an error. "
            "Ask again in a moment."
        )

    text = _parse_claude_stream_json(stdout)
    if not text:
        # Fall back to raw stdout if stream-json parsing produced nothing.
        text = stdout.strip() or "I don't have an answer for that yet."

    _log(f"think: ok ({len(text)} chars)")
    return text


# ── Per-connection bridge session ────────────────────────────────────────────

class VoiceSession:
    """Proxies one browser WebSocket to one Gemini Live session."""

    def __init__(self, ws, user, soul_voice_prompt, gemini_client):
        self.ws = ws
        self.user = user
        self.soul_voice_prompt = soul_voice_prompt
        self.gemini_client = gemini_client
        # conv_id comes from the browser "hello" frame; fall back to a
        # fresh uuid so every session has stable claude-session plumbing.
        self.conv_id = None
        self.claude_session_id = None

    def _derive_claude_session_id(self, conv_id):
        # Siblings with chat's "<conv_id>-claude" (see docker/chat/server.py).
        # Keeping the suffix distinct prevents voice-layer chatter from
        # polluting the text-chat claude memory by default — the client
        # may pass "<conv_id>-claude" explicitly to opt into shared
        # context.
        if not conv_id:
            conv_id = uuid.uuid4().hex[:12]
        if conv_id.endswith("-voice-claude") or conv_id.endswith("-claude"):
            return conv_id
        return f"{conv_id}-voice-claude"

    async def _handle_client_frame(self, frame, live_session):
        """Route a single incoming frame from the browser."""
        # Binary frame → audio sample bytes → forward to Gemini Live.
        if isinstance(frame, (bytes, bytearray)):
            await live_session.send(
                input=genai_types.Blob(
                    data=bytes(frame),
                    # The browser client is expected to send PCM16 mono
                    # 16kHz (matches Gemini Live's audio input contract).
                    mime_type="audio/pcm;rate=16000",
                ),
                end_of_turn=False,
            )
            return

        # Text frame → control/handshake message (JSON).
        try:
            data = json.loads(frame)
        except (json.JSONDecodeError, TypeError):
            _log(f"drop non-json text frame from user={self.user}")
            return

        mtype = data.get("type", "")
        if mtype == "hello":
            self.conv_id = data.get("conversation_id") or uuid.uuid4().hex[:12]
            self.claude_session_id = self._derive_claude_session_id(self.conv_id)
            _log(
                f"hello: user={self.user} conv_id={self.conv_id} "
                f"claude_session={self.claude_session_id}"
            )
            await self.ws.send(json.dumps({
                "type": "ready",
                "conversation_id": self.conv_id,
                "claude_session_id": self.claude_session_id,
            }))
        elif mtype == "text":
            # Optional text-in path (debug / wscat): inject as user text.
            content = data.get("content", "")
            if content:
                await live_session.send(input=content, end_of_turn=True)
        elif mtype == "end_of_turn":
            await live_session.send(input=".", end_of_turn=True)
        else:
            _log(f"unknown client frame type={mtype!r} (ignored)")

    async def _pump_client_to_live(self, live_session):
        """Read frames from the browser forever; forward each to Gemini."""
        try:
            async for frame in self.ws:
                await self._handle_client_frame(frame, live_session)
        except websockets.exceptions.ConnectionClosed:
            _log(f"client closed (user={self.user})")

    async def _pump_live_to_client(self, live_session):
        """Read events from Gemini; forward audio bytes + dispatch tools."""
        async for response in live_session.receive():
            # Gemini Live returns audio chunks as server_content.model_turn
            # parts. The new SDK exposes them as `response.data` for audio
            # and `response.text` for text; older paths may use
            # `response.server_content`. We handle both without branching
            # into SDK internals.
            audio = getattr(response, "data", None)
            if audio:
                try:
                    await self.ws.send(bytes(audio))
                except websockets.exceptions.ConnectionClosed:
                    return

            text = getattr(response, "text", None)
            if text:
                try:
                    await self.ws.send(json.dumps({
                        "type": "transcript",
                        "text": text,
                    }))
                except websockets.exceptions.ConnectionClosed:
                    return

            # Tool call dispatch. The SDK delivers these either at the
            # top level (`response.tool_call`) or folded into
            # `server_content`.
            tool_call = getattr(response, "tool_call", None)
            if tool_call:
                await self._dispatch_tool_call(tool_call, live_session)

    async def _dispatch_tool_call(self, tool_call, live_session):
        """Execute a tool call from Gemini and send the response back."""
        function_responses = []
        for call in getattr(tool_call, "function_calls", []) or []:
            name = getattr(call, "name", "")
            args = getattr(call, "args", {}) or {}
            call_id = getattr(call, "id", None) or name

            if name != "think":
                _log(f"unknown tool call name={name!r} — returning error")
                function_responses.append(genai_types.FunctionResponse(
                    id=call_id,
                    name=name,
                    response={"error": f"unknown tool {name}"},
                ))
                continue

            query = ""
            if isinstance(args, dict):
                query = str(args.get("query", "")).strip()
            if not query:
                function_responses.append(genai_types.FunctionResponse(
                    id=call_id,
                    name=name,
                    response={"error": "missing required arg: query"},
                ))
                continue

            # Notify the browser the bridge is thinking so UIs can show
            # a transient indicator. The voice layer is still free to
            # say "one moment" on its own per SOUL_VOICE.md.
            try:
                await self.ws.send(json.dumps({
                    "type": "think_start",
                    "query": query,
                }))
            except websockets.exceptions.ConnectionClosed:
                return

            claude_session = self.claude_session_id or self._derive_claude_session_id(None)
            result_text = await _run_think(query, claude_session)

            try:
                await self.ws.send(json.dumps({
                    "type": "think_end",
                    "length": len(result_text),
                }))
            except websockets.exceptions.ConnectionClosed:
                return

            function_responses.append(genai_types.FunctionResponse(
                id=call_id,
                name=name,
                response={"result": result_text},
            ))

        if function_responses:
            await live_session.send(
                input=genai_types.LiveClientToolResponse(
                    function_responses=function_responses,
                )
            )

    async def run(self):
        """Open the Gemini Live session and pump frames in both directions."""
        config = genai_types.LiveConnectConfig(
            response_modalities=[genai_types.Modality.AUDIO],
            system_instruction=genai_types.Content(
                parts=[genai_types.Part(text=self.soul_voice_prompt)]
            ),
            tools=[genai_types.Tool(
                function_declarations=[
                    genai_types.FunctionDeclaration(**THINK_TOOL_DECLARATION)
                ],
            )],
        )

        try:
            async with self.gemini_client.aio.live.connect(
                model=GEMINI_MODEL, config=config
            ) as live_session:
                _log(f"gemini live session open (model={GEMINI_MODEL})")
                await asyncio.gather(
                    self._pump_client_to_live(live_session),
                    self._pump_live_to_client(live_session),
                )
        except Exception as exc:  # pragma: no cover — surface + close cleanly
            _log(f"gemini live error: {exc!r}")
            try:
                await self.ws.send(json.dumps({
                    "type": "error",
                    "message": f"gemini live: {exc}",
                }))
            except websockets.exceptions.ConnectionClosed:
                pass
            raise


# ── WebSocket server ─────────────────────────────────────────────────────────

async def _handle_ws(ws, path, *, soul_voice_prompt, gemini_client):
    # Caddy's forward_auth stamps X-Forwarded-User when the OAuth session
    # cookie is valid (#709). The bridge only ever sees authenticated
    # requests, but we still read the header for per-session logging and
    # to fail-closed if Caddy is misconfigured and forwards raw traffic.
    headers = getattr(ws, "request_headers", None) or {}
    user = headers.get("X-Forwarded-User", "")
    if not user:
        _log("reject: missing X-Forwarded-User (Caddy forward_auth misconfig?)")
        try:
            await ws.close(code=4401, reason="unauthenticated")
        except Exception:
            pass
        return

    if path not in ("/voice/ws", "/ws", "/voice"):
        _log(f"reject: unknown path {path!r} from user={user}")
        try:
            await ws.close(code=4404, reason="not found")
        except Exception:
            pass
        return

    _log(f"connect: user={user} path={path}")
    session = VoiceSession(ws, user, soul_voice_prompt, gemini_client)
    try:
        await session.run()
    except Exception as exc:
        _log(f"session error user={user}: {exc!r}")
    finally:
        _log(f"disconnect: user={user}")


async def _main_async():
    api_key = _load_gemini_api_key()
    if not api_key or api_key == "seed-me":
        _log(
            "FATAL: GEMINI_API_KEY unavailable (neither env nor "
            "GEMINI_API_KEY_FILE set). Seed via `disinto vault reseed-voice`."
        )
        # Do NOT start the server — Caddy will return 502 for /voice/ws,
        # which is the expected behavior when the key is unseeded.
        return 1

    soul_voice_prompt = _load_file(SOUL_VOICE_PATH, "SOUL_VOICE.md")
    if not soul_voice_prompt:
        _log("FATAL: SOUL_VOICE.md unavailable — refusing to start")
        return 1

    # Scope the API key to the gemini client + this process; do NOT
    # export it into the wider env where subprocesses could inherit it.
    gemini_client = genai.Client(
        api_key=api_key,
        http_options=genai_types.HttpOptions(api_version="v1beta"),
    )

    async def handler(ws, path):
        await _handle_ws(
            ws, path,
            soul_voice_prompt=soul_voice_prompt,
            gemini_client=gemini_client,
        )

    _log(f"listening on {HOST}:{PORT} (subprotocol={WEBSOCKET_SUBPROTOCOL})")
    async with ws_serve(
        handler,
        HOST,
        PORT,
        subprotocols=[WEBSOCKET_SUBPROTOCOL],
        max_size=4 * 1024 * 1024,  # cap oversized frames (4 MiB)
        ping_interval=20,
        ping_timeout=20,
    ):
        await asyncio.Future()  # run forever
    return 0


def main():
    ap = argparse.ArgumentParser(description="disinto voice bridge")
    ap.add_argument("--check-config", action="store_true",
                    help="Validate env + SOUL_VOICE.md without opening a socket")
    args = ap.parse_args()

    if args.check_config:
        ok = True
        if not _load_gemini_api_key():
            print("missing GEMINI_API_KEY / GEMINI_API_KEY_FILE", file=sys.stderr)
            ok = False
        if not os.path.isfile(SOUL_VOICE_PATH):
            print(f"missing SOUL_VOICE.md at {SOUL_VOICE_PATH}", file=sys.stderr)
            ok = False
        if not os.path.isfile(SOUL_THINK_PATH):
            print(f"missing SOUL_THINK.md at {SOUL_THINK_PATH}", file=sys.stderr)
            ok = False
        return 0 if ok else 1

    try:
        return asyncio.run(_main_async()) or 0
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
