#!/usr/bin/env bash
# =============================================================================
# tools/tape-stuck.sh — proposals stuck beyond their loop's horizon (#1648)
#
# Calibration (#1393) drops every proposal that never got an outcome carrying
# its loop's competence bit, so nothing coming back reads as nothing. The
# design (gut): a proposal with no competence outcome after its loop's horizon
# counts as one failure sample, read at read time; no record is written. This
# tool is that reader; #1649 wires it into tools/calibration.sh.
#
# A proposal on ${TAPE_DIR:-/srv/disinto/tape}/tape.jsonl is stuck when its
# loop is a key of both the loops pack and the stuck pack, its `decision` is
# not `rejected`, its `t` is more than the loop's hours before the clock
# ($CALIBRATION_NOW, ISO-8601 UTC, defaults to now), and its last outcome in
# tape order carries none of the loop's competence bits with a value true,
# false, 1 or 0 — or it has no outcome at all.
#
# Usage:
#   tools/tape-stuck.sh [LOOPS_JSON]
#
#   LOOPS_JSON — the loops pack as tools/calibration.sh parses it, an object of
#   loop name to array of competence-bit names
#   ({"dev": ["merged", "rejected"], "sprint": ["effect"]}); a string value is
#   read as a one-element array. Without it, the tool reads the loops pack from
#   ${CALIBRATION_LOOPS_FILE:-${OPS_REPO_ROOT:-/home/agent/repos/_factory/disinto-ops}/packs/loops.toml}
#   with python3 tomllib (a string value is a one-element array, as
#   calibration.sh does); a missing or unparsable loops pack exits 1.
#
# Stuck pack: flat `loop = <hours>` TOML at
#   ${CALIBRATION_STUCK_FILE:-${OPS_REPO_ROOT:-/home/agent/repos/_factory/disinto-ops}/packs/stuck.toml},
# read with python3 tomllib, as lib/signature.sh does. Missing file: prints `[]`
# and exits 0. Unparsable, or a value that is not a positive integer: exit 1.
#
# Output: one JSON array on stdout, one object per stuck proposal, in the order
# the proposals appear in the tape. Each object has the sample shape calibration
# groups on:
#   {"loop","class","promised","est_dvision","competence","duration","signature"}
#   - loop, class       from the proposal record
#   - promised          the proposal's forecast.p_success when it is a number,
#                       else null
#   - est_dvision       always null — a stuck proposal never reached a
#                       competence outcome, so there is no duration to compare
#                       its forecast against
#   - competence        [false] — it counts as one failure sample
#   - duration          always null — no competence outcome, nothing to average
#   - signature         "stuck" — for the signatures column (#1651)
#
# No record is written: the tape is only read. A missing or empty tape, or one
# with no stuck proposals, prints `[]`. Malformed tape lines (a torn final line
# from a crashed writer) are skipped with a stderr note, as lib/stats.sh does;
# they never fail the listing.
#
# Bash plus inline python3 (tomllib for the packs, the tape listing); nothing
# else. No git, no network.
#
# Exit codes:
#   0  JSON array printed
#   1  python3 missing, or the loops pack (argument omitted) is missing or
#      unparsable, or the stuck pack is unparsable / carries a value that is
#      not a positive integer, or the clock ($CALIBRATION_NOW) is unparseable
# =============================================================================
set -euo pipefail

command -v python3 >/dev/null 2>&1 || { echo "tape-stuck: required tool missing: python3" >&2; exit 1; }

TAPE_DIR="${TAPE_DIR:-/srv/disinto/tape}"
TAPE_FILE="${TAPE_DIR}/tape.jsonl"
NOW="${CALIBRATION_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

# ── Loops pack (loop -> array of competence-bit names) as JSON ──────────────

if [ -n "${1:-}" ]; then
  # Caller-supplied pack (calibration.sh's parsed shape): values are normalised
  # in the listing (string -> one-element array; non-list, non-string -> no
  # bits). A non-JSON pack is reported by the listing.
  PACK_JSON="$1"
else
  LOOPS_FILE="${CALIBRATION_LOOPS_FILE:-${OPS_REPO_ROOT:-/home/agent/repos/_factory/disinto-ops}/packs/loops.toml}"
  if [ ! -f "$LOOPS_FILE" ]; then
    echo "tape-stuck: loops pack file missing: $LOOPS_FILE" >&2
    exit 1
  fi
  # Parse the pack (a flat TOML, one assignment per loop) to JSON, promoting
  # string values to one-element arrays. A non-dict body, or a value that is
  # neither a string nor a string array, is an unparsable pack (exit 1).
  PACK_JSON="$(
    TOML_FILE="$LOOPS_FILE" python3 - <<'PYEOF'
import json, os, tomllib
try:
    with open(os.environ["TOML_FILE"], "rb") as f:
        data = tomllib.load(f)
except Exception:
    raise SystemExit(1)
if not isinstance(data, dict):
    raise SystemExit(1)
out = {}
for k, v in data.items():
    if isinstance(v, str):
        v = [v]
    if not isinstance(v, list) or not all(isinstance(b, str) for b in v):
        raise SystemExit(1)
    out[k] = v
print(json.dumps(out))
PYEOF
  )" || { echo "tape-stuck: failed to parse loops pack $LOOPS_FILE" >&2; exit 1; }
fi

# ── Stuck pack (loop -> hours) as JSON ──────────────────────────────────────

STUCK_FILE="${CALIBRATION_STUCK_FILE:-${OPS_REPO_ROOT:-/home/agent/repos/_factory/disinto-ops}/packs/stuck.toml}"
if [ -f "$STUCK_FILE" ]; then
  # Flat TOML, one `loop = <hours>` assignment per loop (lib/signature.sh
  # style: python3 tomllib, TOML_FILE on the environment). A positive integer
  # is int type (bool excluded) greater than 0; a string, a float, a nested
  # table, or an unparseable body is exit 1.
  STUCK_JSON="$(
    TOML_FILE="$STUCK_FILE" python3 - <<'PYEOF'
