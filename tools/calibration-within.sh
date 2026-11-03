#!/usr/bin/env bash
# =============================================================================
# tools/calibration-within.sh — the `within` column: time to result (#2064)
#
# `merged` saturates: a row can read 100% while most of its samples took days
# to merge. mean duration_s shows this only as a skewed mean and leaves stuck
# samples out. This is a separate tool (not a change to the jq program inside
# calibration.sh, #1617): it reads the finished table on stdin and writes it
# to stdout with a `within` column appended via table_append_column
# (lib/table-column.sh, #1650/#2060).
#
# Horizon pack: flat `loop = <hours>` TOML at
#   ${CALIBRATION_WITHIN_FILE:-${OPS_REPO_ROOT:-/home/agent/repos/_factory/disinto-ops}/packs/within.toml}
# read with python3 tomllib, like the stuck pack of tools/tape-stuck.sh
# (#1648). Missing file: no values, so every row prints `-` and the tool
# exits 0. Unparsable, or a value that is not a positive integer: exit 1.
#
# Loops pack:
#   ${CALIBRATION_LOOPS_FILE:-${OPS_REPO_ROOT:-/home/agent/repos/_factory/disinto-ops}/packs/loops.toml}
# read the way tools/tape-stuck.sh reads it: a string value is a one-element
# array of competence bits. Missing or unparsable: exit 1.
#
# Model map: ${TAPE_MODEL_TOOL:-<this dir>/tape-model.sh} (#2059), run with no
# arguments; a non-zero exit or a non-JSON-object output is exit 1.
#
# Per table row whose loop the horizon pack names, and whose fourth cell is a
# positive integer n (the row's own count, so stuck samples sit in the
# denominator exactly as calibration.sh counted them): the cell is
# `round(100 × numerator / n)%`. The numerator counts proposals on
# ${TAPE_DIR:-/srv/disinto/tape}/tape.jsonl of that loop and class whose
# model — the map at the proposal's `id`, `-` when it names none — equals the
# row's model, whose last outcome in tape order carries one of the loop's
# competence bits as true/1, and whose numbers.duration_s is a number at most
# the loop's hours × 3600. A row whose loop the pack does not name, or whose
# fourth cell is not a positive integer, gets no key and prints `-`.
#
# Tape only. A malformed tape line (a torn final line from a crashed writer)
# is skipped and never fails the report.
#
# Usage:
#   tools/calibration.sh | tools/calibration-signatures.sh \
#     | tools/calibration-purpose.sh | tools/calibration-within.sh
#
# Environment:
#   CALIBRATION_WITHIN_FILE  horizon pack (default under OPS_REPO_ROOT, above)
#   CALIBRATION_LOOPS_FILE   loop -> competence-bit pack (default above)
#   TAPE_MODEL_TOOL          model-per-proposal reader (#2059); run with no
#                            arguments; a non-zero exit or non-object output
#                            fails this tool
#   TAPE_DIR                 tape directory (default /srv/disinto/tape)
#
# Exit codes:
#   0  table printed, with the column appended
#   1  jq or python3 missing, the loops pack is missing or unparsable, the
#      model tool failed or did not print a JSON object, or the horizon pack
#      is unparsable or carries a value that is not a positive integer.
#      Nothing is written (stdin is still consumed, so a pipeline writer is
#      not SIGPIPE'd).
#
# Hermetic aside from the tape dir and the packs it is pointed at. No
# network, no agent, no secrets (AD-006). Does not source lib/env.sh.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../lib/table-column.sh
source "$REPO_ROOT/lib/table-column.sh"

# Resolved before stdin is drained so a later refusal still names the pack
# path; written out here in its own lines instead of copied from
# calibration-purpose.sh, so the five-line windows stay distinct.
WITHIN_FILE="${CALIBRATION_WITHIN_FILE:-${OPS_REPO_ROOT:-/home/agent/repos/_factory/disinto-ops}/packs/within.toml}"
LOOPS_FILE="${CALIBRATION_LOOPS_FILE:-${OPS_REPO_ROOT:-/home/agent/repos/_factory/disinto-ops}/packs/loops.toml}"
MODEL_TOOL="${TAPE_MODEL_TOOL:-$SCRIPT_DIR/tape-model.sh}"

# Consume stdin before any refusal. A missing jq, or a pack that will not
# parse, must not leave the pipeline writer with SIGPIPE.
table="$(cat || true)"

if ! command -v jq >/dev/null 2>&1; then
  echo "calibration-within: required tool missing: jq" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "calibration-within: required tool missing: python3" >&2
  exit 1
fi

# Which bits each loop carries decides every numerator; there is no fallback
# map, so a missing or broken loops pack is a hard failure, not a column of
# dashes (a dash would read as "no loop has a horizon").
if [ ! -f "$LOOPS_FILE" ]; then
  echo "calibration-within: loops pack file missing: $LOOPS_FILE" >&2
  exit 1
fi

