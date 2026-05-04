#!/usr/bin/env python3
"""
engagement-server.py — Minimal HTTP server for client-side engagement beacons.

Accepts POST requests at /api/engagement, appends the JSON body to a log file,
and returns 204 No Content. Used by the client-side engagement.js tracker.

Environment variables:
  ENGAGEMENT_LOG   — log file path (default: /var/log/caddy/engagement.log)
  ENGAGEMENT_PORT  — listen port (default: 8095)
"""
import http.server
import json
import os
import sys
from datetime import datetime, timezone

LOG_FILE = os.environ.get("ENGAGEMENT_LOG", "/var/log/caddy/engagement.log")
PORT = int(os.environ.get("ENGAGEMENT_PORT", "8095"))


class EngagementHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)

        # Ensure log directory exists
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)

        # Append beacon to log file
        with open(LOG_FILE, "a") as f:
            f.write(body.decode("utf-8", errors="replace") + "\n")

        self.send_response(204)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true}')

    def do_GET(self):
        # Return latest engagement data for snapshot queries
        if self.path == "/api/engagement":
            self._serve_snapshot()
            return
        self.send_response(405)
        self.end_headers()

    def _serve_snapshot(self):
        """Serve aggregated engagement snapshot (GET /api/engagement)."""
        try:
            with open(LOG_FILE, "r") as f:
                lines = f.readlines()
        except FileNotFoundError:
            lines = []

        events = []
        for line in lines:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                continue

        if not events:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"events":[],"total":0}')
            return

        # Aggregate: count by event type, top paths, top referrers
        event_counts = {}
        path_counts = {}
        referrer_counts = {}
        total_dwell = 0
        dwell_count = 0
        max_scroll = 0

        for ev in events:
            evt = ev.get("event", "unknown")
            event_counts[evt] = event_counts.get(evt, 0) + 1

            path = ev.get("path", "/")
            path_counts[path] = path_counts.get(path, 0) + 1

            ref = ev.get("referrer", "direct")
            referrer_counts[ref] = referrer_counts.get(ref, 0) + 1

            if "dwell_seconds" in ev:
                total_dwell += ev["dwell_seconds"]
                dwell_count += 1

            if "scroll_pct" in ev:
                max_scroll = max(max_scroll, ev["scroll_pct"])

        top_paths = sorted(path_counts.items(), key=lambda x: -x[1])[:10]
        top_referrers = sorted(referrer_counts.items(), key=lambda x: -x[1])[:10]

        snapshot = {
            "total_events": len(events),
            "event_counts": event_counts,
            "top_paths": [{"path": p, "count": c} for p, c in top_paths],
            "top_referrers": [{"source": r, "count": c} for r, c in top_referrers],
            "avg_dwell_seconds": (
                round(total_dwell / dwell_count, 1) if dwell_count > 0 else 0
            ),
            "max_scroll_pct": max_scroll,
            "last_updated": datetime.now(timezone.utc).isoformat(),
        }

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(json.dumps(snapshot).encode())

    def log_message(self, format, *args):
        # Suppress default stderr logging
        pass


def main():
    server = http.server.HTTPServer(("127.0.0.1", PORT), EngagementHandler)
    print(
        f"engagement-server: listening on 127.0.0.1:{PORT}",
        file=sys.stderr,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
