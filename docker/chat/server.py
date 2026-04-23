#!/usr/bin/env python3
"""
disinto-chat server — minimal HTTP backend for Claude chat UI.

Routes:
    GET /chat/auth/verify    -> Caddy forward_auth callback (returns 200+X-Forwarded-User or 401)
    GET /chat/login          -> 302 to Forgejo OAuth authorize
    GET /chat/oauth/callback -> exchange code for token, validate user, set session
    GET /chat/               -> serves index.html (session required)
    GET /chat/static/*       -> serves static assets (session required)
    POST /chat               -> spawns `claude -r <session-id> -p <msg>` with user message (session required)
    GET /ws                  -> reserved for future streaming upgrade (returns 501)

OAuth flow:
    1. User hits any /chat/* route without a valid session cookie -> 302 /chat/login
    2. /chat/login redirects to Forgejo /login/oauth/authorize
    3. Forgejo redirects back to /chat/oauth/callback with ?code=...&state=...
    4. Server exchanges code for access token, fetches /api/v1/user
    5. Asserts user is in allowlist, sets HttpOnly session cookie
    6. Redirects to /chat/

The claude binary is expected to be mounted from the host at /usr/local/bin/claude.

Workspace access:
    - CHAT_WORKSPACE_DIR environment variable: bind-mounted project working tree
    - Claude invocation uses --permission-mode acceptEdits for code modification
    - CWD is set to workspace directory when configured, enabling Claude to
      inspect, explain, or modify code scoped to that tree only
"""

import asyncio
import json
import os
import re
import secrets
import subprocess
import sys
import time
import threading
import uuid
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from urllib.parse import urlparse, parse_qs, urlencode
import socket
import struct
import base64
import hashlib

# Configuration
HOST = os.environ.get("CHAT_HOST", "127.0.0.1")
PORT = int(os.environ.get("CHAT_PORT", 8080))
UI_DIR = "/var/chat/ui"
STATIC_DIR = os.path.join(UI_DIR, "static")
CLAUDE_BIN = "/usr/local/bin/claude"

# Workspace directory: bind-mounted project working tree for Claude access.
# Default /opt/disinto so chat-Claude acts as a factory operator (#650); this
# is the factory source clone inside the edge container. Override via env for
# local dev or alternate workspace bind-mounts.
WORKSPACE_DIR = os.environ.get("CHAT_WORKSPACE_DIR", "/opt/disinto")

# Claude model pinned for the chat subprocess (#648). Defaults to Opus 4.7 —
# overridable via CHAT_CLAUDE_MODEL so ops can swap the model without a
# code change (e.g. to roll back after a bad release).
CHAT_CLAUDE_MODEL = os.environ.get("CHAT_CLAUDE_MODEL", "claude-opus-4-7")

# OAuth configuration
FORGE_URL = os.environ.get("FORGE_URL", "http://localhost:3000")
CHAT_OAUTH_CLIENT_ID = os.environ.get("CHAT_OAUTH_CLIENT_ID", "")
CHAT_OAUTH_CLIENT_SECRET = os.environ.get("CHAT_OAUTH_CLIENT_SECRET", "")
EDGE_TUNNEL_FQDN = os.environ.get("EDGE_TUNNEL_FQDN", "")
EDGE_TUNNEL_FQDN_CHAT = os.environ.get("EDGE_TUNNEL_FQDN_CHAT", "")
EDGE_ROUTING_MODE = os.environ.get("EDGE_ROUTING_MODE", "subpath")

# Shared secret for Caddy forward_auth verify endpoint (#709).
# When set, only requests carrying this value in X-Forward-Auth-Secret are
# allowed to call /chat/auth/verify.  When empty the endpoint is unrestricted
# (acceptable during local dev; production MUST set this).
FORWARD_AUTH_SECRET = os.environ.get("FORWARD_AUTH_SECRET", "")


# Allowed users - disinto-admin always allowed; CSV allowlist extends it
_allowed_csv = os.environ.get("DISINTO_CHAT_ALLOWED_USERS", "")
ALLOWED_USERS = {"disinto-admin"}
if _allowed_csv:
    ALLOWED_USERS.update(u.strip() for u in _allowed_csv.split(",") if u.strip())

# Session cookie name
SESSION_COOKIE = "disinto_chat_session"

# Session TTL: 24 hours
SESSION_TTL = 24 * 60 * 60

# Chat history directory (bind-mounted from host)
CHAT_HISTORY_DIR = os.environ.get("CHAT_HISTORY_DIR", "/var/lib/chat/history")

# Regex for valid conversation_id (12-char hex, no slashes)
CONVERSATION_ID_PATTERN = re.compile(r"^[0-9a-f]{12}$")

# In-memory session store: token -> {"user": str, "expires": float}
_sessions = {}

# Pending OAuth state tokens: state -> expires (float)
_oauth_states = {}


# WebSocket message queues per user
# user -> asyncio.Queue (for streaming messages to connected clients)
_websocket_queues = {}

# MIME types for static files
MIME_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
}

