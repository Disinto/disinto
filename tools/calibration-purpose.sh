#!/usr/bin/env bash
# =============================================================================
# tools/calibration-purpose.sh — purpose column on the calibration table (#1652)
#
# Grades are given per sprint with tools/grade.sh, from −1 to 1, and the
# calibration report never read them. This is a separate tool (not a change
# to the jq program inside calibration.sh, #1617): it reads the finished
# table on stdin and writes it to stdout with a `purpose` column appended
# via table_append_column (lib/table-column.sh, #1650).
#
# Graded pack: flat `loop = <grace hours>` TOML at
#   ${CALIBRATION_GRADED_FILE:-${OPS_REPO_ROOT:-/home/agent/repos/_factory/disinto-ops}/packs/graded.toml}
# read with python3 tomllib. Missing file: no values (every row prints `-`).
# Unparsable, or a value that is not a positive integer: exit 1.
#
# Clock: $CALIBRATION_NOW (ISO-8601 UTC), default now. Unparseable: exit 1.
#
# Per `<loop>/<class>` of a graded loop, eligible proposals are those of that
# loop and class whose last outcome's `t` (tape order) is at least the grace
# hours before the clock. A proposal with no outcome is not eligible — there
# is no outcome to have aged past the grace period. An earlier outcome's `t`
# is not a fallback. A loop not in the pack is not graded: dev issues must
# not show a fake 0.
#
# Per eligible proposal the reading is the `value` of its last grade record
# in tape order, or 0 when it has none or the value is null. The record
# itself is not rewritten. The cell is `M (g/e)`: M is the mean of those
# readings with two decimals, g is how many of the eligible proposals had a
# numeric grade, e is the eligible count. No eligible proposal: the key is
# left out, so the row prints `-`.
#
# Tape only. A malformed tape line (a torn final line) is skipped and never
# fails the report.
#
# Usage:
#   tools/calibration.sh | tools/calibration-signatures.sh | tools/calibration-purpose.sh
#
# Environment:
#   CALIBRATION_GRADED_FILE  graded pack (default under OPS_REPO_ROOT, above)
#   CALIBRATION_NOW          clock, ISO-8601 UTC (default now)
#   TAPE_DIR                 tape directory (default /srv/disinto/tape)
#
# Exit codes:
#   0  table printed, with the column appended
#   1  jq or python3 missing, the graded pack is unparsable or a value is
#      not a positive integer, the clock is unparseable, or the tape could
#      not be read. Nothing is written (stdin is still consumed, so a
#      pipeline writer is not SIGPIPE'd).
#
# Hermetic aside from the tape dir and the graded pack it is pointed at. No
# network, no agent, no secrets (AD-006). Does not source lib/env.sh.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../lib/table-column.sh
source "$REPO_ROOT/lib/table-column.sh"

# Resolved before stdin is drained so a later refusal still has the pack
# path, and so the five-line bootstrap does not match calibration-signatures.
GRADED_FILE="${CALIBRATION_GRADED_FILE:-${OPS_REPO_ROOT:-/home/agent/repos/_factory/disinto-ops}/packs/graded.toml}"

# Consume stdin before any refusal. A missing jq, or a pack that fails to
# parse, must not leave the pipeline writer with SIGPIPE.
table="$(cat || true)"

if ! command -v jq >/dev/null 2>&1; then
  echo "calibration-purpose: required tool missing: jq" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "calibration-purpose: required tool missing: python3" >&2
  exit 1
fi

TAPE_DIR="${TAPE_DIR:-/srv/disinto/tape}"
TAPE_FILE="${TAPE_DIR}/tape.jsonl"
NOW="${CALIBRATION_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

# A missing pack names no graded loop. The column is still appended; every
# key is absent, so each row prints `-`. An existing file that will not
# parse is a hard failure — dashes would look like "not graded".
if [ ! -e "$GRADED_FILE" ]; then
  values="{}"
