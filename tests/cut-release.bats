#!/usr/bin/env bats
# =============================================================================
# tests/cut-release.bats — tools/cut-release.sh (#1228)
#
# Covers: pre-flight fail-fast, dry-run (plan, no mutation), bump without
# --yes (local commit only), full --yes runs against a local stub GHCR
# registry (manifest 200 / 404-then-200 / timeout / visibility denial),
# and cr_vercmp prerelease suffix ordering.
#
# CI image (alpine) has python3 for the stub; no other dependencies.
# =============================================================================

TOOL="$BATS_TEST_DIRNAME/../tools/cut-release.sh"

setup() {
  REPO="$BATS_TEST_TMPDIR/repo"
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  mkdir -p "$REPO"
  cd "$REPO"
  git init -q -b main .
  git config user.email release@test.local
  git config user.name "Release Test"
  git config commit.gpgsign false
  printf '0.4.0\n' > VERSION
  git add VERSION
  git commit -qm "initial (VERSION 0.4.0)"
  git init -q --bare "$ORIGIN"
  git remote add origin "$ORIGIN"
  git push -q origin main
  STUB_PID=""
}

teardown() {
  if [ -n "$STUB_PID" ]; then
    kill "$STUB_PID" 2>/dev/null || true
  fi
  cd /
}

# _start_stub [ENV=VAL ...] — start a stub GHCR registry on 127.0.0.1 and
# export GHCR_REGISTRY. The stub answers:
#   GET /token?scope=repository:<owner>/<img>:pull → 200 {"token":...}
#       (401 when <img> is listed in DENIED_IMAGES)
#   GET /v2/<owner>/<img>/manifests/<tag> → 200 after PUBLISH_AFTER requests,
#       404 before (default PUBLISH_AFTER=0 = always published).
# PUBLISH_AFTER/COUNTER_FILE/DENIED_IMAGES are env vars for the stub process.
_start_stub() {
  local extra=("$@")
  local port
  port=$(( 10000 + ( ( $$ + RANDOM ) % 40000 ) ))
  local stub_py="$BATS_TEST_TMPDIR/stub-registry.py"
  cat > "$stub_py" <<'PYEOF'
import http.server
import json
import os
import re
import sys

PUBLISH_AFTER = int(os.environ.get("PUBLISH_AFTER", "0"))
DENIED = [i for i in os.environ.get("DENIED_IMAGES", "").split(",") if i]
COUNTER_FILE = os.environ["COUNTER_FILE"]
PORT = int(sys.argv[1])


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _reply(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path, _, query = self.path.partition("?")
        if path == "/token":
            m = re.search(r"scope=repository:([^/]+)/([^:]+):pull", query)
            if m and m.group(2) in DENIED:
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Bearer realm="stub"')
                self.end_headers()
                return
            self._reply(200, {"token": "stub-token", "expires_in": 300})
            return
        m = re.match(r"^/v2/[^/]+/[^/]+/manifests/([^/]+)$", path)
        if m:
            with open(COUNTER_FILE, "a") as f:
                f.write("1\n")
            with open(COUNTER_FILE) as f:
                n = sum(1 for line in f if line.strip())
            if n > PUBLISH_AFTER:
                self._reply(200, {
                    "schemaVersion": 2,
                    "mediaType": "application/vnd.oci.image.index.v1+json",
                    "manifests": []})
            else:
                self._reply(404, {"errors": [{"code": "MANIFEST_UNKNOWN",
                                              "message": "manifest unknown"}]})
            return
        self._reply(404, {"errors": [{"code": "NOT_FOUND"}]})


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
PYEOF
  export COUNTER_FILE="$BATS_TEST_TMPDIR/manifest-count"
  : > "$COUNTER_FILE"
  env "${extra[@]}" python3 "$stub_py" "$port" >"$BATS_TEST_TMPDIR/stub.log" 2>&1 &
  STUB_PID=$!
  local tries=0
  while [ "$tries" -lt 50 ]; do
    if curl -s -o /dev/null "http://127.0.0.1:${port}/"; then
      break
    fi
    sleep 0.1
    tries=$((tries + 1))
  done
  export GHCR_REGISTRY="http://127.0.0.1:${port}"
}

# ── Help / usage ─────────────────────────────────────────────────────────────

@test "help exits 0 and documents the contract" {
  run bash "$TOOL" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--dry-run"* ]]
  [[ "$output" == *"--yes"* ]]
  [[ "$output" == *"--main"* ]]
  [[ "$output" == *"--skip-wait"* ]]
  [[ "$output" == *"v2/"* ]]
}

@test "unknown flag exits 2" {
  run bash "$TOOL" --bogus
  [ "$status" -eq 2 ]
}

# ── Stage 1: pre-flight fail-fast ────────────────────────────────────────────

@test "pre-flight: dirty tree refuses" {
  echo junk >> VERSION
  run bash "$TOOL" 0.4.1
  [ "$status" -ne 0 ]
  [[ "$output" == *"dirty"* ]]
  [ "$(git branch --show-current)" = "main" ]
}

@test "pre-flight: wrong branch refuses" {
  git checkout -qb feature
  run bash "$TOOL" 0.4.1
  [ "$status" -ne 0 ]
  [[ "$output" == *"not on 'main'"* ]]
}

@test "pre-flight: same version refuses" {
  run bash "$TOOL" 0.4.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"already"* ]]
}