# WebSocket subprotocol for chat streaming
WEBSOCKET_SUBPROTOCOL = "chat-stream-v1"

# WebSocket opcodes
OPCODE_CONTINUATION = 0x0
OPCODE_TEXT = 0x1
OPCODE_BINARY = 0x2
OPCODE_CLOSE = 0x8
OPCODE_PING = 0x9
OPCODE_PONG = 0xA


def _build_callback_uri():
    """Build the OAuth callback URI based on tunnel configuration."""
    if EDGE_ROUTING_MODE == "subdomain" and EDGE_TUNNEL_FQDN_CHAT:
        return f"https://{EDGE_TUNNEL_FQDN_CHAT}/oauth/callback"
    if EDGE_TUNNEL_FQDN:
        return f"https://{EDGE_TUNNEL_FQDN}/chat/oauth/callback"
    return "http://localhost/chat/oauth/callback"


def _session_cookie_flags():
    """Return cookie flags appropriate for the deployment mode."""
    flags = "HttpOnly; SameSite=Lax; Path=/chat"
    if EDGE_TUNNEL_FQDN:
        flags += "; Secure"
    return flags


def _validate_session(cookie_header):
    """Check session cookie and return (username, session_id) if valid, else (None, None)."""
    if not cookie_header:
        return None, None
    for part in cookie_header.split(";"):
        part = part.strip()
        if part.startswith(SESSION_COOKIE + "="):
            token = part[len(SESSION_COOKIE) + 1:]
            session = _sessions.get(token)
            if session and session["expires"] > time.time():
                return session["user"], session.get("session_id")
            # Expired - clean up
            _sessions.pop(token, None)
            return None, None
    return None, None


def _gc_sessions():
    """Remove expired sessions (called opportunistically)."""
    now = time.time()
    expired = [k for k, v in _sessions.items() if v["expires"] <= now]
    for k in expired:
        del _sessions[k]
    expired_states = [k for k, v in _oauth_states.items() if v <= now]
    for k in expired_states:
        del _oauth_states[k]


