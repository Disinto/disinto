#!/usr/bin/env bash
# run-ledger.sh — append-only research run ledger for the ops repo (#1297)
#
# Source from the caller:
#   source "$(dirname "$0")/run-ledger.sh"
#
# Functions:
#   run_ledger_append <ops_root> <record.json>
#     - Validate a run record (required keys, id shape, field types)
#     - Write <ops_root>/runs/<id>.json (one file per id, append-only)
#     - Refuse a record whose id already exists (the ledger is never
#       rewritten or edited in place)
#
# Record contract:
#   Required keys: id, action_id, git_tree, image, host, argv, started,
#   ended, exit, artifacts (array of relative payload paths under
#   <ops_root>/artifacts/). Extra keys are allowed; missing required keys
#   fail. `id` must be filename-safe (no slashes, no leading dot).
#
# Fields do not belong in git; the record does. Payloads stay under
# <ops_root>/artifacts/<action-id>/ and are gitignored except .gitkeep
# (layout seeded by lib/ops-setup.sh — see runs/README.md there).
#
# Return codes: 0 = appended, 1 = refused (validation or duplicate id),
# 2 = usage error.

set -euo pipefail

_RUN_LEDGER_REQUIRED_KEYS="id action_id git_tree image host argv started ended exit artifacts"

run_ledger_append() {
  local ops_root="${1:-}" record_file="${2:-}"

  if [ -z "$ops_root" ] || [ -z "$record_file" ]; then
    echo "usage: run_ledger_append <ops_root> <record.json>" >&2
    return 2
  fi
  if [ ! -f "$record_file" ]; then
    echo "run_ledger_append: record file not found: $record_file" >&2
    return 2
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "run_ledger_append: jq is required" >&2
    return 2
  fi

  if ! jq -e 'type == "object"' "$record_file" >/dev/null 2>&1; then
    echo "run_ledger_append: $record_file is not a JSON object" >&2
    return 1
  fi

  # Required keys — list all that are missing, then fail.
  local missing
  missing="$(jq -r --arg req "$_RUN_LEDGER_REQUIRED_KEYS" \
    '. as $obj | [ $req | split(" ")[] | select(. as $k | ($obj | has($k)) | not) ] | join(", ")' \
    "$record_file")"
  if [ -n "$missing" ]; then
    echo "run_ledger_append: record is missing required key(s): $missing" >&2
    return 1
  fi

  # id must be a safe filename (runs/<id>.json is the target path).
  # Type first: jq -r would stringify null/number/bool (null -> runs/null.json).
  if ! jq -e '.id | type == "string"' "$record_file" >/dev/null 2>&1; then
    echo "run_ledger_append: id must be a string" >&2
    return 1
  fi
  local id
  id="$(jq -r '.id' "$record_file")"
  if ! [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "run_ledger_append: id '${id}' is not a safe filename" >&2
    return 1
  fi

  # Field types: argv and artifacts are arrays of relative-path strings,
  # exit is a number.
  if ! jq -e '(.argv | type == "array" and (map(type == "string") | all))
      and (.artifacts | type == "array" and (map(type == "string") | all))
      and (.exit | type == "number")' "$record_file" >/dev/null 2>&1; then
    echo "run_ledger_append: argv and artifacts must be arrays of strings, exit must be a number" >&2
    return 1
  fi

  local dest_dir="${ops_root}/runs"
  local dest="${dest_dir}/${id}.json"
  if [ -e "$dest" ]; then
    echo "run_ledger_append: refusing duplicate id '${id}' — ${dest} already exists (ledger is append-only)" >&2
    return 1
  fi

  mkdir -p "$dest_dir"
  local tmp
  # Template must END in X's: busybox mktemp rejects X's in the middle of
  # the name (EINVAL — "mktemp: Invalid argument" on Alpine CI).
  tmp="$(mktemp "${dest}.XXXXXX")"
  if ! cat "$record_file" > "$tmp"; then
    rm -f "$tmp"
    echo "run_ledger_append: failed writing ${dest}" >&2
    return 1
  fi
  mv "$tmp" "$dest"
  echo "run_ledger_append: appended runs/${id}.json"
}
