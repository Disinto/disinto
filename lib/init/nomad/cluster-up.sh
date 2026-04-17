#!/usr/bin/env bash
# =============================================================================
# lib/init/nomad/cluster-up.sh — Empty Nomad+Vault cluster orchestrator (S0.4)
#
# Wires together the S0.1–S0.3 building blocks into one idempotent
# "bring up a single-node Nomad+Vault cluster" script:
#
#   1. install.sh                  (nomad + vault binaries + docker daemon)
#   2. systemd-nomad.sh            (nomad.service — unit + enable, not started)
#   3. systemd-vault.sh            (vault.service — unit + vault.hcl + enable)
#   4. Host-volume dirs            (/srv/disinto/* matching nomad/client.hcl)
#   5. /etc/nomad.d/*.hcl          (server.hcl + client.hcl from repo)
#   6. vault-init.sh               (first-run init + unseal + persist keys)
#   7. systemctl start vault       (auto-unseal via ExecStartPost; poll)
#   8. systemctl start nomad       (poll until ≥1 ready node)
#   9. /etc/profile.d/disinto-nomad.sh  (VAULT_ADDR + NOMAD_ADDR for shells)
#
# This is the "empty cluster" orchestrator — no jobs deployed. Subsequent
# Step-1 issues layer job deployment on top of this checkpoint.
#
# Idempotency contract:
#   Running twice back-to-back on a healthy box is a no-op. Each sub-step
#   is itself idempotent — see install.sh / systemd-*.sh / vault-init.sh
#   headers for the per-step contract. Fast-paths in steps 7 and 8 skip
#   the systemctl start when the service is already active + healthy.
#
# Usage:
#   sudo lib/init/nomad/cluster-up.sh            # bring cluster up
#   sudo lib/init/nomad/cluster-up.sh --dry-run  # print step list, exit 0
#
# Environment (override polling for slow boxes):
#   VAULT_POLL_SECS  max seconds to wait for vault to unseal (default: 30)
#   NOMAD_POLL_SECS  max seconds to wait for nomad node=ready (default: 60)
#
# Exit codes:
#   0  success (cluster up, or already up)
#   1  precondition or step failure
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# Sub-scripts (siblings in this directory).
INSTALL_SH="${SCRIPT_DIR}/install.sh"
SYSTEMD_NOMAD_SH="${SCRIPT_DIR}/systemd-nomad.sh"
SYSTEMD_VAULT_SH="${SCRIPT_DIR}/systemd-vault.sh"
VAULT_INIT_SH="${SCRIPT_DIR}/vault-init.sh"

# In-repo Nomad configs copied to /etc/nomad.d/.
NOMAD_CONFIG_DIR="/etc/nomad.d"
NOMAD_SERVER_HCL_SRC="${REPO_ROOT}/nomad/server.hcl"
NOMAD_CLIENT_HCL_SRC="${REPO_ROOT}/nomad/client.hcl"

# /etc/profile.d entry — makes VAULT_ADDR + NOMAD_ADDR available to
# interactive shells without requiring the operator to source anything.
PROFILE_D_FILE="/etc/profile.d/disinto-nomad.sh"

# Host-volume paths — MUST match the `host_volume "..."` declarations
# in nomad/client.hcl. Adding a host_volume block there requires adding
# its path here so the dir exists before nomad starts (otherwise client
# fingerprinting fails and the node stays in "initializing").
HOST_VOLUME_DIRS=(
  "/srv/disinto/forgejo-data"
  "/srv/disinto/woodpecker-data"
  "/srv/disinto/agent-data"
  "/srv/disinto/project-repos"
  "/srv/disinto/caddy-data"
  "/srv/disinto/chat-history"
  "/srv/disinto/ops-repo"
)

# Default API addresses — matches the listener bindings in
# nomad/server.hcl and nomad/vault.hcl. If either file ever moves
# off 127.0.0.1 / default port, update both places together.
VAULT_ADDR_DEFAULT="http://127.0.0.1:8200"
NOMAD_ADDR_DEFAULT="http://127.0.0.1:4646"

VAULT_POLL_SECS="${VAULT_POLL_SECS:-30}"
NOMAD_POLL_SECS="${NOMAD_POLL_SECS:-60}"

log() { printf '[cluster-up] %s\n' "$*"; }
die() { printf '[cluster-up] ERROR: %s\n' "$*" >&2; exit 1; }

# ── Flag parsing ─────────────────────────────────────────────────────────────
dry_run=false
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=true; shift ;;
    -h|--help)
      cat <<EOF