@test "pre-flight: older version refuses" {
  run bash "$TOOL" 0.3.9
  [ "$status" -ne 0 ]
  [[ "$output" == *"newer than target"* ]]
}

@test "pre-flight: unpushed commits on main refuse" {
  git commit -q --allow-empty -m "wip"
  run bash "$TOOL" 0.4.1
  [ "$status" -ne 0 ]
  [[ "$output" == *"unpushed"* ]]
}

@test "pre-flight: invalid version format refuses" {
  run bash "$TOOL" not-a-version
  [ "$status" -ne 0 ]
  [[ "$output" == *"not semver"* ]]
}

# ── Prerelease ordering (cr_vercmp) ──────────────────────────────────────────

test_cr_vercmp() {
  source "$TOOL"
  run cr_vercmp "$1" "$2"
  [ "$status" -eq 0 ]
  [ "$output" = "$3" ]
}

@test "vercmp: prerelease suffixes are ordered, not equal" {
  test_cr_vercmp 0.5.0-rc.1 0.5.0-rc.2 -1
  test_cr_vercmp 0.5.0-rc.2 0.5.0-rc.1 1
  test_cr_vercmp 0.5.0-rc.1 0.5.0-rc.1 0
  test_cr_vercmp 0.5.0-rc.9 0.5.0-rc.10 -1
}

@test "vercmp: prerelease field rules (alphanumeric, prefix, numeric < alpha)" {
  test_cr_vercmp 0.5.0-alpha 0.5.0-beta -1
  test_cr_vercmp 0.5.0-alpha 0.5.0-alpha.1 -1
  test_cr_vercmp 0.5.0-alpha.1 0.5.0-alpha 1
  test_cr_vercmp 0.5.0-1 0.5.0-alpha -1
  test_cr_vercmp 0.5.0-rc.1 0.5.0 -1
  test_cr_vercmp 0.5.0 0.5.0-rc.1 1
}

@test "pre-flight: cutting 0.5.0-rc.2 from VERSION 0.5.0-rc.1 is allowed" {
  printf '0.5.0-rc.1\n' > VERSION
  git commit -qam "release: v0.5.0-rc.1"
  git push -q origin main
  run bash "$TOOL" 0.5.0-rc.2
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = "release/v0.5.0-rc.2" ]
  [ "$(cat VERSION)" = "0.5.0-rc.2" ]
  [ -z "$(git tag -l v0.5.0-rc.2)" ]
}

# ── Dry-run: plan, no mutation ───────────────────────────────────────────────

