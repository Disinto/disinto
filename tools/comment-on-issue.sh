#!/usr/bin/env bash
# =============================================================================
# tools/comment-on-issue.sh — post a comment on a Forgejo issue and (optionally)
# adjust labels and state, all via the REST API.
#
# Wraps the curl + Forgejo-API boilerplate so the acceptance-tests pipeline
# (.woodpecker/acceptance-tests.yml) can stay declarative. Designed to be
# called once per issue per pipeline step.
#
# Usage:
#   tools/comment-on-issue.sh <issue-number> [options]
#
# Required env:
#   FACTORY_FORGE_PAT  — write:issues PAT (same secret as publish-images.yml).
#   FORGE_URL          — e.g. https://codeberg.org (no trailing slash).
#   FORGE_REPO         — owner/repo, e.g. disinto-admin/disinto.
#                        Alternatively set FORGE_API directly to override.
#
# Options:
#   --body <text>           Comment body (or use --body-file).
#   --body-file <path>      Read comment body from a file (use '-' for stdin).
#   --add-label <name>      Add a label by name (looked up by exact match).
#                            Repeatable.
#   --remove-label <name>   Remove a label by name. Repeatable. Missing-label
#                            removals are tolerated (idempotent).
#   --reopen                PATCH the issue back to state=open.
#   --close                 PATCH the issue to state=closed.
#   --dry-run               Print the API calls instead of executing them.
#   -h, --help              Show this help.
#
# Behaviour:
#   - Operations run in this order: comment → labels (add then remove) →
#     state change. Each operation is independent — a failed label add does
#     not skip the state change. The script exits non-zero if any single
#     operation fails (with a per-operation error message on stderr) so the
#     pipeline can flag a partial failure.
#   - Label name lookup hits /api/v1/repos/<repo>/labels and matches by
#     exact name. Names are case-sensitive (Forgejo convention).
#
# Exit codes:
#   0   all requested operations succeeded
#   1   at least one operation failed
#   2   usage / argument error
# =============================================================================
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tools/comment-on-issue.sh <issue-number> [options]

Required env: FACTORY_FORGE_PAT, FORGE_URL, FORGE_REPO (or FORGE_API).

Options:
  --body <text>           Comment body (or use --body-file).
  --body-file <path>      Read comment body from a file (use '-' for stdin).
  --add-label <name>      Add a label by name (repeatable).
  --remove-label <name>   Remove a label by name (repeatable, idempotent).
  --reopen                PATCH the issue back to state=open.
  --close                 PATCH the issue to state=closed.
  --dry-run               Print the API calls instead of executing them.
  -h, --help              Show this help.
EOF
}

die() { echo "comment-on-issue: error: $*" >&2; exit 2; }

ISSUE=""
BODY=""
BODY_FILE=""
ADD_LABELS=()
REMOVE_LABELS=()
NEW_STATE=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --body)
      shift; [ $# -gt 0 ] || die "--body requires an argument"
      BODY="$1"; shift ;;
    --body-file)
      shift; [ $# -gt 0 ] || die "--body-file requires an argument"
      BODY_FILE="$1"; shift ;;
    --add-label)
      shift; [ $# -gt 0 ] || die "--add-label requires an argument"
      ADD_LABELS+=("$1"); shift ;;
    --remove-label)
      shift; [ $# -gt 0 ] || die "--remove-label requires an argument"
      REMOVE_LABELS+=("$1"); shift ;;
    --reopen)
      NEW_STATE="open"; shift ;;
    --close)
      NEW_STATE="closed"; shift ;;
    --dry-run)
      DRY_RUN=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift; break ;;
    -*)
      die "unknown flag: $1" ;;
    *)
      if [ -z "$ISSUE" ]; then
        ISSUE="$1"
      else
        die "unexpected argument: $1"
      fi
      shift ;;
  esac
done

[ -n "$ISSUE" ] || die "issue number required"
case "$ISSUE" in
  ''|*[!0-9]*) die "issue must be a positive integer, got: $ISSUE" ;;
esac

# If --body and --body-file both unset, but no other ops requested either,
# that's a no-op — refuse so callers don't accidentally pass nothing.
if [ -z "$BODY" ] && [ -z "$BODY_FILE" ] \
   && [ "${#ADD_LABELS[@]}" -eq 0 ] && [ "${#REMOVE_LABELS[@]}" -eq 0 ] \
   && [ -z "$NEW_STATE" ]; then
  die "no operation requested (need --body, --body-file, --add-label, --remove-label, --reopen, or --close)"