Usage: sudo $(basename "$0") [--dry-run]

Brings up an empty single-node Nomad+Vault cluster (idempotent).

  --dry-run   Print the step list without performing any action.
EOF
      exit 0
      ;;
    *) die "unknown flag: $1" ;;
  esac
done

# ── Dry-run: print step list + exit ──────────────────────────────────────────
if [ "$dry_run" = true ]; then
  cat <<EOF
[dry-run] Step 1/9: install nomad + vault binaries + docker daemon
  → sudo ${INSTALL_SH}

[dry-run] Step 2/9: write + enable nomad.service (NOT started)
  → sudo ${SYSTEMD_NOMAD_SH}

[dry-run] Step 3/9: write + enable vault.service + vault.hcl (NOT started)
  → sudo ${SYSTEMD_VAULT_SH}

[dry-run] Step 4/9: create host-volume dirs under /srv/disinto/
EOF
  for d in "${HOST_VOLUME_DIRS[@]}"; do
    printf '  → install -d -m 0777 %s\n' "$d"
  done
  cat <<EOF

[dry-run] Step 5/9: install /etc/nomad.d/server.hcl + client.hcl from repo
  → ${NOMAD_SERVER_HCL_SRC} → ${NOMAD_CONFIG_DIR}/server.hcl
  → ${NOMAD_CLIENT_HCL_SRC} → ${NOMAD_CONFIG_DIR}/client.hcl

[dry-run] Step 6/9: first-run vault init + persist unseal.key + root.token
  → sudo ${VAULT_INIT_SH}

[dry-run] Step 7/9: systemctl start vault + poll until unsealed (≤${VAULT_POLL_SECS}s)

[dry-run] Step 8/9: systemctl start nomad + poll until ≥1 node ready + docker driver healthy (≤${NOMAD_POLL_SECS}s each)

[dry-run] Step 9/9: write ${PROFILE_D_FILE}
  → export VAULT_ADDR=${VAULT_ADDR_DEFAULT}
  → export NOMAD_ADDR=${NOMAD_ADDR_DEFAULT}

Dry run complete — no changes made.
EOF
  exit 0
fi

# ── Preconditions ────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  die "must run as root (spawns install/systemd/vault-init sub-scripts)"
fi

command -v systemctl >/dev/null 2>&1 \
  || die "systemctl not found (systemd required)"

for f in "$INSTALL_SH" "$SYSTEMD_NOMAD_SH" "$SYSTEMD_VAULT_SH" "$VAULT_INIT_SH"; do
  [ -x "$f" ] || die "sub-script missing or non-executable: ${f}"
done

[ -f "$NOMAD_SERVER_HCL_SRC" ] \
  || die "source config not found: ${NOMAD_SERVER_HCL_SRC}"
[ -f "$NOMAD_CLIENT_HCL_SRC" ] \
  || die "source config not found: ${NOMAD_CLIENT_HCL_SRC}"

# ── Helpers ──────────────────────────────────────────────────────────────────

# install_file_if_differs SRC DST MODE
#   Copy SRC to DST (root:root with MODE) iff on-disk content differs.
#   No-op + log otherwise — preserves mtime, avoids spurious reloads.
install_file_if_differs() {
  local src="$1" dst="$2" mode="$3"
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    log "unchanged: ${dst}"
    return 0
  fi
  log "writing: ${dst}"
  install -m "$mode" -o root -g root "$src" "$dst"
}

# vault_status_json — echo `vault status -format=json`, or '' on unreachable.
#   vault status exit codes: 0 = unsealed, 2 = sealed/uninit, 1 = unreachable.
#   We treat all of 0/2 as "reachable with state"; 1 yields empty output.
#   Wrapped in `|| true` so set -e doesn't abort on exit 2 (the expected
#   sealed-state case during first-boot polling).
vault_status_json() {
  VAULT_ADDR="$VAULT_ADDR_DEFAULT" vault status -format=json 2>/dev/null || true
}

# vault_is_unsealed — true iff vault reachable AND initialized AND unsealed.
vault_is_unsealed() {
  local out init sealed
  out="$(vault_status_json)"
  [ -n "$out" ] || return 1
  init="$(printf '%s' "$out" | jq -r '.initialized' 2>/dev/null)" || init=""
  sealed="$(printf '%s' "$out" | jq -r '.sealed' 2>/dev/null)" || sealed=""
  [ "$init" = "true" ] && [ "$sealed" = "false" ]
}