@test "dry-run prints the full plan and mutates nothing" {
  local before_head before_version
  before_head="$(git rev-parse HEAD)"
  before_version="$(cat VERSION)"
  run bash "$TOOL" 0.5.0 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Stage 2"* ]]
  [[ "$output" == *"Stage 3"* ]]
  [[ "$output" == *"Stage 4"* ]]
  [[ "$output" == *"Stage 5"* ]]
  [[ "$output" == *"release/v0.5.0"* ]]
  [[ "$output" == *"DRY RUN"* ]]
  [ "$(git rev-parse HEAD)" = "$before_head" ]
  [ "$(cat VERSION)" = "$before_version" ]
  [ -z "$(git status --porcelain)" ]
  [ -z "$(git tag -l v0.5.0)" ]
  [ -z "$(git branch --list 'release/*')" ]
}

@test "dry-run reports issues (lower version, detached HEAD) and still exits 0" {
  git checkout -q --detach HEAD
  run bash "$TOOL" 0.0.0-test --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"pre-flight ISSUE"* ]]
  [[ "$output" == *"DRY RUN"* ]]
  [ -z "$(git status --porcelain)" ]
  [ -z "$(git tag -l v0.0.0-test)" ]
}

# ── Stage 2: bump without --yes ──────────────────────────────────────────────

@test "without --yes: bump is committed locally, nothing tagged or pushed" {
  run bash "$TOOL" 0.5.0
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = "release/v0.5.0" ]
  [ "$(cat VERSION)" = "0.5.0" ]
  [ "$(git log -1 --format=%s)" = "release: v0.5.0" ]
  [ -z "$(git tag -l v0.5.0)" ]
  [ "$(git --git-dir="$ORIGIN" show main:VERSION)" = "0.4.0" ]
  [[ "$output" == *"gated behind --yes"* ]]
}

# ── Resume: the two-step flow (stage 2 → re-run with --yes) ─────────────────

@test "resume: the --yes re-run from release/v<version> completes the cut" {
  _start_stub
  run bash "$TOOL" 0.5.0
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = "release/v0.5.0" ]
  # the exact re-run the STOP message prescribes
  run bash "$TOOL" 0.5.0 --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"resuming"* ]]
  [[ "$output" == *"[2/6] PASS"* ]]
  [[ "$output" == *"[3/6] PASS"* ]]
  [[ "$output" == *"[4/6] PASS"* ]]
  [[ "$output" == *"[5/6] PASS"* ]]
  [[ "$output" == *"DONE"* ]]
  [ -n "$(git tag -l v0.5.0)" ]
  [ "$(git --git-dir="$ORIGIN" tag -l v0.5.0)" = "v0.5.0" ]
  [ "$(git --git-dir="$ORIGIN" show release/v0.5.0:VERSION)" = "0.5.0" ]
  # no second bump commit: still exactly one commit ahead of origin/main
  [ "$(git rev-list --count origin/main..release/v0.5.0)" = "1" ]
}

@test "resume: --yes re-run from main picks up the existing release branch" {
  _start_stub
  run bash "$TOOL" 0.5.0
  [ "$status" -eq 0 ]
  git checkout -q main
  run bash "$TOOL" 0.5.0 --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"resuming"* ]]
  [[ "$output" == *"[3/6] PASS"* ]]
  [[ "$output" == *"DONE"* ]]
  [ "$(git branch --show-current)" = "release/v0.5.0" ]
  [ -n "$(git tag -l v0.5.0)" ]
}

@test "resume: a different version on release/v<version> refuses" {
  run bash "$TOOL" 0.5.0
  [ "$status" -eq 0 ]
  run bash "$TOOL" 0.5.1
  [ "$status" -ne 0 ]
  [[ "$output" == *"not on 'main' or 'release/v0.5.1'"* ]]
  [ "$(git branch --show-current)" = "release/v0.5.0" ]
  [ -z "$(git branch --list release/v0.5.1)" ]
  [ "$(cat VERSION)" = "0.5.0" ]
}

@test "resume: --main two-step flow completes from the bump on main" {
  _start_stub
  run bash "$TOOL" 0.6.0 --main
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = "main" ]
  [ "$(cat VERSION)" = "0.6.0" ]
  # the unpushed bump commit is the expected resume state, not an issue
  run bash "$TOOL" 0.6.0 --yes --main
  [ "$status" -eq 0 ]
  [[ "$output" == *"resuming"* ]]
  [[ "$output" == *"[3/6] PASS"* ]]
  [[ "$output" == *"DONE"* ]]
  [ "$(git --git-dir="$ORIGIN" tag -l v0.6.0)" = "v0.6.0" ]
  [ "$(git --git-dir="$ORIGIN" show main:VERSION)" = "0.6.0" ]
}

