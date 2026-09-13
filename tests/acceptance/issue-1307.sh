#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1307.sh
#
# Issue #1307: vault-runner honors action image and artifacts volume.
# The dispatcher must forward the optional action-TOML `image` field and
# `artifacts` globs to the runner: the Nomad backend passes them as dispatch
# meta (image + artifacts_csv) against a parameterized vault-runner jobspec
# whose task image is ${NOMAD_META_image} and which mounts a WRITEABLE
# host-volume artifacts dir at /artifacts; the Docker backend runs the
# action's image (default disinto/agents:latest) with a per-action bind
# under /artifacts. An action without `image` must still run the default
# agents image. Unknown action fields must still fail validation.
#
# Verifies (all checks read-only — temp TOMLs in mktemp dirs only, no forge,
# no real nomad — the dispatcher function is extracted and executed in a
# stubbed subshell):
#   1. vault-runner.hcl: task image is ${NOMAD_META_image}; meta_required
#      includes image and artifacts_csv; writeable /artifacts volume_mount
#      (host volume "vault-artifacts", no read_only); ARTIFACTS_DIR /
#      ARTIFACTS_GLOB env.
#   2. host_volume "vault-artifacts" declared in nomad/client.hcl and the
#      dir listed in HOST_VOLUME_DIRS in lib/init/nomad/cluster-up.sh.
#   3. Dry-run proof: _launch_runner_nomad (nomad stubbed) dispatches
#      image=<action image> when set, image=disinto/agents:local when the
#      action omits it; artifacts_csv is always passed.
#   4. _launch_runner_docker uses the action image with a
#      disinto/agents:latest default and mounts /artifacts.
#   5. Regression: a TOML with an unknown field still fails validation with
#      an 'Unknown fields' error.
#   6. SCHEMA.md documents the dispatch behaviour (image default, /artifacts,
#      ARTIFACTS_GLOB).
#
# Run via: tools/run-acceptance.sh 1307
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep awk mktemp jq

# lib/env.sh (sourced via vault-env.sh by validate.sh) requires USER/HOME
export USER="${USER:-$(id -un)}"
export HOME="${HOME:-/root}"

HCL="$REPO_ROOT/nomad/jobs/vault-runner.hcl"
DISPATCHER="$REPO_ROOT/docker/edge/dispatcher.sh"
ac_assert_file "$HCL" "nomad/jobs/vault-runner.hcl is missing"
ac_assert_file "$DISPATCHER" "docker/edge/dispatcher.sh is missing"

# ── 1. vault-runner.hcl honors the image meta and mounts /artifacts ────────
grep -qE 'image[[:space:]]*=[[:space:]]*"\$\{NOMAD_META_image\}"' "$HCL" \
  || ac_fail "vault-runner.hcl: task image is not \${NOMAD_META_image} (still hardcoded?)"

grep -qE 'meta_required[[:space:]]*=[[:space:]]*\[[^]]*"image"[^]]*\]' "$HCL" \
  || ac_fail "vault-runner.hcl: meta_required does not include \"image\""
grep -qE 'meta_required[[:space:]]*=[[:space:]]*\[[^]]*"artifacts_csv"[^]]*\]' "$HCL" \
  || ac_fail "vault-runner.hcl: meta_required does not include \"artifacts_csv\""