def _exchange_code_for_token(code):
    """Exchange an authorization code for an access token via Forgejo."""
    import urllib.request
    import urllib.error

    data = urlencode({
        "grant_type": "authorization_code",
        "code": code,
        "client_id": CHAT_OAUTH_CLIENT_ID,
        "client_secret": CHAT_OAUTH_CLIENT_SECRET,
        "redirect_uri": _build_callback_uri(),
    }).encode()

    req = urllib.request.Request(
        f"{FORGE_URL}/login/oauth/access_token",
        data=data,
        headers={"Accept": "application/json", "Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode())
    except (urllib.error.URLError, json.JSONDecodeError, OSError) as e:
        print(f"OAuth token exchange failed: {e}", file=sys.stderr)
        return None


def _fetch_user(access_token):
    """Fetch the authenticated user from Forgejo API."""
    import urllib.request
    import urllib.error

    req = urllib.request.Request(
        f"{FORGE_URL}/api/v1/user",
        headers={"Authorization": f"token {access_token}", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode())
    except (urllib.error.URLError, json.JSONDecodeError, OSError) as e:
        print(f"User fetch failed: {e}", file=sys.stderr)
        return None



def _parse_stream_json(output):
    """Parse stream-json output from claude --print.

    Returns (text_content, total_tokens).  Falls back gracefully if the
    usage event is absent or malformed.
    """
    text_parts = []
    total_tokens = 0

    for line in output.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue

        etype = event.get("type", "")

        # Collect assistant text
        if etype == "content_block_delta":
            delta = event.get("delta", {})
            if delta.get("type") == "text_delta":
                text_parts.append(delta.get("text", ""))
        elif etype == "assistant":
            # Full assistant message (non-streaming)
            content = event.get("content", "")
            if isinstance(content, str) and content:
                text_parts.append(content)
            elif isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("text"):
                        text_parts.append(block["text"])

        # Parse usage from result event
        if etype == "result":
            usage = event.get("usage", {})
            total_tokens = usage.get("input_tokens", 0) + usage.get("output_tokens", 0)
        elif "usage" in event:
            usage = event["usage"]
            if isinstance(usage, dict):
                total_tokens = usage.get("input_tokens", 0) + usage.get("output_tokens", 0)

    return "".join(text_parts), total_tokens


# =============================================================================
# WebSocket Handler Class
# =============================================================================

class _WebSocketHandler:
    """Handle WebSocket connections for chat streaming."""

    def __init__(self, reader, writer, user, message_queue, conv_id=None):
        self.reader = reader
        self.writer = writer
        self.user = user
        self.message_queue = message_queue
        self.conv_id = conv_id
        self.closed = False

    async def accept_connection(self, sec_websocket_key, sec_websocket_protocol=None):
        """Accept the WebSocket handshake.

        The HTTP request has already been parsed by BaseHTTPRequestHandler,
        so we use the provided key and protocol instead of re-reading from socket.
        """
        # Validate subprotocol
        if sec_websocket_protocol and sec_websocket_protocol != WEBSOCKET_SUBPROTOCOL:
            self._send_http_error(
                400,
                "Bad Request",
                f"Unsupported subprotocol. Expected: {WEBSOCKET_SUBPROTOCOL}",
            )
            self._close_connection()
            return False

        # Generate accept key
        accept_key = self._generate_accept_key(sec_websocket_key)

        # Send handshake response
        response = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept_key}\r\n"
        )

        if sec_websocket_protocol:
            response += f"Sec-WebSocket-Protocol: {sec_websocket_protocol}\r\n"

        response += "\r\n"
        self.writer.write(response.encode("utf-8"))
        await self.writer.drain()
        return True

    def _generate_accept_key(self, sec_key):
        """Generate the Sec-WebSocket-Accept key."""
        GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        combined = sec_key + GUID
        sha1 = hashlib.sha1(combined.encode("utf-8"))
        return base64.b64encode(sha1.digest()).decode("utf-8")

    async def _read_line(self):
        """Read a line from the socket."""
        data = await self.reader.read(1)
        line = ""
        while data:
            if data == b"\r":
                data = await self.reader.read(1)
                continue
            if data == b"\n":
                return line
            line += data.decode("utf-8", errors="replace")
            data = await self.reader.read(1)
        return line

    def _send_http_error(self, code, title, message):
        """Send an HTTP error response."""
        response = (
            f"HTTP/1.1 {code} {title}\r\n"
            "Content-Type: text/plain; charset=utf-8\r\n"
            "Content-Length: " + str(len(message)) + "\r\n"
            "\r\n"
            + message
        )
        try:
            self.writer.write(response.encode("utf-8"))
            self.writer.drain()
        except Exception:
            pass

    def _close_connection(self):
        """Close the connection."""
        try:
            self.writer.close()
        except Exception:
            pass

    async def send_text(self, data):
        """Send a text frame."""
        if self.closed:
            return
        try:
            frame = self._encode_frame(OPCODE_TEXT, data.encode("utf-8"))
            self.writer.write(frame)
            await self.writer.drain()
        except Exception as e:
            print(f"WebSocket send error: {e}", file=sys.stderr)

    async def send_binary(self, data):
        """Send a binary frame."""
        if self.closed:
            return
        try:
            if isinstance(data, str):
                data = data.encode("utf-8")
            frame = self._encode_frame(OPCODE_BINARY, data)
            self.writer.write(frame)
            await self.writer.drain()
        except Exception as e:
            print(f"WebSocket send error: {e}", file=sys.stderr)

    def _encode_frame(self, opcode, payload):
        """Encode a WebSocket frame."""
        frame = bytearray()
        frame.append(0x80 | opcode)  # FIN + opcode

        length = len(payload)
        if length < 126:
            frame.append(length)
        elif length < 65536:
            frame.append(126)
            frame.extend(struct.pack(">H", length))
        else:
            frame.append(127)
            frame.extend(struct.pack(">Q", length))

        frame.extend(payload)
        return bytes(frame)

    async def _decode_frame(self):
        """Decode a WebSocket frame. Returns (opcode, payload)."""
        try:
            # Read first two bytes (use readexactly for guaranteed length)
            header = await self.reader.readexactly(2)

            fin = (header[0] >> 7) & 1
            opcode = header[0] & 0x0F
            masked = (header[1] >> 7) & 1
            length = header[1] & 0x7F

            # Extended payload length
            if length == 126:
                ext = await self.reader.readexactly(2)
                length = struct.unpack(">H", ext)[0]
            elif length == 127:
                ext = await self.reader.readexactly(8)
                length = struct.unpack(">Q", ext)[0]

            # Masking key
            if masked:
                mask_key = await self.reader.readexactly(4)

            # Payload
            payload = await self.reader.readexactly(length)

            # Unmask if needed
            if masked:
                payload = bytes(b ^ mask_key[i % 4] for i, b in enumerate(payload))

            return opcode, payload
        except Exception as e:
            print(f"WebSocket decode error: {e}", file=sys.stderr)
            return None, None

    async def handle_connection(self):
        """Handle the WebSocket connection loop."""
        try:
            while not self.closed:
                opcode, payload = await self._decode_frame()
                if opcode is None:
                    break

                if opcode == OPCODE_CLOSE:
                    await self._send_close()
                    break
                elif opcode == OPCODE_PING:
                    await self._send_pong(payload)
                elif opcode == OPCODE_PONG:
                    pass  # Ignore pong
                elif opcode in (OPCODE_TEXT, OPCODE_BINARY):
                    # Handle text messages from client (e.g., chat_request)
                    try:
                        msg = payload.decode("utf-8")
                        data = json.loads(msg)
                        if data.get("type") == "chat_request":
                            # Invoke Claude with the message
                            await self._handle_chat_request(
                                data.get("message", ""),
                                data.get("conversation_id"),
                            )
                    except (json.JSONDecodeError, UnicodeDecodeError):
                        pass

                # Check if we should stop waiting for messages
                if self.closed:
                    break

        except Exception as e:
            print(f"WebSocket connection error: {e}", file=sys.stderr)
        finally:
            self._close_connection()
            # Clean up the message queue on disconnect
            if self.user in _websocket_queues:
                del _websocket_queues[self.user]

    async def _send_close(self):
        """Send a close frame."""
        try:
            # Close code 1000 = normal closure
            frame = self._encode_frame(OPCODE_CLOSE, struct.pack(">H", 1000))
            self.writer.write(frame)
            await self.writer.drain()
        except Exception:
            pass

    async def _send_pong(self, payload):
        """Send a pong frame."""
        try:
            frame = self._encode_frame(OPCODE_PONG, payload)
            self.writer.write(frame)
            await self.writer.drain()
        except Exception:
            pass

    async def _handle_chat_request(self, message, message_conv_id=None):
        """Handle a chat_request WebSocket frame by invoking Claude."""
        if not message:
            return

        # Validate Claude binary exists
        if not os.path.exists(CLAUDE_BIN):
            await self.send_text(json.dumps({
                "type": "error",
                "message": "Claude CLI not found",
            }))
            return

        # Derive claude session_id from conv_id so each conversation has its own claude context
        conv_id = message_conv_id or self.conv_id or _generate_conversation_id()
        claude_session_id = f"{conv_id}-claude"
        if not claude_session_id:
            claude_session_id = uuid.uuid4().hex

        try:
            # Build claude command with session continuity (-r) for conversation memory
            claude_args = [
                CLAUDE_BIN, "-r", claude_session_id, "-p", message,
                "--output-format", "stream-json",
                "--permission-mode", "acceptEdits",
                "--model", CHAT_CLAUDE_MODEL,
            ]

            # Spawn claude --print with stream-json for streaming output
            # Set cwd to workspace directory if configured, allowing Claude to access project code
            cwd = WORKSPACE_DIR if WORKSPACE_DIR else None
            proc = subprocess.Popen(
                claude_args,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                cwd=cwd,
                bufsize=1,
            )

            # Stream output line by line
            for line in iter(proc.stdout.readline, ""):
                line = line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                    etype = event.get("type", "")

                    # Extract text content from content_block_delta events
                    if etype == "content_block_delta":
                        delta = event.get("delta", {})
                        if delta.get("type") == "text_delta":
                            text = delta.get("text", "")
                            if text:
                                # Send tokens to client
                                await self.send_text(text)

                    # Check for usage event to know when complete
                    if etype == "result":
                        pass  # Will send complete after loop

                except json.JSONDecodeError:
                    pass

            # Wait for process to complete
            proc.wait()

            if proc.returncode != 0:
                await self.send_text(json.dumps({
                    "type": "error",
                    "message": f"Claude CLI failed with exit code {proc.returncode}",
                }))
                return

            # Send complete signal
            await self.send_text(json.dumps({
                "type": "complete",
            }))

        except FileNotFoundError:
            await self.send_text(json.dumps({
                "type": "error",
                "message": "Claude CLI not found",
            }))
        except Exception as e:
            await self.send_text(json.dumps({
                "type": "error",
                "message": str(e),
            }))


# =============================================================================
# Conversation History Functions (#710)
# =============================================================================

def _generate_conversation_id():
    """Generate a new conversation ID (12-char hex string)."""
    return secrets.token_hex(6)


def _validate_conversation_id(conv_id):
    """Validate that conversation_id matches the required format."""
    return bool(CONVERSATION_ID_PATTERN.match(conv_id))


def _get_user_history_dir(user):
    """Get the history directory path for a user."""
    return os.path.join(CHAT_HISTORY_DIR, user)


def _get_conversation_path(user, conv_id):
    """Get the full path to a conversation file."""
    user_dir = _get_user_history_dir(user)
    return os.path.join(user_dir, f"{conv_id}.ndjson")


def _ensure_user_dir(user):
    """Ensure the user's history directory exists."""
    user_dir = _get_user_history_dir(user)
    os.makedirs(user_dir, exist_ok=True)
    return user_dir


def _write_message(user, conv_id, role, content):
    """Append a message to a conversation file in NDJSON format."""
    conv_path = _get_conversation_path(user, conv_id)
    _ensure_user_dir(user)

    record = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "user": user,
        "role": role,
        "content": content,
    }

    with open(conv_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


def _read_conversation(user, conv_id):
    """Read all messages from a conversation file."""
    conv_path = _get_conversation_path(user, conv_id)
    messages = []

    if not os.path.exists(conv_path):
        return None

    try:
        with open(conv_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        messages.append(json.loads(line))
                    except json.JSONDecodeError:
                        # Skip malformed lines
                        continue
    except IOError:
        return None

    return messages


def _list_user_conversations(user):
    """List all conversation files for a user with first message preview."""
    user_dir = _get_user_history_dir(user)
    conversations = []

    if not os.path.exists(user_dir):
        return conversations

    try:
        for filename in os.listdir(user_dir):
            if not filename.endswith(".ndjson"):
                continue

            conv_id = filename[:-7]  # Remove .ndjson extension
            if not _validate_conversation_id(conv_id):
                continue

            conv_path = os.path.join(user_dir, filename)
            messages = _read_conversation(user, conv_id)

            if messages:
                first_msg = messages[0]
                preview = first_msg.get("content", "")[:50]
                if len(first_msg.get("content", "")) > 50:
                    preview += "..."
                conversations.append({
                    "id": conv_id,
                    "created_at": first_msg.get("ts", ""),
                    "preview": preview,
                    "message_count": len(messages),
                })
            else:
                # Empty conversation file
                conversations.append({
                    "id": conv_id,
                    "created_at": "",
                    "preview": "(empty)",
                    "message_count": 0,
                })
    except OSError:
        pass

    # Sort by created_at descending
    conversations.sort(key=lambda x: x["created_at"] or "", reverse=True)
    return conversations


def _delete_conversation(user, conv_id):
    """Delete a conversation file."""
    conv_path = _get_conversation_path(user, conv_id)
    if os.path.exists(conv_path):
        os.remove(conv_path)
        return True
    return False


class ChatHandler(BaseHTTPRequestHandler):
    """HTTP request handler for disinto-chat with Forgejo OAuth."""

    def log_message(self, format, *args):
        """Log to stderr."""
        print(f"[{self.log_date_time_string()}] {format % args}", file=sys.stderr)

    def send_error_page(self, code, message=None):
        """Custom error response."""
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        if message:
            self.wfile.write(message.encode("utf-8"))

    def _require_session(self):
        """Check session; redirect to /chat/login if missing. Returns username or None."""
        user, _sid = _validate_session(self.headers.get("Cookie"))
        if user:
            return user
        self.send_response(302)
        self.send_header("Location", "/chat/login")
        self.end_headers()
        return None

    def _check_forwarded_user(self, session_user):
        """Defense-in-depth: verify X-Forwarded-User matches session user (#709).

        Returns True if the request may proceed, False if a 403 was sent.
        When X-Forwarded-User is absent (forward_auth removed from Caddy),
        the request is rejected - fail-closed by design.
        """
        forwarded = self.headers.get("X-Forwarded-User")
        if not forwarded:
            rid = self.headers.get("X-Request-Id", "-")
            print(
                f"WARN: missing X-Forwarded-User for session_user={session_user} "
                f"req_id={rid} - fail-closed (#709)",
                file=sys.stderr,
            )
            self.send_error_page(403, "Forbidden: missing forwarded-user header")
            return False
        if forwarded != session_user:
            rid = self.headers.get("X-Request-Id", "-")
            print(
                f"WARN: X-Forwarded-User mismatch: header={forwarded} "
                f"session={session_user} req_id={rid} (#709)",
                file=sys.stderr,
            )
            self.send_error_page(403, "Forbidden: user identity mismatch")
            return False
        return True

    def do_GET(self):
        """Handle GET requests."""
        parsed = urlparse(self.path)
        path = parsed.path

        # Health endpoint (no auth required) — used by Docker healthcheck
        if path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok\n")
            return

        # Verify endpoint for Caddy forward_auth (#709)
        if path == "/chat/auth/verify":
            self.handle_auth_verify()
            return

        # OAuth routes (no session required)
        if path == "/chat/login":
            self.handle_login()
            return

        if path == "/chat/oauth/callback":
            self.handle_oauth_callback(parsed.query)
            return

        # Conversation list endpoint: GET /chat/history
        if path == "/chat/history":
            user = self._require_session()
            if not user:
                return
            if not self._check_forwarded_user(user):
                return
            self.handle_conversation_list(user)
            return

        # Single conversation endpoint: GET /chat/history/<id>
        if path.startswith("/chat/history/"):
            user = self._require_session()
            if not user:
                return
            if not self._check_forwarded_user(user):
                return
            conv_id = path[len("/chat/history/"):]
            self.handle_conversation_get(user, conv_id)
            return

        # Serve index.html at root
        if path in ("/", "/chat", "/chat/"):
            user = self._require_session()
            if not user:
                return
            if not self._check_forwarded_user(user):
                return
            self.serve_index()
            return

        # Serve static files
        if path.startswith("/chat/static/") or path.startswith("/static/"):
            user = self._require_session()
            if not user:
                return
            if not self._check_forwarded_user(user):
                return
            self.serve_static(path)
            return

        # WebSocket upgrade endpoint
        if path == "/chat/ws" or path == "/ws" or path.startswith("/ws"):
            self.handle_websocket_upgrade()
            return

        # 404 for unknown paths
        self.send_error_page(404, "Not found")

    def do_POST(self):
        """Handle POST requests."""
        parsed = urlparse(self.path)
        path = parsed.path

        # New conversation endpoint (session required)
        if path == "/chat/new":
            user = self._require_session()
            if not user:
                return
            if not self._check_forwarded_user(user):
                return
            self.handle_new_conversation(user)
            return

        # Chat endpoint (session required)
        if path in ("/chat", "/chat/"):
            user = self._require_session()
            if not user:
                return
            if not self._check_forwarded_user(user):
                return
            self.handle_chat(user)
            return

        # 404 for unknown paths
        self.send_error_page(404, "Not found")

    def handle_auth_verify(self):
        """Caddy forward_auth callback - validate session and return X-Forwarded-User (#709).

        Caddy calls this endpoint for every /chat/* request.  If the session
        cookie is valid the endpoint returns 200 with the X-Forwarded-User
        header set to the session username.  Otherwise it returns 401 so Caddy
        knows the request is unauthenticated.

        Access control: when FORWARD_AUTH_SECRET is configured, the request must
        carry a matching X-Forward-Auth-Secret header (shared secret between
        Caddy and the chat backend).
        """
        # Shared-secret gate
        if FORWARD_AUTH_SECRET:
            provided = self.headers.get("X-Forward-Auth-Secret", "")
            if not secrets.compare_digest(provided, FORWARD_AUTH_SECRET):
                self.send_error_page(403, "Forbidden: invalid forward-auth secret")
                return

        user, _sid = _validate_session(self.headers.get("Cookie"))
        if not user:
            self.send_error_page(401, "Unauthorized: no valid session")
            return

        self.send_response(200)
        self.send_header("X-Forwarded-User", user)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        self.wfile.write(b"ok")

    def handle_login(self):
        """Redirect to Forgejo OAuth authorize endpoint."""
        _gc_sessions()

        if not CHAT_OAUTH_CLIENT_ID:
            self.send_error_page(500, "Chat OAuth not configured (CHAT_OAUTH_CLIENT_ID missing)")
            return

        state = secrets.token_urlsafe(32)
        _oauth_states[state] = time.time() + 600  # 10 min validity

        params = urlencode({
            "client_id": CHAT_OAUTH_CLIENT_ID,
            "redirect_uri": _build_callback_uri(),
            "response_type": "code",
            "state": state,
        })
        self.send_response(302)
        self.send_header("Location", f"{FORGE_URL}/login/oauth/authorize?{params}")
        self.end_headers()

    def handle_oauth_callback(self, query_string):
        """Exchange authorization code for token, validate user, set session."""
        params = parse_qs(query_string)
        code = params.get("code", [""])[0]
        state = params.get("state", [""])[0]

        # Validate state
        expected_expiry = _oauth_states.pop(state, None) if state else None
        if not expected_expiry or expected_expiry < time.time():
            self.send_error_page(400, "Invalid or expired OAuth state")
            return

        if not code:
            self.send_error_page(400, "Missing authorization code")
            return

        # Exchange code for access token
        token_resp = _exchange_code_for_token(code)
        if not token_resp or "access_token" not in token_resp:
            self.send_error_page(502, "Failed to obtain access token from Forgejo")
            return

        access_token = token_resp["access_token"]

        # Fetch user info
        user_info = _fetch_user(access_token)
        if not user_info or "login" not in user_info:
            self.send_error_page(502, "Failed to fetch user info from Forgejo")
            return

        username = user_info["login"]

        # Check allowlist
        if username not in ALLOWED_USERS:
            self.send_response(403)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(
                f"Not authorised: user '{username}' is not in the allowed users list.\n".encode()
            )
            return

        # Create session
        session_token = secrets.token_urlsafe(48)
        _sessions[session_token] = {
            "user": username,
            "expires": time.time() + SESSION_TTL,
        }

        cookie_flags = _session_cookie_flags()
        self.send_response(302)
        self.send_header("Set-Cookie", f"{SESSION_COOKIE}={session_token}; {cookie_flags}")
        self.send_header("Location", "/chat/")
        self.end_headers()

    def serve_index(self):
        """Serve the main index.html file."""
        index_path = os.path.join(UI_DIR, "index.html")
        if not os.path.exists(index_path):
            self.send_error_page(500, "UI not found")
            return

        try:
            with open(index_path, "r", encoding="utf-8") as f:
                content = f.read()
            self.send_response(200)
            self.send_header("Content-Type", MIME_TYPES[".html"])
            self.send_header("Content-Length", len(content.encode("utf-8")))
            self.end_headers()
            self.wfile.write(content.encode("utf-8"))
        except IOError as e:
            self.send_error_page(500, f"Error reading index.html: {e}")

    def serve_static(self, path):
        """Serve static files from the static directory."""
        # Strip /chat/static/ or /static/ prefix
        if path.startswith("/chat/static/"):
            relative_path = path[len("/chat/static/"):]
        else:
            relative_path = path[len("/static/"):]

        if ".." in relative_path or relative_path.startswith("/"):
            self.send_error_page(403, "Forbidden")
            return

        file_path = os.path.join(STATIC_DIR, relative_path)
        if not os.path.exists(file_path):
            self.send_error_page(404, "Not found")
            return

        # Determine MIME type
        _, ext = os.path.splitext(file_path)
        content_type = MIME_TYPES.get(ext.lower(), "application/octet-stream")

        try:
            with open(file_path, "rb") as f:
                content = f.read()
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", len(content))
            self.end_headers()
            self.wfile.write(content)
        except IOError as e:
            self.send_error_page(500, f"Error reading file: {e}")

 
    def handle_chat(self, user):
        """
        Handle chat requests by spawning `claude --print` with the user message.
        Streams tokens over WebSocket if connected.
        """

        # Read request body
        content_length = int(self.headers.get("Content-Length", 0))
        if content_length == 0:
            self.send_error_page(400, "No message provided")
            return

        body = self.rfile.read(content_length)
        try:
            # Parse form-encoded body
            body_str = body.decode("utf-8")
            params = parse_qs(body_str)
            message = params.get("message", [""])[0]
            conv_id = params.get("conversation_id", [None])[0]
        except (UnicodeDecodeError, KeyError):
            self.send_error_page(400, "Invalid message format")
            return

        if not message:
            self.send_error_page(400, "Empty message")
            return

        # Get user from session
        user, _ = _validate_session(self.headers.get("Cookie"))
        if not user:
            self.send_error_page(401, "Unauthorized")
            return

        # Validate Claude binary exists
        if not os.path.exists(CLAUDE_BIN):
            self.send_error_page(500, "Claude CLI not found")
            return

        # Generate new conversation ID if not provided
        if not conv_id or not _validate_conversation_id(conv_id):
            conv_id = _generate_conversation_id()

        # Derive claude session_id from conv_id so each conversation has its own claude context
        claude_session_id = f"{conv_id}-claude"
        if not claude_session_id:
            claude_session_id = uuid.uuid4().hex

        try:
            # Save user message to history
            _write_message(user, conv_id, "user", message)

            # Build claude command with session continuity (-r) for conversation memory
            claude_args = [
                CLAUDE_BIN, "-r", claude_session_id, "-p", message,
                "--output-format", "stream-json",
                "--permission-mode", "acceptEdits",
                "--model", CHAT_CLAUDE_MODEL,
            ]

            # Spawn claude --print with stream-json for token tracking (#711)
            # Set cwd to workspace directory if configured, allowing Claude to access project code
            cwd = WORKSPACE_DIR if WORKSPACE_DIR else None
            proc = subprocess.Popen(
                claude_args,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                cwd=cwd,
                bufsize=1,  # Line buffered
            )

            # Stream output line by line
            response_parts = []
            total_tokens = 0
            for line in iter(proc.stdout.readline, ""):
                line = line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                    etype = event.get("type", "")

                    # Extract text content from content_block_delta events
                    if etype == "content_block_delta":
                        delta = event.get("delta", {})
                        if delta.get("type") == "text_delta":
                            text = delta.get("text", "")
                            if text:
                                response_parts.append(text)
                                # Stream to WebSocket if connected
                                if user in _websocket_queues:
                                    try:
                                        _websocket_queues[user].put_nowait(text)
                                    except Exception:
                                        pass  # Client disconnected

                    # Parse usage from result event
                    if etype == "result":
                        usage = event.get("usage", {})
                        total_tokens = usage.get("input_tokens", 0) + usage.get("output_tokens", 0)
                    elif "usage" in event:
                        usage = event["usage"]
                        if isinstance(usage, dict):
                            total_tokens = usage.get("input_tokens", 0) + usage.get("output_tokens", 0)

                except json.JSONDecodeError:
                    pass

            # Wait for process to complete
            error_output = proc.stderr.read()
            if error_output:
                print(f"Claude stderr: {error_output}", file=sys.stderr)

            proc.wait()

            if proc.returncode != 0:
                self.send_error_page(500, f"Claude CLI failed with exit code {proc.returncode}")
                return

            # Combine response parts
            response = "".join(response_parts)

            # Fall back to raw output if stream-json parsing yielded no text
            if not response:
                response = proc.stdout.getvalue() if hasattr(proc.stdout, 'getvalue') else ""

            # Save assistant response to history
            _write_message(user, conv_id, "assistant", response)

            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.end_headers()
            self.wfile.write(json.dumps({
                "response": response,
                "conversation_id": conv_id,
            }, ensure_ascii=False).encode("utf-8"))

        except FileNotFoundError:
            self.send_error_page(500, "Claude CLI not found")
        except Exception as e:
            self.send_error_page(500, f"Error: {e}")

    # =======================================================================
    # Conversation History Handlers
    # =======================================================================

    def handle_conversation_list(self, user):
        """List all conversations for the logged-in user."""
        conversations = _list_user_conversations(user)

        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.end_headers()
        self.wfile.write(json.dumps(conversations, ensure_ascii=False).encode("utf-8"))

    def handle_conversation_get(self, user, conv_id):
        """Get a specific conversation for the logged-in user."""
        # Validate conversation_id format
        if not _validate_conversation_id(conv_id):
            self.send_error_page(400, "Invalid conversation ID")
            return

        messages = _read_conversation(user, conv_id)

        if messages is None:
            self.send_error_page(404, "Conversation not found")
            return

        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.end_headers()
        self.wfile.write(json.dumps(messages, ensure_ascii=False).encode("utf-8"))

    def handle_conversation_delete(self, user, conv_id):
        """Delete a specific conversation for the logged-in user."""
        # Validate conversation_id format
        if not _validate_conversation_id(conv_id):
            self.send_error_page(400, "Invalid conversation ID")
            return

        if _delete_conversation(user, conv_id):
            self.send_response(204)  # No Content
            self.end_headers()
        else:
            self.send_error_page(404, "Conversation not found")

    def handle_new_conversation(self, user):
        """Create a new conversation and return its ID."""
        conv_id = _generate_conversation_id()
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.end_headers()
        self.wfile.write(json.dumps({"conversation_id": conv_id}, ensure_ascii=False).encode("utf-8"))

    @staticmethod
    def push_to_websocket(user, message):
        """Push a message to a WebSocket connection for a user.

        This is called from the chat handler to stream tokens to connected clients.
        The message is added to the user's WebSocket message queue.
        """
        # Get the message queue from the WebSocket handler's queue
        # We store the queue in a global dict keyed by user
        if user in _websocket_queues:
            _websocket_queues[user].put_nowait(message)

    def handle_websocket_upgrade(self):
        """Handle WebSocket upgrade request for chat streaming."""
        # Check session cookie
        user, _ = _validate_session(self.headers.get("Cookie"))
        if not user:
            self.send_error_page(401, "Unauthorized: no valid session")
            return

        # Create message queue for this user
        _websocket_queues[user] = asyncio.Queue()

        # Get WebSocket upgrade headers from the HTTP request
        sec_websocket_key = self.headers.get("Sec-WebSocket-Key", "")
        sec_websocket_protocol = self.headers.get("Sec-WebSocket-Protocol", "")

        # Validate Sec-WebSocket-Key
        if not sec_websocket_key:
            self.send_error_page(400, "Bad Request", "Missing Sec-WebSocket-Key")
            return

        # Get the socket from the connection
        sock = self.connection
        sock.setblocking(False)

        # Create async server to handle the connection
        async def handle_ws():
            try:
                # Wrap the socket in asyncio streams using open_connection
                reader, writer = await asyncio.open_connection(sock=sock)

                # Create WebSocket handler (pass conv_id for claude session scoping)
                ws_handler = _WebSocketHandler(reader, writer, user, _websocket_queues[user])

                # Accept the connection (pass headers from HTTP request)
                if not await ws_handler.accept_connection(sec_websocket_key, sec_websocket_protocol):
                    return

                # Start a task to read from the queue and send to client
                async def send_stream():
                    while not ws_handler.closed:
                        try:
                            data = await asyncio.wait_for(ws_handler.message_queue.get(), timeout=1.0)
                            await ws_handler.send_text(data)
                        except asyncio.TimeoutError:
                            # Send ping to keep connection alive
                            try:
                                frame = ws_handler._encode_frame(OPCODE_PING, b"")
                                writer.write(frame)
                                await writer.drain()
                            except Exception:
                                break
                        except Exception as e:
                            print(f"Send stream error: {e}", file=sys.stderr)
                            break

                # Start sending task
                send_task = asyncio.create_task(send_stream())

                # Handle incoming WebSocket frames
                await ws_handler.handle_connection()

                # Cancel send task
                send_task.cancel()
                try:
                    await send_task
                except asyncio.CancelledError:
                    pass

            except Exception as e:
                print(f"WebSocket handler error: {e}", file=sys.stderr)
            finally:
                try:
                    writer.close()
                    await writer.wait_closed()
                except Exception:
                    pass

        # Run the async handler in a thread
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        try:
            loop.run_until_complete(handle_ws())
        except Exception as e:
            print(f"WebSocket error: {e}", file=sys.stderr)
        finally:
            loop.close()
            sock.close()

    def do_DELETE(self):
        """Handle DELETE requests."""
        parsed = urlparse(self.path)
        path = parsed.path

        # Delete conversation endpoint
        if path.startswith("/chat/history/"):
            user = self._require_session()
            if not user:
                return
            if not self._check_forwarded_user(user):
                return
            conv_id = path[len("/chat/history/"):]
            self.handle_conversation_delete(user, conv_id)
            return

        # 404 for unknown paths
        self.send_error_page(404, "Not found")


def main():
    """Start the HTTP server."""
    server_address = (HOST, PORT)
    httpd = HTTPServer(server_address, ChatHandler)
    print(f"Starting disinto-chat server on {HOST}:{PORT}", file=sys.stderr)
    print(f"UI available at http://localhost:{PORT}/chat/", file=sys.stderr)
    if CHAT_OAUTH_CLIENT_ID:
        print(f"OAuth enabled (client_id={CHAT_OAUTH_CLIENT_ID[:8]}...)", file=sys.stderr)
        print(f"Allowed users: {', '.join(sorted(ALLOWED_USERS))}", file=sys.stderr)
    else:
        print("WARNING: CHAT_OAUTH_CLIENT_ID not set - OAuth disabled", file=sys.stderr)
    if FORWARD_AUTH_SECRET:
        print("forward_auth secret configured (#709)", file=sys.stderr)
    else:
        print("WARNING: FORWARD_AUTH_SECRET not set - verify endpoint unrestricted", file=sys.stderr)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