@test "dry-run on release/v<version> shows the resume plan and mutates nothing" {
  run bash "$TOOL" 0.5.0
  [ "$status" -eq 0 ]
  local head
  head="$(git rev-parse HEAD)"
  run bash "$TOOL" 0.5.0 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"resuming"* ]]
  [[ "$output" == *"no-op"* ]]
  [[ "$output" == *"DRY RUN"* ]]
  [ "$(git rev-parse HEAD)" = "$head" ]
  [ -z "$(git status --porcelain)" ]
}

# ── Full runs against the stub registry ──────────────────────────────────────

@test "--yes: bump, tag, push, images publish, visibility passes" {
  _start_stub
  run bash "$TOOL" 0.5.0 --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"[2/6] PASS"* ]]
  [[ "$output" == *"[3/6] PASS"* ]]
  [[ "$output" == *"[4/6] PASS"* ]]
  [[ "$output" == *"[5/6] PASS"* ]]
  [[ "$output" == *"DONE"* ]]
  [ -n "$(git tag -l v0.5.0)" ]
  [ "$(git --git-dir="$ORIGIN" tag -l v0.5.0)" = "v0.5.0" ]
  [ "$(git --git-dir="$ORIGIN" show release/v0.5.0:VERSION)" = "0.5.0" ]
}

@test "--yes --main: bump and tag land on main" {
  _start_stub
  run bash "$TOOL" 0.6.0 --yes --main
  [ "$status" -eq 0 ]
  [ "$(git branch --show-current)" = "main" ]
  [ "$(git --git-dir="$ORIGIN" show main:VERSION)" = "0.6.0" ]
  [ "$(git --git-dir="$ORIGIN" tag -l v0.6.0)" = "v0.6.0" ]
}

@test "wait: 404s past the timeout fail with the pipeline hint" {
  _start_stub PUBLISH_AFTER=999999
  run env WAIT_TIMEOUT_SECS=2 POLL_INTERVAL_SECS=0 bash "$TOOL" 0.5.0 --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"[4/6] FAIL"* ]]
  [[ "$output" == *"Woodpecker"* ]]
  # stage 3 (tag + push) ran before the wait timed out
  [ "$(git --git-dir="$ORIGIN" tag -l v0.5.0)" = "v0.5.0" ]
}

@test "wait: images published after 404s pass on re-poll" {
  _start_stub PUBLISH_AFTER=2
  run env WAIT_TIMEOUT_SECS=60 POLL_INTERVAL_SECS=1 bash "$TOOL" 0.5.0 --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"[4/6] PASS"* ]]
}

@test "visibility: denied package fails with the remediation" {
  _start_stub DENIED_IMAGES=reproduce
  run bash "$TOOL" 0.5.0 --yes --skip-wait
  [ "$status" -ne 0 ]
  [[ "$output" == *"[5/6] FAIL"* ]]
  [[ "$output" == *"reproduce"* ]]
  [[ "$output" == *"Visibility"* ]]
  [[ "$output" == *"Public"* ]]
  [[ "$output" == *"[4/6] SKIP"* ]]
}

@test "skip-wait still checks visibility" {
  _start_stub DENIED_IMAGES=edge
  run bash "$TOOL" 0.5.0 --yes --skip-wait
  [ "$status" -ne 0 ]
  [[ "$output" == *"edge"* ]]
}

@test "visibility: unreachable registry fails as a network error, not a visibility verdict" {
  # port 1 on loopback is closed: curl reports code 000 → rc=2 path
  run env GHCR_REGISTRY="http://127.0.0.1:1" bash "$TOOL" 0.5.0 --yes --skip-wait
  [ "$status" -ne 0 ]
  [[ "$output" == *"[5/6] FAIL"* ]]
  [[ "$output" == *"unreachable"* ]]
  [[ "$output" == *"network"* ]]
  # the operator must not be sent to fix package visibility for an outage
  [[ "$output" != *"Visibility"* ]]
}
