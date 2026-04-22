#!/usr/bin/env bash
# =============================================================================
# lib/init/nomad/wp-seed-secrets.sh — Seed Woodpecker repo secrets from .env
#
# Part of issue #603. After Woodpecker is up and the project repo is activated
# (see wp-activate-repo.sh), this script seeds the repo-level secrets needed
# by release-triggered pipelines (e.g. .woodpecker/publish-images.yml):
#
#   - GHCR_TOKEN  — push access to ghcr.io/disinto/*
#   - FORGE_TOKEN — authenticate the clone step against Forgejo
#
# The list of secret names is configurable via SECRET_NAMES (space-separated);
# each name is read from the environment. Missing env vars produce a warning
# (not a hard error) — operators can add them later via the WP UI or by
# re-running init after updating .env.
#
# Why direct sqlite3 insert (and not the WP REST API):
#   Woodpecker's /api/repos/{id}/secrets endpoint requires a WP session token
#   which only exists after an interactive OAuth login. Headless factory init
#   has no such token, so we seed the DB row directly (same reasoning as
#   wp-activate-repo.sh).
#
# Idempotency:
#   Upsert on (repo_id, name). Re-running overwrites the value with the
#   current env-var value — .env is the source of truth.
#
# Preconditions:
#   - Woodpecker sqlite DB present at $WP_DB
#   - wp-activate-repo.sh has already inserted the project repo row
#   - FORGE_REPO set (e.g. disinto-admin/disinto)
#
# Requires: python3 (stdlib sqlite3)
#
# Usage:
#   lib/init/nomad/wp-seed-secrets.sh
#   lib/init/nomad/wp-seed-secrets.sh --dry-run
#
# Exit codes:
#   0  success (secrets seeded, or all env vars absent and warned)
#   1  precondition failure (missing DB, repo row, or python3)
# =============================================================================
set -euo pipefail

FORGE_REPO="${FORGE_REPO:-}"
WP_DB="${WP_DB:-/srv/disinto/woodpecker-data/woodpecker.sqlite}"
SECRET_NAMES="${SECRET_NAMES:-GHCR_TOKEN FORGE_TOKEN}"
# Events the seeded secrets should be available to. publish-images.yml
# triggers on tags; push is included so any future release-trigger variant
# (e.g. semver tags via push to release branch) also works without rework.
# Default stored as a single-quoted JSON literal — `[...]` inside bash
# parameter-expansion defaults is parsed as a bracket expression.
SECRET_EVENTS="${SECRET_EVENTS:-$(printf '["tag","push"]')}"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      printf 'Usage: %s [--dry-run]\n\n' "$(basename "$0")"
      printf 'Seed Woodpecker repo secrets from .env for release pipelines.\n\n'
      printf 'Env:\n'
      printf '  FORGE_REPO     Project repo slug (owner/name), required\n'
      printf '  WP_DB          Path to woodpecker.sqlite (default: /srv/disinto/woodpecker-data/woodpecker.sqlite)\n'
      printf '  SECRET_NAMES   Space-separated secret names (default: "GHCR_TOKEN FORGE_TOKEN")\n'
      printf '  SECRET_EVENTS  JSON array of event names (default: ["tag","push"])\n'
      exit 0
      ;;
    *)
      printf '[wp-seed-secrets] ERROR: unknown argument: %s\n' "$arg" >&2
      exit 1
      ;;
  esac
done

LOG_TAG="[wp-seed-secrets]"
log() { printf '%s %s\n' "$LOG_TAG" "$*" >&2; }
die() { printf '%s ERROR: %s\n' "$LOG_TAG" "$*" >&2; exit 1; }

[ -n "$FORGE_REPO" ] || die "FORGE_REPO required (e.g. disinto-admin/disinto)"
[ -f "$WP_DB" ]      || die "WP sqlite DB not found at $WP_DB"
command -v python3 >/dev/null 2>&1 || die "python3 required"

# Collect present + absent secrets from the environment. Warn on absent ones
# and continue — operator can add later without needing to re-run init.
present_names=()
present_values=()
for name in $SECRET_NAMES; do
  val="${!name:-}"
  if [ -z "$val" ]; then
    log "skip ${name} (not set in environment / .env)"
    continue
  fi
  present_names+=("$name")
  present_values+=("$val")
done

if [ "${#present_names[@]}" -eq 0 ]; then
  log "no secrets to seed — done"
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  for name in "${present_names[@]}"; do
    log "[dry-run] would upsert secret ${name} for ${FORGE_REPO}"
  done
  exit 0
fi

# Hand off to python3 for sqlite3 access + schema discovery. Names and
# values are serialized to a mode-0600 tempfile so secret material never
# lands on argv (visible to `ps`) and the python subprocess reads the
# same file — heredoc-as-stdin would have conflicted with us piping the
# data in (shellcheck SC2259).
#
# Protocol: one name<TAB>value pair per line, terminated by EOF.
pairs_file="$(mktemp)"
chmod 600 "$pairs_file"
cleanup_pairs() { rm -f "$pairs_file"; }
trap cleanup_pairs EXIT