# The volume_mount block whose destination is /artifacts: must reference the
# artifacts host volume and must NOT be read-only.
ART_VM=$(awk '
  /volume_mount[[:space:]]*\{/ { buf = $0; inblk = 1; next }
  inblk {
    buf = buf "\n" $0
    if ($0 ~ /^[[:space:]]*}/) {
      if (index(buf, "/artifacts")) print buf
      inblk = 0
    }
  }
' "$HCL")
[ -n "$ART_VM" ] \
  || ac_fail "vault-runner.hcl: no volume_mount block with destination /artifacts"
grep -qE 'volume[[:space:]]*=[[:space:]]*"artifacts"' <<<"$ART_VM" \
  || ac_fail "vault-runner.hcl: /artifacts volume_mount does not reference volume \"artifacts\""
if grep -q 'read_only' <<<"$ART_VM"; then
  ac_fail "vault-runner.hcl: /artifacts volume_mount is read_only (must be writeable)"
fi
ac_log "hcl: /artifacts volume_mount references the artifacts volume, writeable"

# The volume "artifacts" block: host type, source vault-artifacts, not read_only.
ART_VOL=$(awk '
  /^[[:space:]]*volume[[:space:]]+"artifacts"[[:space:]]*\{/ { buf = $0; inblk = 1; next }
  inblk {
    buf = buf "\n" $0
    if ($0 ~ /^[[:space:]]*}/) { print buf; inblk = 0 }
  }
' "$HCL")
[ -n "$ART_VOL" ] \
  || ac_fail "vault-runner.hcl: no volume \"artifacts\" block"
grep -qE 'type[[:space:]]*=[[:space:]]*"host"' <<<"$ART_VOL" \
  || ac_fail "vault-runner.hcl: volume \"artifacts\" is not type host"
grep -qE 'source[[:space:]]*=[[:space:]]*"vault-artifacts"' <<<"$ART_VOL" \
  || ac_fail "vault-runner.hcl: volume \"artifacts\" does not source host_volume vault-artifacts"
if grep -q 'read_only' <<<"$ART_VOL"; then
  ac_fail "vault-runner.hcl: volume \"artifacts\" is read_only (must be writeable)"
fi
ac_log "hcl: volume \"artifacts\" is a writeable host volume (source vault-artifacts)"

grep -qE 'ARTIFACTS_DIR[[:space:]]*=[[:space:]]*"/artifacts"' "$HCL" \
  || ac_fail "vault-runner.hcl: ARTIFACTS_DIR=/artifacts env not set"
grep -qE 'ARTIFACTS_GLOB[[:space:]]*=[[:space:]]*"\$\{NOMAD_META_artifacts_csv\}"' "$HCL" \
  || ac_fail "vault-runner.hcl: ARTIFACTS_GLOB env not wired to \${NOMAD_META_artifacts_csv}"
ac_log "hcl: ARTIFACTS_DIR/ARTIFACTS_GLOB env exposed to the task"

# ── 2. host volume declared + dir created at cluster-up ─────────────────────
grep -q 'host_volume "vault-artifacts"' "$REPO_ROOT/nomad/client.hcl" \
  || ac_fail "nomad/client.hcl: host_volume \"vault-artifacts\" not declared"
grep -q '/srv/disinto/vault-artifacts' "$REPO_ROOT/nomad/client.hcl" \
  || ac_fail "nomad/client.hcl: vault-artifacts host_volume path missing"
grep -q '/srv/disinto/vault-artifacts' "$REPO_ROOT/lib/init/nomad/cluster-up.sh" \
  || ac_fail "lib/init/nomad/cluster-up.sh: /srv/disinto/vault-artifacts not in HOST_VOLUME_DIRS"
ac_log "cluster: vault-artifacts host_volume declared and dir in HOST_VOLUME_DIRS"

# ── 3. Dry-run proof: nomad dispatch carries image + artifacts_csv ─────────
# Extract _launch_runner_nomad and run it in a subshell with `nomad`, `log`
# and `write_result` stubbed: the stub records every -meta k=v it sees and
# answers the polling loop with an already-terminal (dead) alloc, so no
# sleep ever fires and no real nomad is touched.
FN_NOMAD=$(ac_extract_fn _launch_runner_nomad "$DISPATCHER")
[ -n "$FN_NOMAD" ] \
  || ac_fail "could not extract _launch_runner_nomad from docker/edge/dispatcher.sh"

run_nomad_dryrun() {
  # Prints the -meta k=v lines the stubbed `nomad job dispatch` received.
  # The stub records them to $META_FILE because dispatch runs inside the
  # function's $(nomad ...) command substitution — array appends in that
  # subshell would not survive back to the parent.
  local fn_src="$1" image_arg="$2"
  local meta_file
  meta_file=$(mktemp)
  META_FILE="$meta_file" bash -s "$fn_src" "$image_arg" <<'EOF'
set -u
log() { :; }
write_result() { :; }
: > "$META_FILE"
nomad() {
  case "$1 $2" in
    "job dispatch")
      local a got_meta=0
      for a in "$@"; do
        if [ "$got_meta" -eq 1 ]; then
          printf '%s\n' "$a" >> "$META_FILE"
          got_meta=0
          continue
        fi
        if [ "$a" = "-meta" ]; then
          got_meta=1
        fi
      done
      echo "Dispatched Job ID = vault-runner/dispatch-fake"
      ;;
    "job status")
      echo '{"Status":"dead","Allocations":[{"ID":"alloc-fake"}]}'
      ;;
    "alloc status")
      if [ "${3:-}" = "-json" ]; then
        echo '{"TaskStates":{"runner":{"Events":[]}}}'
      else
        echo "alloc-fake dead runner"
      fi
      ;;
    "alloc logs")
      :
      ;;
  esac
  return 0
}
eval "$1"
_launch_runner_nomad "ac-test" "" "" "$2" "" >/dev/null 2>&1 || true
exit 0
EOF
  cat "$meta_file"
  rm -f "$meta_file"
}

# Action with image = "busybox": dispatch must carry image=busybox.
OUT=$(run_nomad_dryrun "$FN_NOMAD" "busybox")
grep -qx "image=busybox" <<<"$OUT" \
  || ac_fail "dry-run: action image not forwarded as dispatch meta (got: $(tr '\n' ' ' <<<"$OUT"))"
