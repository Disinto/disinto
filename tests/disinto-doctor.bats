#!/usr/bin/env bats
# =============================================================================
# tests/disinto-doctor.bats — `disinto doctor` factory drift checks (#1237).
#
# The chat drift check compares the live standalone `chat` Nomad job against
# the state init generates from this repo (no standalone chat jobspec by
# design — lib/generators.sh is the source of truth, no in-repo snapshot).
#
# Hermetic: a fake `nomad` binary (stub-bin) on PATH answers the three calls
# doctor makes (`node status`, `job inspect -json chat`, `job inspect chat`).
# Behaviour switches on env vars:
#   FAKE_NOMAD_API_DOWN=1      → `node status` fails (connection refused)
#   FAKE_NOMAD_CHAT_PRESENT=1  → the `chat` job exists (JSON + HCL below)
#   FAKE_NOMAD_HCL_FILE        → HCL returned by `job inspect chat`
#
# Exit-code contract under test: 0 = OK (in sync), 1 = DRIFT, 2 = uncheckable.
# =============================================================================

setup_file() {
  export DISINTO_ROOT
  DISINTO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export DISINTO_BIN="${DISINTO_ROOT}/bin/disinto"
  [ -x "$DISINTO_BIN" ] || {
    echo "disinto binary not executable: $DISINTO_BIN" >&2
    return 1
  }

  local stub_dir="${BATS_FILE_TMPDIR}/stub-bin"
  mkdir -p "$stub_dir"

  cat > "${stub_dir}/nomad" <<'STUB'
#!/usr/bin/env bash
# Fake `nomad` for tests/disinto-doctor.bats — see the file header for the
# FAKE_NOMAD_* env-var contract.
set -euo pipefail

if [ "${1:-}" = "node" ] && [ "${2:-}" = "status" ]; then
  if [ "${FAKE_NOMAD_API_DOWN:-0}" = "1" ]; then
    echo 'Error: Get "http://127.0.0.1:4646/v1/nodes?prefix=": dial tcp 127.0.0.1:4646: connect: connection refused' >&2
    exit 1
  fi
  cat <<'EOF'
ID    Datacenter  Status  Eligibility  StatusDescription
c0ffee dc1        ready   eligible     4/4 queued jobs fit
EOF
  exit 0
fi

if [ "${1:-}" = "job" ] && [ "${2:-}" = "inspect" ]; then
  if [ "${FAKE_NOMAD_CHAT_PRESENT:-0}" != "1" ]; then
    echo 'Error: No job with ID prefix "chat" found' >&2
    exit 1
  fi
  if [ "${3:-}" = "-json" ]; then
    cat <<'EOF'
{
  "ID": "chat",
  "Status": "running",
  "ModifiedAt": 1757200000,
  "Groups": [ { "Name": "chat", "Count": 1 } ]
}
EOF
    exit 0
  fi
  cat "$FAKE_NOMAD_HCL_FILE"
  exit 0
fi

echo "fake nomad: unsupported invocation: $*" >&2
exit 2
STUB
  chmod +x "${stub_dir}/nomad"
  export DISINTO_DOCTOR_STUB_DIR="$stub_dir"

  # Reference HCL for a legacy pre-#1158 standalone `chat` job — what a
  # pre-#1158 live box would register (and what doctor should surface).
  export DISINTO_DOCTOR_HCL_FILE="${BATS_FILE_TMPDIR}/chat-live.hcl"
  cat > "$DISINTO_DOCTOR_HCL_FILE" <<'HCL'
job "chat" {
  type        = "service"
  datacenters = ["dc1"]

  group "chat" {
    count = 1

    task "chat" {
      driver = "docker"

      config {
        image = "disinto/chat:local"
        ports = { "http" = "8080" }
      }
    }
  }
}
HCL
}

# ── no chat job → OK (the generated state) ─────────────────────────────────

@test "doctor: no live chat job is OK — matches the generated state (exit 0)" {
  run env PATH="${DISINTO_DOCTOR_STUB_DIR}:${PATH}" "$DISINTO_BIN" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK — matches the generated state"* ]]
  [[ "$output" == *"no in-repo snapshot"* ]]
  [[ "$output" == *"no \`chat\` job registered on the cluster"* ]]
}

# ── live chat job, no snapshot → DRIFT ──────────────────────────────────────

