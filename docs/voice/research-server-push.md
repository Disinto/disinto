# Research: Gemini Live Server-Initiated Turns

**Issue**: #780 (spike for #767)
**Date**: 2026-04-26

## 1. Does the Gemini Live API expose a server-initiated turn?

**Short answer: No native primitive, but a practical workaround exists.**

The Gemini Live API (protocol `v1beta` on `gemini-2.5-flash-native-audio-latest`)
uses a bidirectional WebSocket protocol with these client→server message types:

| Frame key | Purpose |
|---|---|
| `client_content` | Send structured Content turns (text, audio, images) |
| `realtime_input` | Stream raw media chunks (audio/video) |
| `tool_response` | Reply to function-call tool calls |

There is **no** dedicated `response.create`-like server-event or `model_turn`
frame that the server exposes for the client to trigger an unprompted model
response. The model only responds when it receives client input (a `client_content`
turn with `turn_complete: true`, or `realtime_input` audio that triggers VAD).

### What the SDK provides

The `google-genai` Python SDK (v0.6+) exposes four methods on `AsyncSession`:

- **`send_client_content(turns, turn_complete=True)`** — Sends structured
  `client_content` frames. When `turn_complete=True`, the model responds
  immediately. This is the recommended replacement for the deprecated `send()`.
- **`send_realtime_input(audio=...)`** — Streams raw audio; VAD triggers
  automatic model response.
- **`send_tool_response(function_responses=...)`** — Replies to tool calls.
- **`send(...)`** — Deprecated; internally routes to the above.

The current bridge (`docker/voice/bridge.py`) uses `send()` which internally
converts to `client_content` frames. The `end_of_turn` parameter maps to
`turn_complete`.

### The workaround: synthetic client_content turn

We can **inject a synthetic user turn** via `send_client_content()` mid-session.
The model treats it as if the user just spoke, so it produces a full audio
response. This is not truly "server-initiated" — it's the client telling the
server "here's a user turn" — but from the executive loop's perspective, it
achieves the same effect.

```python
# Inside an active VoiceSession, when the executive loop wants the model to speak:
await live_session.send_client_content(
    turns=[{
        "role": "user",
        "parts": [{"text": "Announcement: Your delegated task has completed."}],
    }],
    turn_complete=True,
)
```

**Constraints:**
- The model **will** respond with audio (subject to voice activity detection).
- The model **will not** know this was injected; it treats it as a normal user
  turn, so SOUL_VOICE.md's persona applies.
- This **is** a user turn, so it becomes part of the conversation context.
  Subsequent turns will see the injected message.

## 2. Constraints

### Latency

From inject → first audio frame:
- `send_client_content()` serializes the JSON, sends it over WebSocket, and the
  server begins processing. First audio frame typically arrives in **~200–500ms**
  for text prompts on `gemini-2.5-flash-native-audio-latest`.
- This is comparable to the normal user-input path (transcription → text → model).

### Interruption semantics

**What happens if the model is already speaking when we inject a turn?**

The Gemini Live API handles this by **interrupting** the current model output.
When a new `client_content` frame arrives:
1. The server stops the current model turn immediately.
2. The server processes the new input.
3. A new model turn begins with the injected text.

This is the desired behavior for the executive loop — an inbox notification
should interrupt whatever the model is currently saying.

**What if the user starts speaking (realtime_input audio) while the inject is
being read out?**

The same VAD-based interruption applies. The `realtime_input` audio stream
interrupts the model's audio output, and the model responds to the user's
actual speech. The bridge's existing `_pump_client_to_live` /
`_pump_live_to_client` goroutines handle this naturally via the concurrent
`asyncio.gather()` pattern.

### Multi-turn coherence

The injected turn **becomes part of the conversation context** because it's a
`client_content` turn (same as a normal user turn). This means:
- The model references the injected content in subsequent responses.
- The conversation history includes the synthetic turn.
- If the executive loop wants a "transient" announcement that doesn't pollute
  context, it would need a different approach (e.g., a separate TTS path).

For the use cases in #767 (thread completion, inbox notifications), context
inclusion is acceptable — the voice assistant naturally incorporates these
announcements into the conversation.

## 3. Fallback paths (if synthetic turns are insufficient)