for i in "${!present_names[@]}"; do
  # Strip any literal tab/newline from values defensively. Tokens never
  # contain these, so this is a belt-and-braces sanitization.
  v="${present_values[$i]//$'\t'/}"
  v="${v//$'\n'/}"
  printf '%s\t%s\n' "${present_names[$i]}" "$v" >> "$pairs_file"
done

FORGE_REPO="$FORGE_REPO" WP_DB="$WP_DB" SECRET_EVENTS="$SECRET_EVENTS" \
  LOG_TAG="$LOG_TAG" PAIRS_FILE="$pairs_file" \
  python3 - <<'PY'
import json
import os
import sqlite3
import sys

WP_DB       = os.environ["WP_DB"]
FORGE_REPO  = os.environ["FORGE_REPO"]
PAIRS_FILE  = os.environ["PAIRS_FILE"]
EVENTS_JSON = os.environ.get("SECRET_EVENTS", '["tag","push"]')
LOG_TAG     = os.environ.get("LOG_TAG", "[wp-seed-secrets]")

def log(msg):
    print(f"{LOG_TAG} {msg}", file=sys.stderr)

def die(msg, code=1):
    print(f"{LOG_TAG} ERROR: {msg}", file=sys.stderr)
    sys.exit(code)

# Validate events JSON early.
try:
    json.loads(EVENTS_JSON)
except json.JSONDecodeError as e:
    die(f"SECRET_EVENTS is not valid JSON: {e}")

c = sqlite3.connect(WP_DB)

# 1. Look up the repo row so we can key secrets by repo_id.
row = c.execute(
    "SELECT id FROM repos WHERE full_name=? LIMIT 1", (FORGE_REPO,)
).fetchone()
if row is None:
    die(
        f"repo row for '{FORGE_REPO}' not found in {WP_DB} — "
        "run wp-activate-repo.sh first"
    )
repo_id = row[0]

# 2. Discover the secrets table schema. Column names vary across Woodpecker
#    versions (v3 uses a `secret_` prefix on most columns). We introspect
#    to stay version-robust.
pragma = c.execute("PRAGMA table_info(secrets)").fetchall()
if not pragma:
    die("secrets table not found in WP DB (schema unexpected)")

cols = {row[1] for row in pragma}  # row[1] is column name

def pick(*candidates):
    """Return the first column name from `candidates` present in `cols`,
    or None if none match. Lets us handle schema variants across WP versions."""
    for name in candidates:
        if name in cols:
            return name
    return None

col_repo_id  = pick("secret_repo_id", "repo_id")
col_name     = pick("secret_name", "name")
col_value    = pick("secret_value", "value")
col_events   = pick("secret_events", "events")
col_images   = pick("secret_images", "images")
col_plugins  = pick("secret_plugins_only", "plugins_only")
col_org_id   = pick("secret_org_id", "org_id")

missing = [
    label for label, val in [
        ("repo_id", col_repo_id),
        ("name",    col_name),
        ("value",   col_value),
    ] if val is None
]
if missing:
    die(f"secrets table missing required columns: {missing} (have: {sorted(cols)})")

# 3. Read (name, value) pairs from the tempfile and upsert into secrets.
pairs = []
with open(PAIRS_FILE, "r") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        name, _, value = line.partition("\t")
        if not name or not value:
            continue
        pairs.append((name, value))

if not pairs:
    log("no secret pairs received from PAIRS_FILE — nothing to do")
    sys.exit(0)

# Build INSERT column list dynamically. Unknown-but-present columns get
# schema-appropriate defaults (JSON empty array, 0 for bool, 0 for org_id).
def build_row(name, value):
    row = {
        col_repo_id: repo_id,
        col_name:    name,
        col_value:   value,
    }
    if col_events is not None:
        row[col_events] = EVENTS_JSON
    if col_images is not None:
        row[col_images] = "[]"
    if col_plugins is not None:
        row[col_plugins] = 0
    if col_org_id is not None:
        row[col_org_id] = 0
    return row

for name, value in pairs:
    existing = c.execute(
        f"SELECT rowid FROM secrets WHERE {col_repo_id}=? AND {col_name}=? LIMIT 1",
        (repo_id, name),
    ).fetchone()
    row = build_row(name, value)
    if existing is not None:
        # Update all managed columns (value + events + images + plugins_only).
        set_cols = [k for k in row if k not in (col_repo_id, col_name)]
        set_sql  = ", ".join(f"{k}=?" for k in set_cols)
        params   = [row[k] for k in set_cols] + [existing[0]]
        c.execute(f"UPDATE secrets SET {set_sql} WHERE rowid=?", params)
        log(f"{name} updated (repo_id={repo_id})")
    else:
        col_list = list(row.keys())
        placeholders = ", ".join("?" for _ in col_list)
        params = [row[k] for k in col_list]
        c.execute(
            f"INSERT INTO secrets ({', '.join(col_list)}) VALUES ({placeholders})",
            params,
        )
        log(f"{name} inserted (repo_id={repo_id})")

c.commit()
log(f"done — {len(pairs)} secret(s) seeded for {FORGE_REPO}")
PY