@test "doctor: live legacy chat job with no in-repo snapshot is DRIFT (exit 1)" {
  run env PATH="${DISINTO_DOCTOR_STUB_DIR}:${PATH}" \
    FAKE_NOMAD_CHAT_PRESENT=1 FAKE_NOMAD_HCL_FILE="$DISINTO_DOCTOR_HCL_FILE" \
    "$DISINTO_BIN" doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT — legacy box drift from a pre-#1158 init (not a release gap)"* ]]
  # The live spec is summarised (status / count) and printed verbatim…
  [[ "$output" == *"status=running"* ]]
  [[ "$output" == *"count=1"* ]]
  [[ "$output" == *"disinto/chat:local"* ]]
  # …with an explicit diff statement and the remediation.
  [[ "$output" == *"cannot be reproduced from git"* ]]
  [[ "$output" == *"nomad job stop chat"* ]]
}

# ── uncheckable paths → exit 2 ──────────────────────────────────────────────

@test "doctor: no nomad CLI on PATH is uncheckable (exit 2, SKIP)" {
  run env PATH="${DISINTO_DOCTOR_STUB_DIR}:${PATH}" \
    DISINTO_DOCTOR_NOMAD=/nonexistent-nomad-binary "$DISINTO_BIN" doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"SKIP: no"* ]]
  [[ "$output" == *"cannot query the Nomad API"* ]]
}

@test "doctor: unreachable Nomad API is uncheckable (exit 2), not a drift verdict" {
  run env PATH="${DISINTO_DOCTOR_STUB_DIR}:${PATH}" \
    FAKE_NOMAD_API_DOWN=1 "$DISINTO_BIN" doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot reach the Nomad API"* ]]
  [[ "$output" == *"not a drift verdict"* ]]
}

# ── in-repo snapshot branch (fakeroot; the repo itself holds none) ──────────

# build_fakeroot — a minimal factory tree (bin/disinto + lib/ [+ VERSION]) so
# bin/disinto's env.sh resolves FACTORY_ROOT to the fakeroot; tests then drop
# a nomad/jobs/chat.hcl snapshot in there to exercise the snapshot branch.
build_fakeroot() {
  local fakeroot="$1"
  mkdir -p "${fakeroot}/bin" "${fakeroot}/nomad/jobs"
  cp -R "${DISINTO_ROOT}/lib" "${fakeroot}/lib"
  cp "$DISINTO_BIN" "${fakeroot}/bin/disinto"
  [ -f "${DISINTO_ROOT}/VERSION" ] && cp "${DISINTO_ROOT}/VERSION" "${fakeroot}/VERSION"
}

@test "doctor: live chat job matching the in-repo snapshot is OK (exit 0)" {
  local fakeroot="${BATS_TEST_TMPDIR}/fakeroot"
  build_fakeroot "$fakeroot"
  cp "$DISINTO_DOCTOR_HCL_FILE" "${fakeroot}/nomad/jobs/chat.hcl"

  run env PATH="${DISINTO_DOCTOR_STUB_DIR}:${PATH}" \
    FAKE_NOMAD_CHAT_PRESENT=1 FAKE_NOMAD_HCL_FILE="$DISINTO_DOCTOR_HCL_FILE" \
    "${fakeroot}/bin/disinto" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK — live spec matches the in-repo snapshot"* ]]
}

@test "doctor: live chat job differing from the in-repo snapshot is DRIFT (exit 1)" {
  local fakeroot="${BATS_TEST_TMPDIR}/fakeroot"
  build_fakeroot "$fakeroot"
  # Snapshot drifted from the live spec (different image tag).
  sed 's/disinto\/chat:local/disinto\/chat:legacy/' \
    "$DISINTO_DOCTOR_HCL_FILE" > "${fakeroot}/nomad/jobs/chat.hcl"

  run env PATH="${DISINTO_DOCTOR_STUB_DIR}:${PATH}" \
    FAKE_NOMAD_CHAT_PRESENT=1 FAKE_NOMAD_HCL_FILE="$DISINTO_DOCTOR_HCL_FILE" \
    "${fakeroot}/bin/disinto" doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT — live spec differs from the in-repo snapshot"* ]]
  # The diff itself is printed, both sides visible.
  [[ "$output" == *"disinto/chat:local"* ]]
  [[ "$output" == *"disinto/chat:legacy"* ]]
}