import json, os, tomllib
try:
    with open(os.environ["TOML_FILE"], "rb") as f:
        data = tomllib.load(f)
except Exception:
    raise SystemExit(1)
if not isinstance(data, dict):
    raise SystemExit(1)
out = {}
for k, v in data.items():
    if type(v) is not int or v <= 0:
        raise SystemExit(1)
    out[k] = v
print(json.dumps(out))
PYEOF
  )" || { echo "tape-stuck: failed to parse stuck pack $STUCK_FILE" >&2; exit 1; }
else
  # No stuck pack: no horizon is named, so nothing can be stuck.
  STUCK_JSON="{}"
fi

# ── Tape listing ─────────────────────────────────────────────────────────────

if [ -f "$TAPE_FILE" ] && [ -s "$TAPE_FILE" ]; then
  # stdout: the JSON array (only on success); stderr: either the number of
  # malformed lines skipped (a bare integer, 0 when none), or a one-line error.
  err_file="$(mktemp)"
  rc=0
  out="$(
    NOW="$NOW" PACK_JSON="$PACK_JSON" STUCK_JSON="$STUCK_JSON" TAPE_FILE="$TAPE_FILE" \
    python3 - <<'PYEOF' 2>"$err_file"
import json, os, sys
from datetime import datetime, timedelta, timezone

def parse_iso8601(s):
    """ISO-8601 UTC (Z) -> aware datetime; naive input is taken as UTC.
    Returns None when the string is not parseable."""
    s = s.strip()
    if s.endswith(("Z", "z")):
        s = s[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(s)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt

def fail(msg):
    sys.stderr.write(msg + "\n")
    sys.exit(1)

try:
    loops = json.loads(os.environ["PACK_JSON"])
except ValueError:
    fail("unparseable loops pack")
if not isinstance(loops, dict):
    loops = {}
try:
    stuck = json.loads(os.environ["STUCK_JSON"])
except ValueError:
    fail("unparseable stuck pack")
if not isinstance(stuck, dict):
    stuck = {}

now = parse_iso8601(os.environ["NOW"])
if now is None:
    fail("unparseable clock: " + os.environ["NOW"])

def carry(v):
    # true / false / 1 / 0 — exactly the values tape writers emit for bits;
    # matches calibration.sh's `select(. == true or . == false or . == 1
    # or . == 0)`.
    return isinstance(v, bool) or (isinstance(v, (int, float)) and (v == 1 or v == 0))

proposals = []      # in tape (append) order
outcomes = {}       # proposal_id -> outcome records, in tape order
skipped = 0
with open(os.environ["TAPE_FILE"], "r", encoding="utf-8") as f:
    for line in f:
        s = line.strip()
        rec = None
        if s:
            try:
                rec = json.loads(s)
            except ValueError:
                rec = None
        if not isinstance(rec, dict):
            skipped += 1
            continue
        ttype = rec.get("type")
        if ttype == "proposal":
            pid = rec.get("id")
            loop = rec.get("loop")
            cls = rec.get("class")
            if not (isinstance(pid, str) and isinstance(loop, str) and isinstance(cls, str)):
                continue
            forecast = rec.get("forecast")
            promised = None
            if isinstance(forecast, dict):
                p = forecast.get("p_success")
                if isinstance(p, (int, float)) and not isinstance(p, bool):
                    promised = p
            proposals.append({
                "id": pid,
                "loop": loop,
                "class": cls,
                "decision": rec.get("decision"),
                "t": rec.get("t"),
                "promised": promised,
            })
        elif ttype == "outcome":
            pid = rec.get("proposal_id")
            if isinstance(pid, str):
                outcomes.setdefault(pid, []).append(rec)

samples = []
for p in proposals:
    loop = p["loop"]
    if loop not in loops or loop not in stuck:
        continue
    if p["decision"] == "rejected":
        continue
    t = p["t"]
    if not isinstance(t, str):
        continue
    dt = parse_iso8601(t)
    if dt is None:
        continue
    horizon = timedelta(hours=float(stuck[loop]))
    if not (now - dt > horizon):
        continue
    bits = loops[loop]
    if not isinstance(bits, list):
        bits = [bits] if isinstance(bits, str) else []
    last_outcomes = outcomes.get(p["id"])
    if last_outcomes:
        last = last_outcomes[-1]
        bits_obj = last.get("bits")
        bits_obj = bits_obj if isinstance(bits_obj, dict) else {}
        if any(b in bits_obj and carry(bits_obj[b]) for b in bits):
            continue
    samples.append({
        "loop": p["loop"],
        "class": p["class"],
        "promised": p["promised"],
        "est_dvision": None,
        "competence": [False],
        "duration": None,
        "signature": "stuck",
    })

sys.stdout.write(json.dumps(samples) + "\n")
if skipped:
    sys.stderr.write(str(skipped) + "\n")
PYEOF
  )" || rc=$?
  err="$(cat "$err_file" 2>/dev/null || true)"
  rm -f "$err_file"
  if [ "$rc" -ne 0 ]; then
    if [ -n "$err" ]; then
      echo "tape-stuck: $err" >&2
    else
      echo "tape-stuck: failed to list ${TAPE_FILE}" >&2
    fi
    exit 1
  fi
  if [ -n "$err" ]; then
    echo "tape-stuck: skipped ${err} malformed line(s) in ${TAPE_FILE}" >&2
  fi
  printf '%s\n' "$out"
else
  echo "[]"
fi
exit 0