grep -qx "action_id=ac-test" <<<"$OUT" \
  || ac_fail "dry-run: action_id meta missing from dispatch"
grep -qx "artifacts_csv=" <<<"$OUT" \
  || ac_fail "dry-run: artifacts_csv meta not passed (even when empty)"
ac_log "dry-run: image=busybox forwarded via nomad job dispatch meta"

# Action without image: the dispatcher default disinto/agents:local applies.
OUT=$(run_nomad_dryrun "$FN_NOMAD" "")
grep -qx "image=disinto/agents:local" <<<"$OUT" \
  || ac_fail "dry-run: empty action image did not default to disinto/agents:local (got: $(tr '\n' ' ' <<<"$OUT"))"
ac_log "dry-run: empty action image defaults to disinto/agents:local"

# ── 4. Docker backend: action image + default, /artifacts mount ────────────
FN_DOCKER=$(ac_extract_fn _launch_runner_docker "$DISPATCHER")
[ -n "$FN_DOCKER" ] \
  || ac_fail "could not extract _launch_runner_docker from docker/edge/dispatcher.sh"
grep -qF 'local image_name="${image:-disinto/agents:latest}"' <<<"$FN_DOCKER" \
  || ac_fail "_launch_runner_docker: missing disinto/agents:latest default for the action image"
grep -qF 'cmd+=("$image_name"' <<<"$FN_DOCKER" \
  || ac_fail "_launch_runner_docker: docker run does not use the action image"
grep -qF '/artifacts' <<<"$FN_DOCKER" \
  || ac_fail "_launch_runner_docker: no /artifacts mount"
grep -q 'ARTIFACTS_GLOB' <<<"$FN_DOCKER" \
  || ac_fail "_launch_runner_docker: ARTIFACTS_GLOB env not passed to the container"
ac_log "docker: action image honored (default disinto/agents:latest), /artifacts mounted"

# launch_runner itself must read the validated fields and forward 5 args.
FN_LAUNCH=$(ac_extract_fn launch_runner "$DISPATCHER")
[ -n "$FN_LAUNCH" ] \
  || ac_fail "could not extract launch_runner from docker/edge/dispatcher.sh"
grep -q 'VAULT_ACTION_IMAGE' <<<"$FN_LAUNCH" \
  || ac_fail "launch_runner: does not read VAULT_ACTION_IMAGE"
grep -q 'VAULT_ACTION_ARTIFACTS' <<<"$FN_LAUNCH" \
  || ac_fail "launch_runner: does not read VAULT_ACTION_ARTIFACTS"
grep -qF '"$image" "$artifacts_csv"' <<<"$FN_LAUNCH" \
  || ac_fail "launch_runner: does not forward image/artifacts_csv to the backend launcher"
ac_log "launch_runner: forwards image + artifacts_csv to the backend launcher"

# ── 5. Regression: unknown action fields still fail validation ─────────────
VALIDATE="$REPO_ROOT/action-vault/validate.sh"
ac_assert_file "$VALIDATE" "action-vault/validate.sh is missing"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/vault-action.toml" <<'EOF'
id = "issue-1307-regression"
formula = "release"
context = "Acceptance test for issue #1307"
secrets = []
bogus_field = "x"
EOF
# Direct invocation (no shared helper — this test validates a single TOML,
# and the run_validate helper in issue-1296.sh is kept distinct for the
# duplicate-code gate).
V_RC=0
V_OUT="$(bash "$VALIDATE" "$TMP_DIR/vault-action.toml" 2>&1)" || V_RC=$?
[ "$V_RC" -ne 0 ] || ac_fail "unknown field: validation succeeded (must fail)"
grep -q "Unknown fields" <<<"$V_OUT" \
  || ac_fail "unknown field: validation failed without an 'Unknown fields' error (got: ${V_OUT:0:300})"
ac_log "regression: unknown action fields still rejected with an 'Unknown fields' error"

# ── 6. SCHEMA.md documents the dispatch behaviour ───────────────────────────
SCHEMA="$REPO_ROOT/action-vault/SCHEMA.md"
ac_assert_file "$SCHEMA" "action-vault/SCHEMA.md is missing"
grep -q 'ARTIFACTS_GLOB' "$SCHEMA" \
  || ac_fail "SCHEMA.md: does not document ARTIFACTS_GLOB"
grep -q 'disinto/agents:local' "$SCHEMA" \
  || ac_fail "SCHEMA.md: does not document the disinto/agents:local default image"
grep -q '/artifacts' "$SCHEMA" \
  || ac_fail "SCHEMA.md: does not document the /artifacts mount"
ac_log "SCHEMA.md: dispatch behaviour documented"

ac_pass