else
  values="$(
    NOW="$NOW" GRADED_FILE="$GRADED_FILE" TAPE_FILE="$TAPE_FILE" python3 - <<'PY'
import json
import os
import sys
from datetime import datetime, timedelta, timezone

try:
    import tomllib
except ModuleNotFoundError:
    sys.stderr.write("calibration-purpose: python3 tomllib is unavailable\n")
    raise SystemExit(1)


def fail(msg):
    sys.stderr.write("calibration-purpose: " + msg + "\n")
    raise SystemExit(1)


def parse_t(raw):
    """ISO-8601, Z or offset, to an aware UTC datetime. None if not a stamp."""
    if not isinstance(raw, str):
        return None
    text = raw.strip()
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed


def numeric(value):
    # bool is an int subclass; a JSON true is not a grade.
    return isinstance(value, (int, float)) and not isinstance(value, bool)


graded_path = os.environ["GRADED_FILE"]
try:
    with open(graded_path, "rb") as handle:
        pack = tomllib.load(handle)
except Exception:
    fail("failed to parse graded pack " + graded_path)
if not isinstance(pack, dict):
    fail("graded pack is not a table: " + graded_path)
grace = {}
for loop, hours in pack.items():
    # type() is not isinstance: a bool would pass isinstance(..., int).
    if type(hours) is not int or hours <= 0:
        fail("graded pack value for " + str(loop) + " is not a positive integer")
    grace[loop] = hours

now = parse_t(os.environ["NOW"])
if now is None:
    fail("unparseable clock: " + os.environ["NOW"])

# Last proposal record per id (tape order). Outcomes and grades stay lists
# so the last record in the file wins; an earlier one is not a fallback.
proposals = {}
order = []
outcomes = {}
grades = {}
tape_path = os.environ["TAPE_FILE"]
if os.path.isfile(tape_path) and os.path.getsize(tape_path) > 0:
    try:
        handle = open(tape_path, encoding="utf-8")
    except OSError as exc:
        fail("failed to read tape " + tape_path + ": " + str(exc))
    with handle:
        for line in handle:
            text = line.strip()
            if not text:
                continue
            try:
                rec = json.loads(text)
            except ValueError:
                continue
            if not isinstance(rec, dict):
                continue
            kind = rec.get("type")
            if kind == "proposal":
                pid = rec.get("id")
                loop = rec.get("loop")
                cls = rec.get("class")
                if not (isinstance(pid, str) and isinstance(loop, str) and isinstance(cls, str)):
                    continue
                if pid not in proposals:
                    order.append(pid)
                proposals[pid] = (loop, cls)
            elif kind == "outcome":
                pid = rec.get("proposal_id")
                if isinstance(pid, str):
                    outcomes.setdefault(pid, []).append(rec)
            elif kind == "grade":
                pid = rec.get("proposal_id")
                if isinstance(pid, str):
                    grades.setdefault(pid, []).append(rec.get("value"))

# key -> list of numeric grades, None where the reading is the synthetic 0
# (no grade record, or a null / non-numeric value). The 0 still enters the
# mean; only a real number increments g.
groups = {}
for pid in order:
    loop, cls = proposals[pid]
    if loop not in grace:
        continue
    outs = outcomes.get(pid)
    if not outs:
        continue
    stamped = parse_t(outs[-1].get("t"))
    if stamped is None:
        continue
    if now - stamped < timedelta(hours=grace[loop]):
        continue
    recorded = grades.get(pid)
    value = recorded[-1] if recorded else None
    groups.setdefault(loop + "/" + cls, []).append(value if numeric(value) else None)

cells = {}
for key, readings in groups.items():
    eligible = len(readings)
    if eligible == 0:
        continue
    graded = sum(1 for item in readings if item is not None)
    total = sum(item for item in readings if item is not None)
    cells[key] = f"{(total / eligible):.2f} ({graded}/{eligible})"

sys.stdout.write(json.dumps(cells))
PY
  )" || exit 1
fi

printf '%s' "$table" | table_append_column "purpose" "$values"
