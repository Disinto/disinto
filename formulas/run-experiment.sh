#!/usr/bin/env bash
# =============================================================================
# formulas/run-experiment.sh — Mechanical SSH/image dispatch for research runs
#
# Part of #1293 wave 2 (issue #1308). Executes a research-run vault action
# mechanically — no LLM, no Meep:
#
#   1. Reads the vault action TOML ($VAULT_ACTION_TOML): image (required),
#      host, artifacts, resource_class, timeout_minutes, and context — the
#      argv line, e.g. context = "echo ok".
#   2. vault_ssh_install — installs the vault-held SSH files into ~/.ssh
#      (no-op when the action did not declare SSH_KEY).
#   3. Resolves the run host: `host` when set, else the first
#      resource_class fit in RESOURCES.md (ops repo, then factory —
#      lib/resources.sh, #1304), else local.
#   4. Runs `docker run --rm <image> <argv...>` locally, or over SSH on the
#      resolved host (same container command against the host-side
#      artifacts dir), wall-clock-bounded by timeout_minutes (default 60).
#   5. Appends a run-ledger row (lib/run-ledger.sh, #1297) to
#      $OPS_REPO_ROOT/runs/<id>.json — id, action_id, git_tree, image,
#      host (alias; empty = local), argv, started, ended, exit, artifacts.
#   6. Copies the artifact globs into $OPS_REPO_ROOT/artifacts/<action-id>/.
#
# A missing RESOURCES.md or an unresolvable host is a FAILED RUN (ledger
# row with a non-zero exit, formula exits 1) — never a hang: ssh uses
# BatchMode + ConnectTimeout, and the run itself is wrapped in `timeout`.
#
# Usage: run-experiment.sh <action-id>
#
# Expects:
#   OPS_REPO_ROOT   — ops repo (ledger row + artifacts land here)
#   FACTORY_ROOT    — disinto code root (lib/ lives here)
#   VAULT_ACTION_TOML — exported by entrypoint-runner.sh
#   ARTIFACTS_DIR   — writeable run-output mount set by the dispatcher
#                     (#1307); falls back to $VAULT_ARTIFACTS_DIR/<action-id>
#
# Secrets: SSH_KEY, SSH_KNOWN_HOSTS (vault file secrets —
# action-vault/SCHEMA.md).
# =============================================================================

set -euo pipefail

FACTORY_ROOT="${FACTORY_ROOT:-/home/agent/disinto}"
OPS_REPO_ROOT="${OPS_REPO_ROOT:-/home/agent/ops}"

log() {
  printf '[%s] run-experiment: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

die() {
  log "ERROR: $*"
  exit 2
}

# ── Argument + action TOML ──────────────────────────────────────────────────

action_id="${1:-}"
[ -n "$action_id" ] || die "action-id argument required"
[ -n "$OPS_REPO_ROOT" ] || die "OPS_REPO_ROOT is empty — the ledger has nowhere to go"

action_toml="${VAULT_ACTION_TOML:-${OPS_REPO_ROOT}/vault/actions/${action_id}.toml}"
[ -f "$action_toml" ] || die "vault action TOML not found: $action_toml"

command -v timeout >/dev/null 2>&1 || die "coreutils 'timeout' not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH (required by the run ledger)"

# ── TOML extraction ─────────────────────────────────────────────────────────

toml_field() {
  # toml_field <name> — raw right-hand side (quotes/brackets intact), '' when
  # the field is absent.
  local name="$1"
  grep -E "^${name}[[:space:]]*=" "$action_toml" 2>/dev/null | head -n1 \
    | sed -E "s/^${name}[[:space:]]*=[[:space:]]*//" | tr -d '\r' || true
}

unquote() {
  printf '%s' "$1" | sed -E "s/^\"(.*)\"$/\1/; s/^'(.*)'$/\1/"
}

image="$(unquote "$(toml_field image)")"
[ -n "$image" ] || die "action TOML has no 'image' field (research runs require one): $action_toml"

# context is the argv line (the #1296 schema has no separate argv field).
context="$(unquote "$(toml_field context)")"
read -r -a argv_arr <<< "$context"
[ "${#argv_arr[@]}" -gt 0 ] || die "action TOML 'context' (the argv line) is empty: $action_toml"

host_alias="$(unquote "$(toml_field host)")"
resource_class="$(unquote "$(toml_field resource_class)")"

# artifacts: string or array of strings — normalize to space-joined globs
# (same normalization as action-vault/vault-env.sh).
artifacts_glob="$(printf '%s' "$(toml_field artifacts)" | tr -d "\"'[]" | sed -E 's/,/ /g; s/^[[:space:]]+//; s/[[:space:]]+$//')"
[ -n "$artifacts_glob" ] || artifacts_glob="${ARTIFACTS_GLOB:-}"