### Option A: Local TTS + out-of-band audio streaming

Use a local TTS engine (piper, kokoro) to synthesize speech, then stream the
audio frames directly to the browser WebSocket, bypassing the Gemini session
entirely.

**Pros:** True server-initiated audio; no context pollution; full control over
interruption (pause/resume Gemini audio).

**Cons:** Requires a separate audio pipeline in the bridge; adds a TTS dependency
to the edge container; more complex state management (pause Gemini, play TTS,
resume Gemini).

### Option B: End and reopen session

Close the current Gemini session and open a new one with the announcement as the
first user message.

**Pros:** Clean context; model starts fresh.

**Cons:** High latency (~2–5s for session teardown + handshake + TTM); loses
all conversation context; disruptive to the user experience.

### Option C: Pre-tag as fake user turn (current recommendation)

The synthetic `client_content` approach described in Section 1. This is what the
bridge already does for normal user input — we just inject it from the executive
loop instead of the browser.

**Pros:** Zero new infrastructure; low latency; works with existing bridge
architecture; model naturally handles interruption.

**Cons:** Pollutes conversation context (acceptable for #767 use cases); the
voice model "thinks" the user asked, which is fine per SOUL_VOICE.md's persona.

## 4. Prior art

### OpenAI Realtime API

OpenAI's Realtime API has a dedicated `response.create` server-event that
triggers a model response without user input. This is the cleanest approach
but Gemini Live does not have an equivalent primitive.

### RealtimeVoiceChat (KoljaB)

The TypeScript library [RealtimeVoiceChat](https://github.com/KoljaB/RealtimeVoiceChat)
uses the Gemini Live API for voice interactions. It handles the client→server
protocol via `sendClientContent` and `sendRealtimeInput` methods. It does not
implement server-push — it follows the standard request/response pattern.

### Anthropic Claude Code

Claude Code's `claude -p` mode is strictly request/response with no server-push
capability. The disinto executive loop already works around this by spawning
detached `claude -p` sessions (the `delegate` tool). For Gemini Live, we don't
need this workaround because `send_client_content` provides an in-session
trigger.

## 5. Recommendation

**Use Option C (synthetic `client_content` turn) for #767.**

The synthetic turn approach is the best fit for the executive loop because:

1. **It works with the existing bridge architecture** — no new audio pipelines
   or session management.
2. **Low latency** (~200–500ms TTM), comparable to normal user input.
3. **Natural interruption semantics** — the Gemini Live API interrupts the
   current model output when a new turn arrives.
4. **Context inclusion is acceptable** — the voice assistant naturally
   incorporates announcements into the conversation.

### Implementation sketch for bridge.py

Add an `inject_turn()` coroutine to `VoiceSession`:

```python
async def inject_turn(self, text: str):
    """Inject a synthetic user turn into the Gemini session.

    Called by the executive loop to make the voice model speak
    unprompted (thread completion, inbox notifications, etc.).
    """
    try:
        await self.live_session.send_client_content(
            turns=[{
                "role": "user",
                "parts": [{"text": text}],
            }],
            turn_complete=True,
        )
    except Exception as exc:
        _log(f"inject_turn failed: {exc!r}")
```

The executive loop (future PR #767) would call this from its event handlers:

```python
# When a delegated thread completes:
await voice_session.inject_turn(
    f"Your delegated task {task_id} has completed. "
    f"Summary: {result_summary}"
)

# When an inbox event surfaces:
await voice_session.inject_turn(
    f"You have a new inbox notification: {notification_text}"
)
```

### When to reconsider Option A

If future requirements demand:
- Transient announcements that don't pollute conversation context
- Audio synthesis that's independent of the Gemini model's personality
- Sub-second TTM for time-critical alerts

...then Option A (local TTS + out-of-band streaming) becomes worth the
engineering effort.

## References

- [google-genai Python SDK](https://github.com/googleapis/python-genai)
  — `google/genai/live.py` (`AsyncSession` class)
- [Gemini Live API docs](https://cloud.google.com/gemini-live/docs)
- [OpenAI Realtime API](https://platform.openai.com/docs/guides/realtime)
  — `response.create` event (comparison)
- [RealtimeVoiceChat](https://github.com/KoljaB/RealtimeVoiceChat)
  (KoljaB)
