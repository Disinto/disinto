#!/usr/bin/env bash
set -euo pipefail
source tests/lib/acceptance-helpers.sh

# Static check: voice-client.js has the pause/resume calls
js="docker/voice/ui/static/voice-client.js"
grep -q "window.__micVad" "$js" || { echo "FAIL: window.__micVad not exposed"; exit 1; }
grep -q "window.__micVad.pause" "$js" || { echo "FAIL: pause-on-speaking not added"; exit 1; }
grep -q "window.__micVad?.start" "$js" || { echo "FAIL: resume-after-speaking not added"; exit 1; }

# Static check: pause is invoked from PcmPlayer (ie inside the speaking-state block)
awk '/setState\("speaking"/,/setState\("listening"/' "$js" | grep -q 'pause()' \
  || { echo "FAIL: pause() not inside the speaking-state block"; exit 1; }

# Live check: image is rebuilt with the fix
ALLOC=$(nomad job allocs -t '{{range .}}{{if eq .ClientStatus "running"}}{{.ID}}{{end}}{{end}}' edge | head -c 36)
in_container="$(nomad alloc exec -task caddy "$ALLOC" \
  grep -c 'window.__micVad' /var/voice/ui/static/voice-client.js)"
[ "$in_container" -ge "3" ] \
  || { echo "FAIL: shipped image lacks the patch (matches=$in_container)"; exit 1; }

# Browser-side check is left to manual + #860 reproduction:
#   1. Open https://self.disinto.ai/voice/, click Start.
#   2. Speak: "What's the state of the tracker?"
#   3. Listen to the reply.
#   4. Speak: "How many opus agents are running?"
#   5. Verify the assistant replies without needing to click stop/start.

echo PASS