# nomad_ready_count — echo the number of ready nodes, or 0 on error.
#   `nomad node status -json` returns a JSON array of nodes, each with a
#   .Status field ("initializing" | "ready" | "down" | "disconnected").
nomad_ready_count() {
  local out
  out="$(NOMAD_ADDR="$NOMAD_ADDR_DEFAULT" nomad node status -json 2>/dev/null || true)"
  if [ -z "$out" ]; then
    printf '0'
    return 0
  fi
  printf '%s' "$out" \
    | jq '[.[] | select(.Status == "ready")] | length' 2>/dev/null \
    || printf '0'
}

# nomad_has_ready_node — true iff nomad_ready_count ≥ 1. Wrapper exists
# so poll_until_healthy can call it as a single-arg command name.
nomad_has_ready_node() { [ "$(nomad_ready_count)" -ge 1 ]; }

# nomad_docker_driver_healthy — true iff the nomad self-node reports the
# docker driver as Detected=true AND Healthy=true. Required by Step-1's
# forgejo jobspec (the first docker-driver consumer) — without this the
# node reaches "ready" while docker fingerprinting is still in flight,
# and the first `nomad job run forgejo` times out with an opaque
# "missing drivers" placement failure (#871).
nomad_docker_driver_healthy() {
  local out detected healthy
  out="$(NOMAD_ADDR="$NOMAD_ADDR_DEFAULT" nomad node status -self -json 2>/dev/null || true)"
  [ -n "$out" ] || return 1
  detected="$(printf '%s' "$out" | jq -r '.Drivers.docker.Detected // false' 2>/dev/null)" || detected=""
  healthy="$(printf '%s' "$out" | jq -r '.Drivers.docker.Healthy // false' 2>/dev/null)" || healthy=""
  [ "$detected" = "true" ] && [ "$healthy" = "true" ]
}

# _die_with_service_status SVC REASON
#   Log + dump `systemctl status SVC` to stderr + die with REASON. Factored
#   out so the poll helper doesn't carry three copies of the same dump.
_die_with_service_status() {
  local svc="$1" reason="$2"
  log "${svc}.service ${reason} — systemctl status follows:"
  systemctl --no-pager --full status "$svc" >&2 || true
  die "${svc}.service ${reason}"
}

# poll_until_healthy SVC CHECK_CMD TIMEOUT
#   Tick once per second for up to TIMEOUT seconds, invoking CHECK_CMD as a
#   command name (no arguments). Returns 0 on the first successful check.
#   Fails fast via _die_with_service_status if SVC enters systemd "failed"
#   state, and dies with a status dump if TIMEOUT elapses before CHECK_CMD
#   succeeds. Replaces the two in-line ready=1/break/sleep poll loops that
#   would otherwise each duplicate the same pattern already in vault-init.sh.
poll_until_healthy() {
  local svc="$1" check="$2" timeout="$3"
  local waited=0
  until [ "$waited" -ge "$timeout" ]; do
    systemctl is-failed --quiet "$svc" \
      && _die_with_service_status "$svc" "entered failed state during startup"
    if "$check"; then
      log "${svc} healthy after ${waited}s"
      return 0
    fi
    waited=$((waited + 1))
    sleep 1
  done
  _die_with_service_status "$svc" "not healthy within ${timeout}s"
}

# ── Step 1/9: install.sh (nomad + vault binaries + docker daemon) ────────────
log "── Step 1/9: install nomad + vault binaries + docker daemon ──"
"$INSTALL_SH"

# ── Step 2/9: systemd-nomad.sh (unit + enable, not started) ──────────────────
log "── Step 2/9: install nomad.service (enable, not start) ──"
"$SYSTEMD_NOMAD_SH"

# ── Step 3/9: systemd-vault.sh (unit + vault.hcl + enable) ───────────────────
log "── Step 3/9: install vault.service + vault.hcl (enable, not start) ──"
"$SYSTEMD_VAULT_SH"

# ── Step 4/9: host-volume dirs matching nomad/client.hcl ─────────────────────
log "── Step 4/9: host-volume dirs under /srv/disinto/ ──"
# Parent /srv/disinto/ first (install -d handles missing parents, but being
# explicit makes the log output read naturally as a top-down creation).
install -d -m 0755 -o root -g root "/srv/disinto"
for d in "${HOST_VOLUME_DIRS[@]}"; do
  if [ -d "$d" ]; then
    log "unchanged: ${d}"
  else
    log "creating: ${d}"
    install -d -m 0777 -o root -g root "$d"
  fi
  # Ensure correct permissions (fixes pre-existing 0755 dirs on re-run)
  chmod 0777 "$d"
done