map_rc=0
map_json="$("$MODEL_TOOL")" || map_rc=$?
if [ "$map_rc" -gt 0 ]; then
  echo "calibration-within: model tool failed (rc=$map_rc): $MODEL_TOOL" >&2
  exit 1
fi
if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$map_json"; then
  echo "calibration-within: model tool printed a non-object" >&2
  exit 1
fi

TAPE_DIR="${TAPE_DIR:-/srv/disinto/tape}"
TAPE_FILE="${TAPE_DIR}/tape.jsonl"

# A missing horizon pack names no loop: the column is still appended and every
# row prints `-`. An existing pack that will not parse, or with a value that
# is not a positive integer, is a hard failure.
if [ ! -e "$WITHIN_FILE" ]; then
  values="{}"
else
  values="$(
    WITHIN_FILE="$WITHIN_FILE" LOOPS_FILE="$LOOPS_FILE" TAPE_FILE="$TAPE_FILE" \
    TABLE="$table" MODELS_JSON="$map_json" python3 - <<'PY'
import json
import os
import re
import sys

try:
    import tomllib
except ModuleNotFoundError:
    sys.stderr.write("calibration-within: python3 tomllib is unavailable\n")
    raise SystemExit(1)


def bail(msg):
    sys.stderr.write("calibration-within: " + msg + "\n")
    raise SystemExit(1)


def read_pack(path, label):
    try:
        with open(path, "rb") as fh:
            body = tomllib.load(fh)
    except Exception:
        bail("failed to parse " + label + " pack " + path)
    if not isinstance(body, dict):
        bail(label + " pack is not a table: " + path)
    return body


hours = {}
for loop, value in read_pack(os.environ["WITHIN_FILE"], "horizon").items():
    # type() not isinstance: a bool would slip through as an int.
    if type(value) is not int or value <= 0:
        bail("horizon pack value for " + str(loop) + " is not a positive integer")
    hours[loop] = value

# Loop -> competence bits, one-element arrays for bare strings (the shape
# tools/tape-stuck.sh accepts).
bits = {}
for loop, value in read_pack(os.environ["LOOPS_FILE"], "loops").items():
    if isinstance(value, str):
        value = [value]
    if not isinstance(value, list) or not all(isinstance(bit, str) for bit in value):
        bail("loops pack value for " + str(loop) + " is not a bit name or array")
    bits[loop] = value

models = json.loads(os.environ["MODELS_JSON"])

def read_tape():
    path = os.environ["TAPE_FILE"]
    records = []
    if os.path.exists(path):
        try:
            fh = open(path, encoding="utf-8")
        except OSError as exc:
            bail("failed to read tape " + path + ": " + str(exc))
        with fh:
            for raw in fh:
                try:
                    rec = json.loads(raw)
                except ValueError:
                    continue
                if isinstance(rec, dict):
                    records.append(rec)
    return records

# Proposals and their last outcome, both keyed in tape order; a torn line
# yields nothing and is never fatal.
proposal = {}
last_outcome = {}
for rec in read_tape():
    kind = rec.get("type")
    if kind == "proposal":
        pid, loop, cls = rec.get("id"), rec.get("loop"), rec.get("class")
        if isinstance(pid, str) and isinstance(loop, str) and isinstance(cls, str):
            proposal[pid] = (loop, cls)
    elif kind == "outcome" and isinstance(rec.get("proposal_id"), str):
        last_outcome[rec["proposal_id"]] = rec


def success_bit(value):
    # true or 1 only — false/0 carried bits are failures, not results.
    return value is True or (type(value) in (int, float) and value == 1)


# key -> how many of its proposals came back inside the horizon.
numerators = {}
for pid, (loop, cls) in proposal.items():
    if loop not in hours:
        continue
    outcome = last_outcome.get(pid)
    if outcome is None:
        continue
    carried = outcome.get("bits")
    if not isinstance(carried, dict):
        carried = {}
    if not any(success_bit(carried.get(bit)) for bit in bits.get(loop, [])):
        continue
    numbers = outcome.get("numbers")
    if not isinstance(numbers, dict):
        continue
    duration = numbers.get("duration_s")
    if type(duration) not in (int, float):
        continue
    if duration > hours[loop] * 3600:
        continue
    key = loop + "/" + cls + "/" + models.get(pid, "-")
    numerators[key] = numerators.get(key, 0) + 1

values = {}
for index, line in enumerate(os.environ["TABLE"].splitlines()):
    if index < 2 or not line.startswith("|"):
        continue
    cells = [cell.strip() for cell in line.split("|")]
    if len(cells) < 5:
        continue
    loop = cells[1]
    if loop not in hours:
        continue
    if not re.fullmatch(r"[1-9][0-9]*", cells[4]):
        continue
    n = int(cells[4])
    key = loop + "/" + cells[2] + "/" + cells[3]
    # Half-up rounding, matching jq's round on the non-negative share.
    values[key] = str((200 * numerators.get(key, 0) + n) // (2 * n)) + "%"

sys.stdout.write(json.dumps(values))
PY
  )" || exit 1
fi

printf '%s' "$table" | table_append_column "within" "$values"
