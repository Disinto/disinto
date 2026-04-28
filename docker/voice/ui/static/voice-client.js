// disinto-voice browser client (parent issue #651, this file implements #663).
//
// Captures the microphone, runs Silero VAD via @ricky0123/vad-web (loaded
// in index.html as the global `vad`), and streams VAD-gated speech turns
// over a WebSocket to docker/voice/bridge.py (#662).
//
// Wire format mirrors the bridge (docker/voice/bridge.py):
//   client → server, JSON text frame: {"type":"hello","conversation_id":"<12-hex>"}
//   client → server, binary frame:    PCM16 mono 16kHz audio chunks
//   client → server, JSON text frame: {"type":"end_of_turn"} after speech end
//   server → client, JSON text frame: {"type":"ready"|"think_start"|"think_end"|
//                                       "transcript"|"error", ...}
//   server → client, binary frame:    PCM16 mono ~24kHz Gemini Live audio
//
// The page is gated by forward_auth (Caddy edge.hcl) so the WebSocket
// upgrade only succeeds when the browser carries a valid Forgejo OAuth
// session cookie — no API key handling lives in the browser.

(function () {
  "use strict";

  // Sample rates pinned by the audio contract above. Gemini Live emits
  // 24kHz PCM16 mono on the output side; the bridge expects 16kHz PCM16
  // mono on the input side (matches Silero VAD's native rate, no resample).
  const INPUT_SAMPLE_RATE = 16000;
  const OUTPUT_SAMPLE_RATE = 24000;

  // Chunk the gated speech buffer into roughly-50ms binary frames so
  // Gemini Live can begin reacting before the speaker has stopped speaking.
  const FRAME_SAMPLES = 800; // 50ms @ 16kHz

  // ── DOM handles ───────────────────────────────────────────────────────────
  const body = document.body;
  const stateLabel = document.getElementById("state-label");
  const stateDetail = document.getElementById("state-detail");
  const startBtn = document.getElementById("start-btn");
  const stopBtn = document.getElementById("stop-btn");
  const transcriptEl = document.getElementById("transcript");
  const convIdEl = document.getElementById("conv-id");

  // ── Conversation id ───────────────────────────────────────────────────────
  // Reuse the chat plumbing convention: conv_id is a 12-hex string. Allow
  // the operator to pin one via ?conv=<id> in the URL so a voice session
  // can attach to an existing chat (see docker/voice/bridge.py header
  // comment for the sibling-session convention).
  function newConvId() {
    const bytes = new Uint8Array(6);
    crypto.getRandomValues(bytes);
    return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
  }
  const params = new URLSearchParams(window.location.search);
  const convId = params.get("conv") || newConvId();
  convIdEl.textContent = convId;

  // ── State machine ─────────────────────────────────────────────────────────
  // Drives the orb colour + label in index.html. States flow:
  //   idle → connecting → listening ↔ speech → thinking → speaking → listening
  // "error" is a sticky terminal state; the user must press start again.
  function setState(name, detail) {
    body.dataset.state = name;
    stateLabel.textContent = name;
    if (detail !== undefined) stateDetail.textContent = detail;
  }

  function transcriptLine(text, kind) {
    if (transcriptEl.querySelector(".empty")) transcriptEl.innerHTML = "";
    const line = document.createElement("div");
    line.className = "transcript-line" + (kind ? " " + kind : "");
    const ts = document.createElement("span");
    ts.className = "ts";
    ts.textContent = new Date().toLocaleTimeString();
    line.appendChild(ts);
    line.appendChild(document.createTextNode(text));
    transcriptEl.appendChild(line);
    transcriptEl.scrollTop = transcriptEl.scrollHeight;
  }

  // ── WebSocket plumbing ────────────────────────────────────────────────────
  let ws = null;
  let micVad = null;
  // Expose mic VAD globally so PcmPlayer can pause/resume it during "speaking" state.
  // (See PcmPlayer.enqueuePcm16 / src.onended for the pause/resume logic.)
  let player = null;

  function wsUrl() {
    const proto = window.location.protocol === "https:" ? "wss:" : "ws:";
    return proto + "//" + window.location.host + "/voice/ws";
  }

  function send(obj) {
    if (!ws || ws.readyState !== WebSocket.OPEN) return false;
    ws.send(JSON.stringify(obj));
    return true;
  }

  function sendBinary(buf) {
    if (!ws || ws.readyState !== WebSocket.OPEN) return false;
    ws.send(buf);
    return true;
  }

  // ── Audio: Float32 [-1,1] → little-endian PCM16 ───────────────────────────
  function floatToPcm16(float32) {
    const out = new Int16Array(float32.length);
    for (let i = 0; i < float32.length; i++) {
      let s = Math.max(-1, Math.min(1, float32[i]));
      out[i] = s < 0 ? s * 0x8000 : s * 0x7fff;
    }
    return out;
  }

  // ── Streaming PCM player ──────────────────────────────────────────────────
  // Gemini Live emits raw PCM16 at OUTPUT_SAMPLE_RATE in chunks; we queue
  // each chunk into an AudioContext-scheduled buffer so playback is
  // gapless and the orb flips to "speaking" only while audio is queued.
  class PcmPlayer {
    constructor(sampleRate) {
      this.sampleRate = sampleRate;
      this.ctx = null;
      this.nextStart = 0;
      this.activeSources = 0;
    }
    ensureCtx() {
      if (this.ctx) return;
      const Ctx = window.AudioContext || window.webkitAudioContext;
      this.ctx = new Ctx({ sampleRate: this.sampleRate });
      this.nextStart = this.ctx.currentTime;
    }
    enqueuePcm16(int16) {
      this.ensureCtx();
      const buf = this.ctx.createBuffer(1, int16.length, this.sampleRate);
      const channel = buf.getChannelData(0);
      for (let i = 0; i < int16.length; i++) channel[i] = int16[i] / 0x8000;

      const src = this.ctx.createBufferSource();
      src.buffer = buf;
      src.connect(this.ctx.destination);

      const startAt = Math.max(this.ctx.currentTime, this.nextStart);
      src.start(startAt);
      this.nextStart = startAt + buf.duration;

      this.activeSources++;
      setState("speaking", "Gemini is replying");
      // Pause Silero VAD while Gemini is speaking. Without this, the
      // assistant's audio output through speakers is picked up by the
      // mic (Chrome's WebRTC echo canceller cannot see audio produced
      // via a manual AudioContext, so echoCancellation does not apply).
      // The result is VAD trapped in "speech" state — never fires
      // onSpeechEnd, never sends end_of_turn, second user turn lost
      // until stop/start cycle. Trade-off: loses barge-in (acceptable
      // — barge-in is already broken via this echo path).
      try { if (window.__micVad) window.__micVad.pause(); } catch (_) {}
      src.onended = () => {
        this.activeSources--;
        if (this.activeSources <= 0) {
          this.activeSources = 0;
          setState("listening", "listening for speech");
          // Resume mic with a 250ms grace period for the echo tail to
          // settle. Without the delay, VAD picks up the last fragment
          // of Gemini's audio and fires onSpeechStart immediately.
          try {
            if (window.__micVad) {
              setTimeout(() => { try { window.__micVad?.start(); } catch (_) {} }, 250);
            }
          } catch (_) {}
        }
      };
    }
    async stop() {
      if (this.ctx) {
        try { await this.ctx.close(); } catch (_) { /* ignore */ }
        this.ctx = null;
      }
      this.nextStart = 0;
      this.activeSources = 0;
    }
  }

  // ── Inbound bridge frames ─────────────────────────────────────────────────
  async function onWsMessage(ev) {
    if (ev.data instanceof Blob) {
      // Binary frame: Gemini Live PCM16 audio chunk for playback.
      const ab = await ev.data.arrayBuffer();
      const int16 = new Int16Array(ab);
      player.enqueuePcm16(int16);
      return;
    }
    if (ev.data instanceof ArrayBuffer) {
      const int16 = new Int16Array(ev.data);
      player.enqueuePcm16(int16);
      return;
    }
    let msg;
    try {
      msg = JSON.parse(ev.data);
    } catch (_) {
      return;
    }
    switch (msg.type) {
      case "ready":
        // Bridge has opened the Gemini Live session and is ready to
        // accept audio frames. Mic is not yet started — that happens
        // in startSession() once the user has granted permission.
        if (msg.conversation_id) {
          convIdEl.textContent = msg.conversation_id;
        }
        setState("listening", "listening for speech");
        break;
      case "think_start":
        setState("thinking", msg.query ? "thinking: " + msg.query : "thinking…");
        transcriptLine("[think] " + (msg.query || ""), "think");
        break;
      case "think_end":
        // The "speaking" flip will happen when Gemini begins emitting
        // audio chunks; until then, leave the user in "thinking".
        break;
      case "transcript":
        if (msg.text) transcriptLine(msg.text);
        break;
      case "error":
        transcriptLine("[error] " + (msg.message || "unknown"), "error");
        setState("error", msg.message || "bridge error");
        break;
      default:
        // Forward-compatible: ignore unknown frame types.
        break;
    }
  }

  // ── VAD wiring ────────────────────────────────────────────────────────────
  // @ricky0123/vad-web (UMD bundle exposes `vad`) loads Silero from a
  // bundled WASM/onnx blob set; baseAssetPath tells it where to fetch
  // those siblings. Because we're loading the bundle from jsdelivr the
  // default base path resolves correctly without override; the explicit
  // setting documents the contract for an operator who chooses to
  // self-host the assets.
  async function startMicVad() {
    if (typeof vad === "undefined" || !vad.MicVAD) {
      throw new Error("Silero VAD library failed to load");
    }
    const baseAssetPath =
      "https://cdn.jsdelivr.net/npm/@ricky0123/vad-web@0.0.19/dist/";
    const onnxRuntimeBasePath =
      "https://cdn.jsdelivr.net/npm/onnxruntime-web@1.14.0/dist/";

    micVad = window.__micVad = await vad.MicVAD.new({
      // Asset paths for the WASM worker + Silero model (.onnx). Mirrors
      // the CDN URLs of the script tags in index.html so the runtime
      // pulls everything from the same pinned version set.
      baseAssetPath,
      onnxWASMBasePath: onnxRuntimeBasePath,
      modelURL: baseAssetPath + "silero_vad.onnx",
      workletURL: baseAssetPath + "vad.worklet.bundle.min.js",

      // VAD callbacks. The library hands us speech segments at
      // INPUT_SAMPLE_RATE so we can forward straight to the bridge
      // without resampling.
      onSpeechStart: () => {
        setState("speech", "speech detected");
      },
      onVADMisfire: () => {
        // Speech start without a confirmed end — usually a cough. Drop
        // the in-progress flag and go back to listening.
        if (body.dataset.state === "speech") {
          setState("listening", "listening for speech");
        }
      },
      onSpeechEnd: (audio) => {
        // `audio` is a Float32Array at INPUT_SAMPLE_RATE covering the
        // detected speech segment. Slice it into ~50ms PCM16 frames so
        // the bridge sees a stream rather than one giant blob, then
        // mark end_of_turn so Gemini Live commits the turn.
        const pcm = floatToPcm16(audio);
        for (let off = 0; off < pcm.length; off += FRAME_SAMPLES) {
          const slice = pcm.subarray(off, Math.min(off + FRAME_SAMPLES, pcm.length));
          // Copy into a standalone ArrayBuffer; subarray shares the
          // backing buffer and WebSocket.send keeps a reference, which
          // can break the next iteration's slice on some browsers.
          const out = new Int16Array(slice.length);
          out.set(slice);
          sendBinary(out.buffer);
        }
        send({ type: "end_of_turn" });
        // Stay in "listening" — the bridge will flip us to "thinking"
        // (when the model decides to call `think`) or "speaking" (when
        // audio chunks start arriving).
        if (body.dataset.state === "speech") {
          setState("listening", "listening for speech");
        }
      },
    });
    await micVad.start();
  }

  async function stopMicVad() {
    if (micVad) {
      try { micVad.pause(); } catch (_) { /* ignore */ }
      try { await micVad.destroy(); } catch (_) { /* ignore */ }
      micVad = null;
      window.__micVad = null;
    }
  }

  // ── Session lifecycle ─────────────────────────────────────────────────────
  async function startSession() {
    startBtn.disabled = true;
    setState("connecting", "opening WebSocket");

    player = new PcmPlayer(OUTPUT_SAMPLE_RATE);

    try {
      ws = new WebSocket(wsUrl(), "voice-stream-v1");
      ws.binaryType = "arraybuffer";
    } catch (err) {
      setState("error", "WebSocket open failed: " + err.message);
      startBtn.disabled = false;
      return;
    }

    ws.onopen = () => {
      // Hand the bridge the conversation id so claude-session plumbing
      // can derive a stable per-conv claude session (see bridge.py
      // _derive_claude_session_id).
      send({ type: "hello", conversation_id: convId });
      setState("connecting", "starting microphone");

      // VAD start needs user-gesture audio context — startBtn click is
      // the gesture. Catch permission errors and surface them.
      startMicVad()
        .then(() => {
          // setState to "listening" already happened in onWsMessage when
          // the bridge sent {type:"ready"}. If the bridge never replies
          // (slow Gemini handshake) we still want the user to know the
          // mic is live, so flip to listening here as a fallback.
          if (body.dataset.state === "connecting") {
            setState("listening", "listening for speech");
          }
          stopBtn.disabled = false;
        })
        .catch((err) => {
          setState("error", "microphone error: " + (err.message || err));
          stopSession();
        });
    };

    ws.onmessage = onWsMessage;

    ws.onerror = () => {
      setState("error", "WebSocket error");
    };

    ws.onclose = (ev) => {
      // 4401 = forward_auth rejected (session cookie expired). Send the
      // user back to /chat/login so they re-authenticate via OAuth.
      if (ev.code === 4401) {
        setState("error", "session expired — redirecting to login");
        window.location.href = "/chat/login?next=" +
          encodeURIComponent(window.location.pathname + window.location.search);
        return;
      }
      if (body.dataset.state !== "error") {
        setState("idle", "disconnected");
      }
      stopBtn.disabled = true;
      startBtn.disabled = false;
      stopMicVad();
    };
  }

  async function stopSession() {
    stopBtn.disabled = true;
    await stopMicVad();
    if (player) {
      await player.stop();
      player = null;
    }
    if (ws) {
      try { ws.close(1000, "user stopped"); } catch (_) { /* ignore */ }
      ws = null;
    }
    setState("idle", "click start to enable the microphone");
    startBtn.disabled = false;
  }

  // ── Wire buttons ──────────────────────────────────────────────────────────
  startBtn.addEventListener("click", () => {
    startSession().catch((err) => {
      setState("error", "start failed: " + (err.message || err));
      startBtn.disabled = false;
    });
  });
  stopBtn.addEventListener("click", () => {
    stopSession();
  });

  // Best-effort cleanup so a refresh doesn't leave the mic indicator on.
  window.addEventListener("beforeunload", () => {
    try { stopMicVad(); } catch (_) { /* ignore */ }
    if (ws) { try { ws.close(); } catch (_) { /* ignore */ } }
  });
})();