fi

# Resolve body content if a file was given.
if [ -n "$BODY_FILE" ]; then
  if [ "$BODY_FILE" = "-" ]; then
    BODY="$(cat)"
  else
    [ -r "$BODY_FILE" ] || die "body file not readable: $BODY_FILE"
    BODY="$(cat "$BODY_FILE")"
  fi
fi

# ── Env / endpoint resolution ────────────────────────────────────────────────
: "${FACTORY_FORGE_PAT:?FACTORY_FORGE_PAT is required (write:issues)}"

if [ -z "${FORGE_API:-}" ]; then
  : "${FORGE_URL:?FORGE_URL or FORGE_API is required}"
  : "${FORGE_REPO:?FORGE_REPO or FORGE_API is required}"
  FORGE_API="${FORGE_URL%/}/api/v1/repos/${FORGE_REPO}"
fi

AUTH_HDR="Authorization: token ${FACTORY_FORGE_PAT}"
EXIT_CODE=0

# Generic API caller. Args: METHOD PATH [JSON_BODY]. Echoes response body.
# Sets a non-zero EXIT_CODE on HTTP error but does not abort the script
# (each operation is independent).
api_call() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local url="${FORGE_API%/}/${path#/}"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY-RUN: $method $url"
    [ -n "$body" ] && echo "BODY: $body"
    return 0
  fi

  local args=(-sS -o /tmp/comment-on-issue-resp.$$ -w '%{http_code}'
              -X "$method"
              -H "$AUTH_HDR"
              -H "Content-Type: application/json"
              -H "Accept: application/json")
  if [ -n "$body" ]; then
    args+=(--data "$body")
  fi

  local code
  code="$(curl "${args[@]}" "$url" || echo "000")"
  local resp=""
  [ -f /tmp/comment-on-issue-resp.$$ ] && resp="$(cat /tmp/comment-on-issue-resp.$$)"
  rm -f /tmp/comment-on-issue-resp.$$

  case "$code" in
    2*)
      printf '%s' "$resp"
      return 0 ;;
    *)
      echo "comment-on-issue: $method $url failed (HTTP $code): $resp" >&2
      EXIT_CODE=1
      return 1 ;;
  esac
}

# ── 1. Post the comment ──────────────────────────────────────────────────────
if [ -n "$BODY" ]; then
  body_json="$(jq -nc --arg b "$BODY" '{body: $b}')"
  api_call POST "/issues/${ISSUE}/comments" "$body_json" >/dev/null \
    || true  # error already logged + EXIT_CODE bumped
fi

# ── 2. Label management ──────────────────────────────────────────────────────
# Resolve label names → ids only when needed (one fetch covers all label ops).
LABELS_JSON=""
fetch_labels() {
  [ -n "$LABELS_JSON" ] && return 0
  LABELS_JSON="$(api_call GET "/labels?limit=200" "")" || LABELS_JSON=""
}

label_id_for() {
  local name="$1"
  fetch_labels
  printf '%s' "$LABELS_JSON" \
    | jq -r --arg n "$name" '.[] | select(.name == $n) | .id' \
    | head -n1
}

for name in "${ADD_LABELS[@]:-}"; do
  [ -z "$name" ] && continue
  lid="$(label_id_for "$name" || true)"
  if [ -z "$lid" ]; then
    echo "comment-on-issue: label '$name' not found in repo — skipping add" >&2
    EXIT_CODE=1
    continue
  fi
  body_json="$(jq -nc --argjson id "$lid" '{labels: [$id]}')"
  api_call POST "/issues/${ISSUE}/labels" "$body_json" >/dev/null || true
done

for name in "${REMOVE_LABELS[@]:-}"; do
  [ -z "$name" ] && continue
  lid="$(label_id_for "$name" || true)"
  if [ -z "$lid" ]; then
    # Missing label is fine for removal — idempotent.
    continue
  fi
  api_call DELETE "/issues/${ISSUE}/labels/${lid}" "" >/dev/null || true
done

# ── 3. State change ──────────────────────────────────────────────────────────
if [ -n "$NEW_STATE" ]; then
  body_json="$(jq -nc --arg s "$NEW_STATE" '{state: $s}')"
  api_call PATCH "/issues/${ISSUE}" "$body_json" >/dev/null || true
fi

exit "$EXIT_CODE"