# ── Step 5/9: /etc/nomad.d/server.hcl + client.hcl ───────────────────────────
log "── Step 5/9: install /etc/nomad.d/{server,client}.hcl ──"
# systemd-nomad.sh already created /etc/nomad.d/. Re-assert for clarity +
# in case someone runs cluster-up.sh with an exotic step ordering later.
install -d -m 0755 -o root -g root "$NOMAD_CONFIG_DIR"
install_file_if_differs "$NOMAD_SERVER_HCL_SRC" "${NOMAD_CONFIG_DIR}/server.hcl" 0644
install_file_if_differs "$NOMAD_CLIENT_HCL_SRC" "${NOMAD_CONFIG_DIR}/client.hcl" 0644

# ── Step 6/9: vault-init (first-run init + unseal + persist keys) ────────────
log "── Step 6/9: vault-init (no-op after first run) ──"
# vault-init.sh spawns a temporary vault server if systemd isn't managing
# one, runs `operator init`, writes unseal.key + root.token, unseals once,
# then stops the temp server (EXIT trap). After it returns, port 8200 is
# free for systemctl-managed vault to take in step 7.
"$VAULT_INIT_SH"

# ── Step 7/9: systemctl start vault + poll until unsealed ────────────────────
log "── Step 7/9: start vault + poll until unsealed ──"
# Fast-path when vault.service is already active and Vault reports
# initialized=true,sealed=false — re-runs are a no-op.
if systemctl is-active --quiet vault && vault_is_unsealed; then
  log "vault already active + unsealed — skip start"
else
  systemctl start vault
  poll_until_healthy vault vault_is_unsealed "$VAULT_POLL_SECS"
fi

# ── Step 8/9: systemctl start nomad + poll until ≥1 node ready + docker up ──
log "── Step 8/9: start nomad + poll until ≥1 node ready + docker driver healthy ──"
# Three conditions gate this step:
#   (a) nomad.service active
#   (b) ≥1 nomad node in "ready" state
#   (c) nomad's docker task driver fingerprinted as Detected+Healthy
# (c) can lag (a)+(b) briefly because driver fingerprinting races with
# dockerd startup — polling it explicitly prevents Step-1 deploys from
# hitting "missing drivers" placement failures on a cold-booted host (#871).
if systemctl is-active --quiet nomad \
   && nomad_has_ready_node \
   && nomad_docker_driver_healthy; then
  log "nomad already active + ≥1 node ready + docker driver healthy — skip start"
else
  if ! systemctl is-active --quiet nomad; then
    systemctl start nomad
  fi
  poll_until_healthy nomad nomad_has_ready_node "$NOMAD_POLL_SECS"
  poll_until_healthy nomad nomad_docker_driver_healthy "$NOMAD_POLL_SECS"
fi

# ── Step 9/9: /etc/profile.d/disinto-nomad.sh ────────────────────────────────
log "── Step 9/9: write ${PROFILE_D_FILE} ──"
# Shell rc fragments in /etc/profile.d/ are sourced by /etc/profile for
# every interactive login shell. Setting VAULT_ADDR + NOMAD_ADDR here means
# the operator can run `vault status` / `nomad node status` straight after
# `ssh factory-box` without fumbling env vars.
desired_profile="# /etc/profile.d/disinto-nomad.sh — written by lib/init/nomad/cluster-up.sh
# Interactive-shell defaults for Vault + Nomad clients on this box.
export VAULT_ADDR=${VAULT_ADDR_DEFAULT}
export NOMAD_ADDR=${NOMAD_ADDR_DEFAULT}
"
if [ -f "$PROFILE_D_FILE" ] \
   && printf '%s' "$desired_profile" | cmp -s - "$PROFILE_D_FILE"; then
  log "unchanged: ${PROFILE_D_FILE}"
else
  log "writing: ${PROFILE_D_FILE}"
  # Subshell + EXIT trap: guarantees the tempfile is cleaned up on both
  # success AND set-e-induced failure of `install`. A function-scoped
  # RETURN trap does NOT fire on errexit-abort in bash — the subshell is
  # the reliable cleanup boundary here.
  (
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT
    printf '%s' "$desired_profile" > "$tmp"
    install -m 0644 -o root -g root "$tmp" "$PROFILE_D_FILE"
  )
fi

log "── done: empty nomad+vault cluster is up ──"
log "   Vault:  ${VAULT_ADDR_DEFAULT}  (Sealed=false Initialized=true)"
log "   Nomad:  ${NOMAD_ADDR_DEFAULT}  (≥1 node ready)"
