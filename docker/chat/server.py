#!/usr/bin/env python3
"""
disinto-chat server — minimal HTTP backend for Claude chat UI.

Routes:
    GET /          → serves index.html
    GET /static/*  → serves static assets (htmx.min.js, etc.)
    POST /chat     → spawns `claude --print` with user message, returns response
    GET /ws        → reserved for future streaming upgrade (returns 501)

The claude binary is expected to be mounted from the host at /usr/local/bin/claude.
"""

import os
import subprocess
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

# Configuration
HOST = os.environ.get("CHAT_HOST", "0.0.0.0")
PORT = int(os.environ.get("CHAT_PORT", 8080))
UI_DIR = "/var/chat/ui"
STATIC_DIR = os.path.join(UI_DIR, "static")
CLAUDE_BIN = "/usr/local/bin/claude"

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


class ChatHandler(BaseHTTPRequestHandler):
    """HTTP request handler for disinto-chat."""

    def log_message(self, format, *args):
        """Log to stdout instead of stderr."""
        print(f"[{self.log_date_time_string()}] {format % args}", file=sys.stderr)

    def send_error(self, code, message=None):
        """Custom error response."""
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        if message:
            self.wfile.write(message.encode("utf-8"))

    def do_GET(self):
        """Handle GET requests."""
        parsed = urlparse(self.path)
        path = parsed.path

        # Serve index.html at root
        if path == "/" or path == "/chat":
            self.serve_index()
            return

        # Serve static files
        if path.startswith("/static/"):
            self.serve_static(path)
            return

        # Reserved WebSocket endpoint (future use)
        if path == "/ws" or path.startswith("/ws"):
            self.send_error(501, "WebSocket upgrade not yet implemented")
            return

        # 404 for unknown paths
        self.send_error(404, "Not found")

    def do_POST(self):
        """Handle POST requests."""
        parsed = urlparse(self.path)
        path = parsed.path

        # Chat endpoint
        if path == "/chat" or path == "/chat/":
            self.handle_chat()
            return

        # 404 for unknown paths
        self.send_error(404, "Not found")

    def serve_index(self):
        """Serve the main index.html file."""
        index_path = os.path.join(UI_DIR, "index.html")
        if not os.path.exists(index_path):
            self.send_error(500, "UI not found")
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
            self.send_error(500, f"Error reading index.html: {e}")

    def serve_static(self, path):
        """Serve static files from the static directory."""
        # Sanitize path to prevent directory traversal
        relative_path = path[len("/static/"):]
        if ".." in relative_path or relative_path.startswith("/"):
            self.send_error(403, "Forbidden")
            return

        file_path = os.path.join(STATIC_DIR, relative_path)
        if not os.path.exists(file_path):
            self.send_error(404, "Not found")
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
            self.send_error(500, f"Error reading file: {e}")

    def handle_chat(self):
        """
        Handle chat requests by spawning `claude --print` with the user message.
        Returns the response as plain text.
        """
        # Read request body
        content_length = int(self.headers.get("Content-Length", 0))
        if content_length == 0:
            self.send_error(400, "No message provided")
            return

        body = self.rfile.read(content_length)
        try:
            # Parse form-encoded body
            body_str = body.decode("utf-8")
            params = parse_qs(body_str)
            message = params.get("message", [""])[0]
        except (UnicodeDecodeError, KeyError):
            self.send_error(400, "Invalid message format")
            return

        if not message:
            self.send_error(400, "Empty message")
            return

        # Validate Claude binary exists
        if not os.path.exists(CLAUDE_BIN):
            self.send_error(500, "Claude CLI not found")
            return

        try:
            # Spawn claude --print with streaming output
            # Using stream-json format for structured parsing capability
            proc = subprocess.Popen(
                [CLAUDE_BIN, "--print", message, "--output-format", "stream-json"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=False,
                bufsize=0,  # Unbuffered for streaming
            )

            # Read and stream response
            response_parts = []
            error_parts = []

            # Read stdout in chunks
            while True:
                chunk = proc.stdout.read(4096)
                if not chunk:
                    break
                try:
                    response_parts.append(chunk.decode("utf-8"))
                except UnicodeDecodeError:
                    response_parts.append(chunk.decode("utf-8", errors="replace"))

            # Read stderr (should be minimal, mostly for debugging)
            if proc.stderr:
                error_output = proc.stderr.read()
                if error_output:
                    error_parts.append(error_output.decode("utf-8", errors="replace"))

            # Wait for process to complete
            proc.wait()

            # Check for errors
            if proc.returncode != 0:
                self.send_error(500, f"Claude CLI failed with exit code {proc.returncode}")
                return

            # Combine response parts
            response = "".join(response_parts)

            # If using stream-json, we could parse and reformat here.
            # For now, return as-is (HTMX will display it in the UI).
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", len(response.encode("utf-8")))
            self.end_headers()
            self.wfile.write(response.encode("utf-8"))

        except FileNotFoundError:
            self.send_error(500, "Claude CLI not found")
        except Exception as e:
            self.send_error(500, f"Error: {e}")


def main():
    """Start the HTTP server."""
    server_address = (HOST, PORT)
    httpd = HTTPServer(server_address, ChatHandler)
    print(f"Starting disinto-chat server on {HOST}:{PORT}", file=sys.stderr)
    print(f"UI available at http://localhost:{PORT}/", file=sys.stderr)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