timeout_minutes="$(toml_field timeout_minutes | tr -d '[:space:]')"
case "$timeout_minutes" in
  '' | *[!0-9]*) timeout_minutes=60 ;;
esac
timeout_secs=$((timeout_minutes * 60))

# ── Shared libs (pure function files — safe to source) ──────────────────────

LIB_DIR="${FACTORY_ROOT}/lib"
for lib in vault-ssh.sh resources.sh run-ledger.sh; do
  [ -f "${LIB_DIR}/${lib}" ] || die "lib missing: ${LIB_DIR}/${lib} (FACTORY_ROOT=${FACTORY_ROOT})"
done
# shellcheck source=lib/vault-ssh.sh
source "${LIB_DIR}/vault-ssh.sh"
# shellcheck source=lib/resources.sh
source "${LIB_DIR}/resources.sh"
# shellcheck source=lib/run-ledger.sh
source "${LIB_DIR}/run-ledger.sh"

# Step 2: vault-held SSH material (no-op when SSH_KEY was not declared).
vault_ssh_install "${NOMAD_SECRETS_DIR:-/secrets}" "${HOME:-/home/agent}"

# Run output dirs: local (or container-mounted) for the local dispatch, and
# the same path on the remote host for the SSH dispatch.
art_dir="${ARTIFACTS_DIR:-${VAULT_ARTIFACTS_DIR:-/var/lib/disinto/vault-artifacts}/${action_id}}"
remote_art="${VAULT_ARTIFACTS_DIR:-/var/lib/disinto/vault-artifacts}/${action_id}"

# ── finish: collect + ledger row + exit (never returns) ─────────────────────

