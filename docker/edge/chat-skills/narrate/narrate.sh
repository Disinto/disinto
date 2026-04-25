#!/usr/bin/env bash
# =============================================================================
# narrate.sh — pipe snapshot + question to local qwen llama-server
#
# Part of the chat-Claude operator surface (#761). Reads the on-box snapshot
# and sends a natural-language question to the local llama-server for
# TTS-friendly prose answers.
#
# Usage:
#   narrate.sh [question]
#   echo "question" | narrate.sh
#
# Input: question from $1 or stdin
# Output: streamed prose answer on stdout
# =============================================================================
set -euo pipefail

LLAMA_URL="${LLAMA_URL:-http://10.10.10.1:8081}"
LLAMA_MODEL="${LLAMA_MODEL:-unsloth/Qwen3.5-35B-A3B}"
SNAPSHOT_PATH="${SNAPSHOT_PATH:-/var/lib/disinto/snapshot/state.json}"
TIMEOUT="${NARRATE_TIMEOUT:-10}"

# ── Read question from $1 or stdin ───────────────────────────────────────────

question=""
if [ $# -ge 1 ]; then
  question="$1"
elif ! [ -t 0 ]; then
  question=$(cat)
fi

if [ -z "$question" ]; then
  printf 'usage: narrate.sh [question]\n' >&2
  printf '       echo "question" | narrate.sh\n' >&2
  exit 2
fi

# ── Read snapshot ────────────────────────────────────────────────────────────

if [ ! -f "$SNAPSHOT_PATH" ]; then
  printf 'Snapshot not found at %s — is the snapshot daemon running?\n' "$SNAPSHOT_PATH" >&2
  exit 1
fi

snapshot=$(cat "$SNAPSHOT_PATH")

# Validate JSON
if ! printf '%s' "$snapshot" | jq empty 2>/dev/null; then
  printf 'Snapshot file is not valid JSON — daemon may be corrupted\n' >&2
  exit 1
fi

# ── Build the API request ────────────────────────────────────────────────────

# Truncate snapshot to keep the prompt manageable. Send top-level summary
# fields plus any sub-sections that have meaningful data.
snapshot_context=$(printf '%s' "$snapshot" | jq -c '
  {
    ts: .ts,
    forge: (.forge | if .backlog_count > 0 or .in_progress_count > 0 then . else empty end),
    nomad: (.nomad | if (.jobs // [] | length) > 0 then . else empty end),
    agents: (.agents | if (length // 0) > 0 then . else empty end),
    inbox: (.inbox | if (.unread_count // 0) > 0 then . else empty end)
  }
' 2>/dev/null) || snapshot_context="{}"

body=$(jq -n -c \
  --arg model "$LLAMA_MODEL" \
  --arg question "$question" \
  --arg snapshot "$snapshot_context" \
  '{
    model: $model,
    max_tokens: 200,
    stream: true,
    system: "You are a voice assistant for the Disinto factory. Speak in short, clear sentences suitable for text-to-speech. No markdown. No code blocks. No bullet points. Plain prose only. Answer the user'\''s question using the factory snapshot data provided.",
    messages: [
      {
        "role": "user",
        "content": ("Factory snapshot context:\n" + $snapshot + "\n\nQuestion: " + $question)
      }
    ]
  }')

# ── POST to llama-server, stream deltas ──────────────────────────────────────

# The Anthropic messages API returns SSE with `data:` lines. We stream `delta`
# events and print only the `text` field to stdout.
curl -fsS --max-time "$TIMEOUT" \
  -H "Content-Type: application/json" \
  -H "x-api-key: sk-no-key-required" \
  --data-utf8 "$body" \
  "$LLAMA_URL/v1/messages" 2>/dev/null | \
while IFS= read -r line; do
  # Skip non-data lines
  [[ "$line" == data:* ]] || continue

  # Extract the JSON payload from the SSE line
  payload="${line#data: }"

  # Skip [DONE]
  [ "$payload" = "[DONE]" ] && continue

  # Extract text from delta events
  text=$(printf '%s' "$payload" | jq -r '.delta.text // empty' 2>/dev/null) || continue
  if [ -n "$text" ]; then
    printf '%s' "$text"
  fi
done

printf '\n'
