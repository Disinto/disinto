# narrate — pipe snapshot + question to local qwen llama-server

> Trigger phrases: "walk me through", "summarize", "explain", "tell me about",
> "what's the story with", "narrate".

This skill sends a natural-language question and the current factory snapshot
to a local Qwen model running on the on-box llama-server. It returns
TTS-friendly prose — short sentences, no markdown, no code blocks.

## When to use

- Voice queries that need a prose summary rather than structured data.
- "Walk me through the sprint draft", "summarize the PR queue", "what's the
  story with the nomad alerts".
- Any time the operator wants a conversational answer, not a raw table.

## Commands

| Command | Purpose |
| --- | --- |
| `narrate.sh [question]` | Pipe or pass a question on `$1`. Reads snapshot context and streams a prose answer to stdout. |

## How it works

1. Reads `/var/lib/disinto/snapshot/state.json` (the snapshot daemon writes
   this file every 5 seconds).
2. Extracts the full snapshot as structured context.
3. POSTs to `http://10.10.10.1:8081/v1/messages` (the local llama-server)
   with model `unsloth/Qwen3.5-35B-A3B`, `max_tokens` 200.
4. Streams the streamed response (delta events) to stdout.
5. Times out after 10 seconds.

## System prompt

The model receives a system prompt that enforces TTS-friendly output:
short sentences, no markdown, no code blocks, plain prose only.

## Timeout

All HTTP requests to the llama-server use a 10-second timeout. If the
server is slow or unresponsive, the script prints an error and exits 1.

## Examples

User: "walk me through the sprint draft"
→ `narrate.sh "Walk me through the sprint draft. What issues are we working on and what's blocked?"`
→ Streams a short prose summary.

User: "summarize the PR queue"
→ `echo "Summarize the PR queue" | narrate.sh`
→ Streams a short prose summary.

## Data source

The snapshot at `/var/lib/disinto/snapshot/state.json` contains the current
factory state: nomad jobs, forge tracker, agent assignments, inbox items.
The full snapshot is sent as context so the model can reference real data
in its answer.
