#!/usr/bin/env python3
"""
ci-log-reader.py — Read CI logs from Woodpecker SQLite database.

Usage:
    ci-log-reader.py <pipeline_number> [--step <step_name>]

Reads log entries from the Woodpecker SQLite database and outputs them to stdout.
If --step is specified, filters to that step only. Otherwise returns logs from
all failed steps, truncated to the last 200 lines to avoid context bloat.

Environment:
    WOODPECKER_DATA_DIR - Path to Woodpecker data directory (default: /woodpecker-data)

The SQLite database is located at: $WOODPECKER_DATA_DIR/woodpecker.sqlite
"""

import argparse
import sqlite3
import sys
import os

DEFAULT_DB_PATH = "/woodpecker-data/woodpecker.sqlite"
DEFAULT_WOODPECKER_DATA_DIR = "/woodpecker-data"
MAX_OUTPUT_LINES = 200


def get_db_path():
    """Determine the path to the Woodpecker SQLite database."""
    env_dir = os.environ.get("WOODPECKER_DATA_DIR", DEFAULT_WOODPECKER_DATA_DIR)
    return os.path.join(env_dir, "woodpecker.sqlite")


def query_logs(pipeline_number: int, step_name: str | None = None) -> list[str]:
    """
    Query log entries from the Woodpecker database.

    Args:
        pipeline_number: The pipeline number to query
        step_name: Optional step name to filter by

    Returns:
        List of log data strings
    """
    db_path = get_db_path()

    if not os.path.exists(db_path):
        print(f"ERROR: Woodpecker database not found at {db_path}", file=sys.stderr)
        print(f"Set WOODPECKER_DATA_DIR or mount volume to {DEFAULT_WOODPECKER_DATA_DIR}", file=sys.stderr)
        sys.exit(1)

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()

    if step_name:
        # Query logs for a specific step
        query = """
            SELECT le.data
            FROM log_entries le
            JOIN steps s ON le.step_id = s.id
            JOIN pipelines p ON s.pipeline_id = p.id
            WHERE p.number = ? AND s.name = ?
            ORDER BY le.id
        """
        cursor.execute(query, (pipeline_number, step_name))
    else:
        # Query logs for all failed steps in the pipeline
        query = """
            SELECT le.data
            FROM log_entries le
            JOIN steps s ON le.step_id = s.id
            JOIN pipelines p ON s.pipeline_id = p.id
            WHERE p.number = ? AND s.state IN ('failure', 'error', 'killed')
            ORDER BY le.id
        """
        cursor.execute(query, (pipeline_number,))

    logs = [row["data"] for row in cursor.fetchall()]
    conn.close()
    return logs


def main():
    parser = argparse.ArgumentParser(
        description="Read CI logs from Woodpecker SQLite database"
    )
    parser.add_argument(
        "pipeline_number",
        type=int,
        help="Pipeline number to query"
    )
    parser.add_argument(
        "--step", "-s",
        dest="step_name",
        default=None,
        help="Filter to a specific step name"
    )

    args = parser.parse_args()

    logs = query_logs(args.pipeline_number, args.step_name)

    if not logs:
        if args.step_name:
            print(f"No logs found for pipeline #{args.pipeline_number}, step '{args.step_name}'", file=sys.stderr)
        else:
            print(f"No failed steps found in pipeline #{args.pipeline_number}", file=sys.stderr)
        sys.exit(0)

    # Join all log data and output
    full_output = "\n".join(logs)

    # Truncate to last N lines to avoid context bloat
    lines = full_output.split("\n")
    if len(lines) > MAX_OUTPUT_LINES:
        # Keep last N lines
        truncated = lines[-MAX_OUTPUT_LINES:]
        print("\n".join(truncated))
    else:
        print(full_output)


if __name__ == "__main__":
    main()
