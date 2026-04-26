#!/usr/bin/env python3
"""
disinto-voice bridge — Gemini Live ↔ browser voice client ↔ tiered tools.

Part of the voice interface (parent issue #651, this PR implements #662).

Scope:
    * Expose a single WebSocket endpoint on 127.0.0.1:$VOICE_PORT.
      Caddy (nomad/jobs/edge.hcl) terminates TLS and forwards /voice/ws
      to us with X-Forwarded-User stamped by the forward_auth block
      (shared with /chat/* — same OAuth session cookie gate, #709).
    * For each accepted browser connection, open a Gemini Live session
      loaded with docs/voice/SOUL_VOICE.md as the system prompt.
    * Register six tools (see SOUL_VOICE.md for routing rules):
      - `factory_state(section?)` — fast-path snapshot read, <200ms.
      - `narrate(question)` — fast-path prose summary via local llama, ~1s.
      - `think(query)` — full claude-p reasoning, 5–10s.
      - `delegate(query, context?)` — fire-and-forget detached claude-p,
        returns task-id immediately; result lands in threads store.
      - `check_inbox(min_priority?)` — read prioritized inbox items.
      - `ack_inbox(item_id, action)` — acknowledge an inbox item.
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
import pwd
import subprocess
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
    "GEMINI_LIVE_MODEL", "gemini-2.5-flash-native-audio-latest"
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

# Fast-path skills live in the chat-skills tree inside the container.
# The bridge invokes them directly (no claude -p overhead).
CHAT_SKILLS_DIR = os.environ.get(
    "CHAT_SKILLS_DIR", os.path.join(WORKSPACE_DIR, "docker/edge/chat-skills")
)
FACTORY_STATE_SH = os.environ.get(
    "FACTORY_STATE_SH",
    os.path.join(CHAT_SKILLS_DIR, "factory-state", "factory-state.sh"),
)
NARRATE_SH = os.environ.get(
    "NARRATE_SH",
    os.path.join(CHAT_SKILLS_DIR, "narrate", "narrate.sh"),
)

# Timeouts for fast-path skills (seconds). Much tighter than think.
FACTORY_STATE_TIMEOUT = int(os.environ.get("VOICE_FACTORY_STATE_TIMEOUT_SECS", "10"))
NARRATE_TIMEOUT = int(os.environ.get("VOICE_NARRATE_TIMEOUT_SECS", "15"))
CHECK_INBOX_TIMEOUT = int(os.environ.get("VOICE_CHECK_INBOX_TIMEOUT_SECS", "10"))
ACK_INBOX_TIMEOUT = int(os.environ.get("VOICE_ACK_INBOX_TIMEOUT_SECS", "10"))

# Inbox skill scripts.
CHECK_INBOX_SH = os.environ.get(
    "CHECK_INBOX_SH",
    os.path.join(CHAT_SKILLS_DIR, "check-inbox", "check-inbox.sh"),
)
ACK_INBOX_SH = os.environ.get(
    "ACK_INBOX_SH",
    os.path.join(CHAT_SKILLS_DIR, "ack-inbox", "ack-inbox.sh"),
)

# Threads root — where delegate task state lands.
THREADS_ROOT = os.environ.get("VOICE_THREADS_ROOT", "/var/lib/disinto/threads")

# drop to the unprivileged `agent` user (uid 1000) via preexec_fn before
# exec. The edge container entrypoint starts the bridge as root (to bind
# privileged ports for caddy and manage /home/agent), so each
# create_subprocess_exec of `claude` must drop to agent before exec —
# claude-code ≥ 2.1.84 refuses --permission-mode bypassPermissions when
# euid is 0. Resolved once at import.
try:
    _agent_pw = pwd.getpwnam("agent")
    _AGENT_UID = _agent_pw.pw_uid
    _AGENT_GID = _agent_pw.pw_gid
except KeyError as _agent_err:
    raise RuntimeError(
        "voice bridge requires the 'agent' user (uid 1000) in the image; "
        "see docker/edge/Dockerfile (#743)"
    ) from _agent_err


def _drop_to_agent():
    """preexec_fn: drop privileges to the agent user before exec()."""
    os.setgid(_AGENT_GID)
    os.setuid(_AGENT_UID)


# ── Claude session UUID helpers (#706) ────────────────────────────────────────

_CLAUDE_SESSION_NAMESPACE = uuid.UUID("6d436c61-7564-6553-6573-736964000000")


def _claude_session_id_for(conv_id, suffix="claude"):
    """Derive a stable UUID5 from *conv_id* + *suffix*.

    Voice uses ``suffix="voice-claude"``.  Passes through existing UUIDs
    unchanged so clients that already supply a valid UUID are not broken.
    """
    try:
        uuid.UUID(conv_id)
        return conv_id
    except ValueError:
        pass
    return str(uuid.uuid5(_CLAUDE_SESSION_NAMESPACE, f"{conv_id}-{suffix}"))


def _claude_session_flag(session_uuid, cwd=None):
    """Return ``(flag, uuid)`` for the next claude invocation.

    If the session file already exists on disk use ``-r`` (resume);
    otherwise use ``--session-id`` (create).
    """
    cfg = os.environ.get("CLAUDE_CONFIG_DIR", os.path.expanduser("~/.claude"))
    encoded = (cwd or os.getcwd()).replace("/", "-")
    sess_path = os.path.join(cfg, "projects", encoded, session_uuid + ".jsonl")
    if os.path.exists(sess_path):
        return ("-r", session_uuid)
    return ("--session-id", session_uuid)


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


# ── `factory_state` tool — fast-path snapshot read ────────────────────────────

FACTORY_STATE_TOOL_DECLARATION = {
    "name": "factory_state",
    "description": (
        "Read the current factory state from the snapshot daemon. "
        "Use for any state query — tracker status, agent status, nomad jobs, "
        "inbox items, or a specific section. Returns a concise plain-text "
        "summary plus JSON. Accepts an optional section argument: "
        "nomad, forge, agents, inbox."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "section": {
                "type": "string",
                "description": (
                    "Optional section to read: nomad, forge, agents, inbox. "
                    "Omit for a full summary."
                ),
            }
        },
        "required": [],
    },
}


# ── `narrate` tool — fast-path prose summary via local llama ──────────────────

NARRATE_TOOL_DECLARATION = {
    "name": "narrate",
    "description": (
        "Generate a TTS-friendly prose summary of the factory state in "
        "response to a natural-language question. Use for walk-throughs, "
        "explanations, and conversational summaries. The local llama model "
        "answers using the current snapshot data. Returns plain prose."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "question": {
                "type": "string",
                "description": (
                    "The natural-language question to answer with a prose summary."
                ),
            }
        },
        "required": ["question"],
    },
}


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


# ── `delegate` tool: fire-and-forget claude-p ─────────────────────────────────

DELEGATE_TOOL_DECLARATION = {
    "name": "delegate",
    "description": (
        "Fire-and-forget: spawn a detached Claude session for long-running "
        "investigations. Use when the user's request will take more than a "
        "few seconds to answer (e.g. 'why are PRs stuck?', 'audit the "
        "latest PR'). Returns immediately with a task-id; the result lands "
        "in the threads store so it can be checked later."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "query": {
                "type": "string",
                "description": (
                    "The task description the Claude session should work on."
                ),
            },
            "context": {
                "type": "string",
                "description": (
                    "Optional additional context or instructions for the "
                    "Claude session."
                ),
            },
        },
        "required": ["query"],
    },
}


# ── `check_inbox` tool — read prioritized inbox items ─────────────────────────

CHECK_INBOX_TOOL_DECLARATION = {
    "name": "check_inbox",
    "description": (
        "Read prioritized unread inbox items. Call when the user shows "
        "readiness for a context switch (see SOUL_VOICE.md). Returns "
        "empty if nothing to surface."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "min_priority": {
                "type": "string",
                "enum": ["P0", "P1", "P2"],
                "description": "Optional minimum priority. Defaults to P2 (all).",
            },
        },
        "required": [],
    },
}


# ── `ack_inbox` tool — acknowledge an inbox item ─────────────────────────────

ACK_INBOX_TOOL_DECLARATION = {
    "name": "ack_inbox",
    "description": (
        "Acknowledge an inbox item the user has acted on, dismissed, or "
        "wants to defer."
    ),
    "parameters": {
        "type": "object",
        "required": ["item_id", "action"],
        "properties": {
            "item_id": {"type": "string"},
            "action":  {"type": "string", "enum": ["dismiss", "accept", "snooze"]},
        },
    },
}


def _ensure_threads_dir(task_id):
    """Create the thread directory and return its path."""
    thread_dir = os.path.join(THREADS_ROOT, task_id)
    os.makedirs(thread_dir, exist_ok=True)
    return thread_dir


def _write_meta(task_id, meta):
    """Atomically write meta.json for a delegate task."""
    thread_dir = _ensure_threads_dir(task_id)
    meta_path = os.path.join(thread_dir, "meta.json")
    tmp_path = meta_path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp_path, meta_path)


def _update_meta(task_id, updates):
    """Merge *updates* into the existing meta.json (atomic read-modify-write)."""
    thread_dir = _ensure_threads_dir(task_id)
    meta_path = os.path.join(thread_dir, "meta.json")
    try:
        with open(meta_path, "r", encoding="utf-8") as f:
            meta = json.load(f)
    except (OSError, json.JSONDecodeError):
        meta = {"id": task_id}
    meta.update(updates)
    _write_meta(task_id, meta)


async def _spawn_delegate(query, context=""):
    """Fire-and-forget: spawn a detached claude -p session.

    Returns a dict with ``task_id`` and ``started_at`` immediately.
    The spawned process streams stdout to ``stream.jsonl`` and updates
    ``meta.json`` on exit.
    """
    task_id = f"del-{uuid.uuid4().hex[:12]}"
    started_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    # Build the full prompt from query + optional context.
    full_prompt = query
    if context:
        full_prompt = f"{query}\n\nContext:\n{context}"

    # Write initial meta.json
    _write_meta(task_id, {
        "id": task_id,
        "query": query,
        "started": started_at,
        "status": "running",
        "completed": None,
        "result_summary": None,
    })

    thread_dir = _ensure_threads_dir(task_id)
    stream_path = os.path.join(thread_dir, "stream.jsonl")

    # Build claude args (mirrors _run_think but without --session-id).
    flag, _ = _claude_session_flag(task_id, cwd=WORKSPACE_DIR)
    args = [
        CLAUDE_BIN,
        flag, task_id,
        "-p", full_prompt,
        "--output-format", "stream-json",
        "--permission-mode", "bypassPermissions",
        "--model", VOICE_CLAUDE_MODEL,
        "--verbose",
    ]
    if os.path.isfile(SOUL_THINK_PATH):
        args.extend(["--system-prompt-file", SOUL_THINK_PATH])

    # Open the stream file for writing.
    stream_fh = open(stream_path, "w", encoding="utf-8")

    _log(f"delegate: spawn {task_id} (cwd={WORKSPACE_DIR})")

    try:
        proc = await asyncio.create_subprocess_exec(
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=WORKSPACE_DIR if os.path.isdir(WORKSPACE_DIR) else None,
            preexec_fn=_drop_to_agent,
            start_new_session=True,
        )
    except FileNotFoundError:
        _update_meta(task_id, {
            "status": "failed",
            "completed": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "result_summary": "The reasoning layer is unavailable: claude binary not found.",
        })
        return {"task_id": task_id, "started_at": started_at}

    # Stream stdout to file and track process for exit callback.
    _delegate_tasks[task_id] = proc

    async def _stream():
        """Read stdout line-by-line and write to stream.jsonl."""
        try:
            while True:
                line = await proc.stdout.readline()
                if not line:
                    break
                stream_fh.write(line.decode("utf-8", errors="replace"))
                stream_fh.flush()
        except Exception as exc:
            _log(f"delegate stream error for {task_id}: {exc!r}")

    # Schedule the stream reader; on finish, update meta.
    asyncio.ensure_future(_stream_done(proc, task_id, _stream(), stream_fh, stream_path))

    return {"task_id": task_id, "started_at": started_at}


# Registry of running delegate tasks: task_id -> Process
_delegate_tasks = {}


async def _stream_done(proc, task_id, stream_coro, stream_fh, stream_path):
    """Wait for stream to finish, then update meta on exit."""
    await stream_coro
    # Wait for process to exit (stdout already drained by _stream).
    try:
        _, _ = await proc.communicate()
    except Exception as exc:
        _log(f"delegate communicate error for {task_id}: {exc!r}")

    try:
        # Re-read the stream file (double-read) so we can parse the output
        # that _stream already wrote — proc.stdout is already exhausted.
        with open(stream_path, "r", encoding="utf-8") as fh:
            stdout = fh.read()
        text = _parse_claude_stream_json(stdout)
        if not text:
            text = stdout.strip() or "The delegate session completed with no output."
        status = "completed" if proc.returncode == 0 else "failed"
        _update_meta(task_id, {
            "status": status,
            "completed": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "result_summary": text,
        })
    except Exception as exc:
        _log(f"delegate exit handler error for {task_id}: {exc!r}")
    finally:
        try:
            stream_fh.close()
        except Exception:
            pass
        _delegate_tasks.pop(task_id, None)


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


async def _run_factory_state(section=None):
    """Run factory-state.sh and return the plain-text output."""
    if not os.path.isfile(FACTORY_STATE_SH):
        return "The factory-state skill is unavailable: script not found."

    args = [FACTORY_STATE_SH]
    if section:
        args.append(section)

    _log(f"factory_state: spawn {FACTORY_STATE_SH}{' ' + section if section else ''}")

    try:
        proc = await asyncio.create_subprocess_exec(
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=WORKSPACE_DIR if os.path.isdir(WORKSPACE_DIR) else None,
            preexec_fn=_drop_to_agent,
        )
    except FileNotFoundError:
        return "The factory-state skill is unavailable: script not found."

    try:
        stdout_b, stderr_b = await asyncio.wait_for(
            proc.communicate(), timeout=FACTORY_STATE_TIMEOUT
        )
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        return "The factory-state read timed out."

    stdout = stdout_b.decode("utf-8", errors="replace") if stdout_b else ""
    stderr = stderr_b.decode("utf-8", errors="replace") if stderr_b else ""

    if proc.returncode != 0:
        _log(f"factory_state: exit={proc.returncode} stderr={stderr[:400]}")
        return "The factory-state read returned an error. Try again in a moment."

    # Script emits: text summary, blank line, JSON. Return everything as-is;
    # the voice model will naturally focus on the text summary.
    text = stdout.strip()
    if not text:
        text = "The factory-state read returned no data."

    _log(f"factory_state: ok ({len(text)} chars)")
    return text


async def _run_narrate(question):
    """Run narrate.sh and return the prose output."""
    if not os.path.isfile(NARRATE_SH):
        return "The narrate skill is unavailable: script not found."

    _log(f"narrate: spawn {NARRATE_SH}")

    try:
        proc = await asyncio.create_subprocess_exec(
            NARRATE_SH, question,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=WORKSPACE_DIR if os.path.isdir(WORKSPACE_DIR) else None,
            preexec_fn=_drop_to_agent,
        )
    except FileNotFoundError:
        return "The narrate skill is unavailable: script not found."

    try:
        stdout_b, stderr_b = await asyncio.wait_for(
            proc.communicate(), timeout=NARRATE_TIMEOUT
        )
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        return "The narrate call timed out."

    stdout = stdout_b.decode("utf-8", errors="replace") if stdout_b else ""
    stderr = stderr_b.decode("utf-8", errors="replace") if stderr_b else ""

    if proc.returncode != 0:
        _log(f"narrate: exit={proc.returncode} stderr={stderr[:400]}")
        return "The narrate call returned an error. Try again in a moment."

    text = stdout.strip()
    if not text:
        text = "I don't have a narrated answer for that yet."

    _log(f"narrate: ok ({len(text)} chars)")
    return text


async def _run_check_inbox(min_priority=None):
    """Run check-inbox.sh and return the plain-text output."""
    if not os.path.isfile(CHECK_INBOX_SH):
        return "The check-inbox skill is unavailable: script not found."

    args = [CHECK_INBOX_SH]
    if min_priority:
        args.append(min_priority)

    _log(f"check_inbox: spawn {CHECK_INBOX_SH}{' ' + min_priority if min_priority else ''}")

    try:
        proc = await asyncio.create_subprocess_exec(
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=WORKSPACE_DIR if os.path.isdir(WORKSPACE_DIR) else None,
            preexec_fn=_drop_to_agent,
        )
    except FileNotFoundError:
        return "The check-inbox skill is unavailable: script not found."

    try:
        stdout_b, stderr_b = await asyncio.wait_for(
            proc.communicate(), timeout=CHECK_INBOX_TIMEOUT
        )
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        return "The check-inbox call timed out."

    stdout = stdout_b.decode("utf-8", errors="replace") if stdout_b else ""
    stderr = stderr_b.decode("utf-8", errors="replace") if stderr_b else ""

    if proc.returncode != 0:
        _log(f"check_inbox: exit={proc.returncode} stderr={stderr[:400]}")
        return "The check-inbox call returned an error. Try again in a moment."

    text = stdout.strip()
    if not text:
        text = "Nothing to surface right now."

    _log(f"check_inbox: ok ({len(text)} chars)")
    return text


async def _run_ack_inbox(item_id, action):
    """Run ack-inbox.sh and return the plain-text output."""
    if not os.path.isfile(ACK_INBOX_SH):
        return "The ack-inbox skill is unavailable: script not found."

    _log(f"ack_inbox: spawn {ACK_INBOX_SH} item_id={item_id} action={action}")

    try:
        proc = await asyncio.create_subprocess_exec(
            ACK_INBOX_SH, item_id, action,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=WORKSPACE_DIR if os.path.isdir(WORKSPACE_DIR) else None,
            preexec_fn=_drop_to_agent,
        )
    except FileNotFoundError:
        return "The ack-inbox skill is unavailable: script not found."

    try:
        stdout_b, stderr_b = await asyncio.wait_for(
            proc.communicate(), timeout=ACK_INBOX_TIMEOUT
        )
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        return "The ack-inbox call timed out."

    stdout = stdout_b.decode("utf-8", errors="replace") if stdout_b else ""
    stderr = stderr_b.decode("utf-8", errors="replace") if stderr_b else ""

    if proc.returncode != 0:
        _log(f"ack_inbox: exit={proc.returncode} stderr={stderr[:400]}")
        return "The ack-inbox call returned an error. Try again in a moment."

    text = stdout.strip()
    if not text:
        text = "Item acknowledged."

    _log(f"ack_inbox: ok ({len(text)} chars)")
    return text


async def _run_think(query, claude_session_id):
    """Spawn `claude <flag> <session> -p <query>` and return the text reply."""
    if not os.path.exists(CLAUDE_BIN):
        return "The reasoning layer is unavailable: claude binary not found."

    flag, session_uuid = _claude_session_flag(claude_session_id, cwd=WORKSPACE_DIR)
    args = [
        CLAUDE_BIN,
        flag, session_uuid,
        "-p", query,
        "--output-format", "stream-json",
        "--permission-mode", "bypassPermissions",
        "--model", VOICE_CLAUDE_MODEL,
        "--verbose",
    ]
    if os.path.isfile(SOUL_THINK_PATH):
        args.extend(["--system-prompt-file", SOUL_THINK_PATH])

    _log(f"think: spawn claude {flag} {session_uuid} (cwd={WORKSPACE_DIR})")

    try:
        proc = await asyncio.create_subprocess_exec(
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=WORKSPACE_DIR if os.path.isdir(WORKSPACE_DIR) else None,
            preexec_fn=_drop_to_agent,
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
        self._activity_open = False

    def _derive_claude_session_id(self, conv_id):
        # Siblings with chat's "<conv_id>-claude" (see docker/chat/server.py).
        # Keeping the suffix distinct prevents voice-layer chatter from
        # polluting the text-chat claude memory by default — the client
        # may pass "<conv_id>-claude" explicitly to opt into shared
        # context.
        if not conv_id:
            conv_id = uuid.uuid4().hex[:12]
        return _claude_session_id_for(conv_id, suffix="voice-claude")

    async def _handle_client_frame(self, frame, live_session):
        """Route a single incoming frame from the browser."""
        # Binary frame → audio sample bytes → forward to Gemini Live.
        # Use send_realtime_input + activity bracketing for native-audio
        # models (gemini-2.5-flash-native-audio-latest). The legacy
        # send(input=Blob, end_of_turn=False) call silently no-ops on
        # native-audio models — Gemini receives no audio. Manual activity
        # bracketing requires server VAD disabled (see LiveConnectConfig).
        if isinstance(frame, (bytes, bytearray)):
            if not self._activity_open:
                await live_session.send_realtime_input(
                    activity_start=genai_types.ActivityStart(),
                )
                self._activity_open = True
            await live_session.send_realtime_input(
                audio=genai_types.Blob(
                    data=bytes(frame),
                    # The browser client is expected to send PCM16 mono
                    # 16kHz (matches Gemini Live's audio input contract).
                    mime_type="audio/pcm;rate=16000",
                ),
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
                await live_session.send_client_content(
                    turns=genai_types.Content(
                        role="user",
                        parts=[genai_types.Part(text=content)],
                    ),
                    turn_complete=True,
                )
        elif mtype == "end_of_turn":
            if self._activity_open:
                await live_session.send_realtime_input(
                    activity_end=genai_types.ActivityEnd(),
                )
                self._activity_open = False
            return
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

            # Native-audio models surface transcripts via
            # server_content.{output,input}_transcription.text. Forward
            # both to the browser tagged with their source so the UI can
            # render Gemini's speech alongside the user's transcribed
            # mic input.
            sc = getattr(response, "server_content", None)
            if sc is not None:
                for attr, kind in (
                    ("output_transcription", "transcript"),
                    ("input_transcription", "transcript"),
                ):
                    tr = getattr(sc, attr, None)
                    tr_text = getattr(tr, "text", None) if tr is not None else None
                    if tr_text:
                        try:
                            await self.ws.send(json.dumps({
                                "type": kind,
                                "text": tr_text,
                                "source": attr.replace("_transcription", ""),
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

            if name == "factory_state":
                section = (isinstance(args, dict)
                           and str(args.get("section", "")).strip()) or None
                result_text = await _run_factory_state(section)

            elif name == "narrate":
                query = ""
                if isinstance(args, dict):
                    query = str(args.get("question", "")).strip()
                if not query:
                    function_responses.append(genai_types.FunctionResponse(
                        id=call_id,
                        name=name,
                        response={"error": "missing required arg: question"},
                    ))
                    continue
                result_text = await _run_narrate(query)

            elif name == "think":
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

            elif name == "delegate":
                query = ""
                context = ""
                if isinstance(args, dict):
                    query = str(args.get("query", "")).strip()
                    context = str(args.get("context", "")).strip()
                if not query:
                    function_responses.append(genai_types.FunctionResponse(
                        id=call_id,
                        name=name,
                        response={"error": "missing required arg: query"},
                    ))
                    continue

                result = await _spawn_delegate(query, context)
                result_text = (
                    f"Delegated. Task id: {result['task_id']} "
                    f"(started {result['started_at']}). "
                    "I'll let you know when it's done."
                )

            elif name == "check_inbox":
                min_priority = None
                if isinstance(args, dict):
                    min_priority = str(args.get("min_priority", "")).strip() or None
                result_text = await _run_check_inbox(min_priority)

            elif name == "ack_inbox":
                item_id = ""
                action = ""
                if isinstance(args, dict):
                    item_id = str(args.get("item_id", "")).strip()
                    action = str(args.get("action", "")).strip()
                if not item_id or action not in ("dismiss", "accept", "snooze"):
                    function_responses.append(genai_types.FunctionResponse(
                        id=call_id,
                        name=name,
                        response={
                            "error": "missing required args: item_id and action (dismiss|accept|snooze)",
                        },
                    ))
                    continue
                result_text = await _run_ack_inbox(item_id, action)

            else:
                _log(f"unknown tool call name={name!r} — returning error")
                function_responses.append(genai_types.FunctionResponse(
                    id=call_id,
                    name=name,
                    response={"error": f"unknown tool {name}"},
                ))
                continue

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
            output_audio_transcription=genai_types.AudioTranscriptionConfig(),
            input_audio_transcription=genai_types.AudioTranscriptionConfig(),
            # Disable server VAD — required for manual activity_start /
            # activity_end bracketing in send_realtime_input. Without this
            # Gemini rejects the manual activity_* calls with code 11007.
            realtime_input_config=genai_types.RealtimeInputConfig(
                automatic_activity_detection=genai_types.AutomaticActivityDetection(
                    disabled=True,
                ),
            ),
            system_instruction=genai_types.Content(
                parts=[genai_types.Part(text=self.soul_voice_prompt)]
            ),
            tools=[genai_types.Tool(
                function_declarations=[
                    genai_types.FunctionDeclaration(**FACTORY_STATE_TOOL_DECLARATION),
                    genai_types.FunctionDeclaration(**NARRATE_TOOL_DECLARATION),
                    genai_types.FunctionDeclaration(**THINK_TOOL_DECLARATION),
                    genai_types.FunctionDeclaration(**DELEGATE_TOOL_DECLARATION),
                    genai_types.FunctionDeclaration(**CHECK_INBOX_TOOL_DECLARATION),
                    genai_types.FunctionDeclaration(**ACK_INBOX_TOOL_DECLARATION),
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
    _log(f"gemini live: model={GEMINI_MODEL} api=v1beta")

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