# finish <rc> <started> <ended>
finish() {
  local rc="$1" started="$2" ended="$3"
  local ops_art="${OPS_REPO_ROOT}/artifacts/${action_id}"

  # Pull remote artifacts back (best effort — a failed run may have no dir).
  if [ "$remote" -eq 1 ]; then
    mkdir -p "$art_dir" 2>/dev/null || true
    if [ -d "$art_dir" ]; then
      if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$ssh_target" \
           "tar -C '${remote_art}' -cf - ." 2>/dev/null \
           | tar -C "$art_dir" -xf - 2>/dev/null; then
        log "WARN: remote artifact pull failed (host=${ssh_target}, remote dir=${remote_art}) — continuing"
      fi
    fi
  fi

  # Collect the artifact globs into the ops repo.
  local artifacts_json="[]"
  if [ -d "$art_dir" ] && [ -n "$(find "$art_dir" -type f 2>/dev/null | head -n1)" ]; then
    if mkdir -p "$ops_art" 2>/dev/null; then
      local -a glob_arr=()
      if [ -n "$artifacts_glob" ]; then
        read -r -a glob_arr <<< "$artifacts_glob"
      fi
      local -a collected=()
      local rel matched g dest
      while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        matched=0
        if [ "${#glob_arr[@]}" -gt 0 ]; then
          for g in "${glob_arr[@]}"; do
            # shellcheck disable=SC2053  # glob match on purpose
            if [[ "$rel" == $g ]]; then
              matched=1
              break
            fi
          done
        else
          matched=1
        fi
        [ "$matched" -eq 1 ] || continue
        dest="${ops_art}/${rel}"
        mkdir -p "$(dirname "$dest")"
        cp -a "${art_dir}/${rel}" "$dest"
        collected+=("${action_id}/${rel}")
      done < <(cd "$art_dir" && find . -type f | sed 's|^\./||' | sort)
      if [ "${#collected[@]}" -gt 0 ]; then
        artifacts_json="$(printf '%s\n' "${collected[@]}" | jq -R . | jq -s .)"
        log "collected ${#collected[@]} file(s) into ${ops_art}"
      fi
    else
      log "ERROR: cannot write artifacts to ${ops_art} (ops repo unwritable?)"
    fi
  fi

  # Ledger row.
  local git_tree stamp run_id n
  git_tree="$(git -C "$FACTORY_ROOT" rev-parse HEAD 2>/dev/null || true)"
  stamp="$(date -u +%Y%m%d-%H%M%S)"
  run_id="${action_id}-${stamp}"
  n=2
  while [ -e "${OPS_REPO_ROOT}/runs/${run_id}.json" ]; do
    run_id="${action_id}-${stamp}-${n}"
    n=$((n + 1))
  done

  local argv_json
  if [ "${#argv_arr[@]}" -gt 0 ]; then
    argv_json="$(printf '%s\n' "${argv_arr[@]}" | jq -R . | jq -s .)"
  else
    argv_json="[]"
  fi

  local record_file
  record_file="$(mktemp)"
  jq -n \
    --arg id "$run_id" \
    --arg action_id "$action_id" \
    --arg git_tree "$git_tree" \
    --arg image "$image" \
    --arg host "$host_alias" \
    --argjson argv "$argv_json" \
    --arg started "$started" \
    --arg ended "$ended" \
    --argjson exit_code "$rc" \
    --argjson artifacts "$artifacts_json" \
    '{id: $id, action_id: $action_id, git_tree: $git_tree, image: $image,
      host: $host, argv: $argv, started: $started, ended: $ended,
      "exit": $exit_code, artifacts: $artifacts}' > "$record_file"

  if run_ledger_append "$OPS_REPO_ROOT" "$record_file"; then
    rm -f "$record_file"
    if [ "$rc" -eq 0 ]; then
      log "action ${action_id} completed (ledger row ${run_id})"
    else
      log "action ${action_id} failed (rc=${rc}, ledger row ${run_id})"
    fi
    exit "$rc"
  fi
  rm -f "$record_file"
  log "ERROR: run_ledger_append refused row ${run_id} (validation or duplicate id) — run output remains in ${art_dir}"
  exit 1
}

# ── Step 3: host resolution ─────────────────────────────────────────────────
# RESOURCES.md: ops repo first, then factory (the factory one is
# gitignored, so this is mostly a fallback for standalone runs).

resources_file=""
if [ -f "${OPS_REPO_ROOT}/RESOURCES.md" ]; then
  resources_file="${OPS_REPO_ROOT}/RESOURCES.md"
elif [ -f "${FACTORY_ROOT}/RESOURCES.md" ]; then
  resources_file="${FACTORY_ROOT}/RESOURCES.md"
fi

remote=0
ssh_target=""

# Host resolution is a FAILED RUN, not a hang: ledger row with exit 1, exit 1.
fail_before_run() {
  local reason="$1" now
  log "ERROR: ${reason}"
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  finish 1 "$now" "$now"
}

if [ -n "$host_alias" ]; then
  [ -n "$resources_file" ] || fail_before_run "host '${host_alias}' is set but no RESOURCES.md found (ops: ${OPS_REPO_ROOT}, factory: ${FACTORY_ROOT})"
  ssh_target="$(resources_field "$resources_file" "$host_alias" ssh)" || fail_before_run "host alias '${host_alias}' not found in RESOURCES.md (${resources_file})"
  [ -n "$ssh_target" ] || fail_before_run "host alias '${host_alias}' has no 'ssh:' field in RESOURCES.md (${resources_file})"
  remote=1
elif [ -n "$resource_class" ]; then
  [ -n "$resources_file" ] || fail_before_run "resource_class '${resource_class}' is set but no RESOURCES.md found (ops: ${OPS_REPO_ROOT}, factory: ${FACTORY_ROOT})"
  host_alias="$(resources_pick "$resources_file" "$resource_class")" || fail_before_run "no host of class '${resource_class}' with in-flight count below cap in RESOURCES.md (${resources_file})"
  ssh_target="$(resources_field "$resources_file" "$host_alias" ssh)" || fail_before_run "picked host '${host_alias}' has no 'ssh:' field in RESOURCES.md (${resources_file})"
  [ -n "$ssh_target" ] || fail_before_run "picked host '${host_alias}' has no 'ssh:' field in RESOURCES.md (${resources_file})"
  remote=1
else
  log "no host and no resource_class — dispatching locally"
fi

# ── Step 4: the run itself ──────────────────────────────────────────────────

# The container command, exported so the `timeout`'d child bash can run it.
# (An exported function survives `bash -c` where a PATH-stubbed `docker`
# would not survive execvp — that is how acceptance tests stub the run.)
_run_experiment_cmd() {
  if [ "$RUNEXP_REMOTE" = "1" ]; then
    # The quoted pieces expand HERE, so the remote shell receives one
    # literal command line and parses it itself.
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$RUNEXP_SSH_TARGET" \
      "mkdir -p '${RUNEXP_REMOTE_ART}' && docker run --rm -v '${RUNEXP_REMOTE_ART}:/artifacts' -e ARTIFACTS_DIR=/artifacts -e ARTIFACTS_GLOB='${RUNEXP_ARTIFACTS_GLOB}' ${RUNEXP_IMAGE} ${RUNEXP_CONTEXT}"
  else
    # shellcheck disable=SC2086  # word-split on purpose: context is the argv line
    docker run --rm -v "${RUNEXP_ART_DIR}:/artifacts" -e ARTIFACTS_DIR=/artifacts -e ARTIFACTS_GLOB="${RUNEXP_ARTIFACTS_GLOB}" "${RUNEXP_IMAGE}" ${RUNEXP_CONTEXT}
  fi
}
export -f _run_experiment_cmd
RUNEXP_REMOTE="$remote"
RUNEXP_SSH_TARGET="$ssh_target"
RUNEXP_IMAGE="$image"
RUNEXP_CONTEXT="$context"
RUNEXP_ART_DIR="$art_dir"
RUNEXP_REMOTE_ART="$remote_art"
RUNEXP_ARTIFACTS_GLOB="$artifacts_glob"
export RUNEXP_REMOTE RUNEXP_SSH_TARGET RUNEXP_IMAGE RUNEXP_CONTEXT RUNEXP_ART_DIR RUNEXP_REMOTE_ART RUNEXP_ARTIFACTS_GLOB

run_log="$(mktemp)"
trap 'rm -f "$run_log"' EXIT

if [ "$remote" -eq 1 ]; then
  log "remote dispatch: ssh ${ssh_target} → docker run --rm ${image} ${context} (timeout ${timeout_secs}s)"
else
  log "local dispatch: docker run --rm ${image} ${context} (timeout ${timeout_secs}s)"
  mkdir -p "$art_dir"
fi

started="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
run_rc=0
timeout "$timeout_secs" bash -c '_run_experiment_cmd' >"$run_log" 2>&1 || run_rc=$?
ended="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

if [ "$run_rc" -eq 124 ]; then
  log "run hit its ${timeout_secs}s timeout (timeout_minutes=${timeout_minutes})"
fi
if [ "$run_rc" -ne 0 ]; then
  log "run exited ${run_rc} — last lines of run output:"
  tail -n 20 "$run_log" | sed 's/^/    /'
fi

# ── Steps 5+6: ledger row + artifact collection (never returns) ─────────────
finish "$run_rc" "$started" "$ended"
