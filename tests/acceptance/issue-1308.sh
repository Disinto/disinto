#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1308.sh
#
# Issue #1308: formulas/run-experiment.sh — mechanical SSH/image dispatch for
# research runs. The formula reads the vault action TOML, installs vault SSH
# files (no-op without SSH_KEY), resolves the run host (host field, else
# resource_class against RESOURCES.md via lib/resources.sh, else local),
# runs `docker run --rm <image> <argv...>` locally or over SSH, appends a
# run-ledger row, and collects the artifact globs into ops/artifacts/<id>/.
#
# Verifies (hermetic — no docker daemon, no forge, no real ssh; docker/ssh
# are exported-function stubs; all state in mktemp dirs):
#   1. formulas/run-experiment.sh exists, parses, is executable, and
#      contains no LLM call.
#   2. action-vault/policy.toml tiers run-experiment as "medium".
#   3. action-vault/examples/run-experiment.toml is VALID with the
#      run-experiment formula and SSH_KEY/SSH_KNOWN_HOSTS secrets.
#   4. Local dispatch (busybox `echo ok`): the docker stub receives
#      `docker run --rm -v <dir>:/artifacts ... busybox echo ok`; a ledger
#      row is written with exit 0, host "" (local), argv ["echo","ok"],
#      image busybox; the artifact is collected into ops/artifacts/<id>/;
#      the formula exits 0.
#   5. Missing RESOURCES.md / unresolvable host is a FAILED RUN, not a
#      hang: host="ghost" (no RESOURCES.md) and resource_class without
#      RESOURCES.md both finish quickly with a non-zero exit and a ledger
#      row whose exit != 0.
#   6. Remote dispatch: host resolves to an ssh target via RESOURCES.md;
#      the ssh stub sees `docker run` against the remote artifacts dir; the
#      row records the host alias and the remote artifact is collected.
#
# Run via: tools/run-acceptance.sh 1308
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep sed find sort jq mktemp tar date timeout

# validate.sh (via vault-env.sh) requires USER/HOME
export USER="${USER:-$(id -un)}"
export HOME="${HOME:-/root}"

FORMULA="$REPO_ROOT/formulas/run-experiment.sh"
POLICY="$REPO_ROOT/action-vault/policy.toml"
EXAMPLE="$REPO_ROOT/action-vault/examples/run-experiment.toml"
VALIDATE="$REPO_ROOT/action-vault/validate.sh"

# ── 1. formula: exists, parses, no LLM, executable ──────────────────────────

ac_assert_file "$FORMULA" "formulas/run-experiment.sh is missing"
bash -n "$FORMULA" || ac_fail "formulas/run-experiment.sh does not parse (bash -n)"
if grep -qi 'claude' "$FORMULA"; then
  ac_fail "formulas/run-experiment.sh references the LLM (must be a mechanical formula)"
fi
[ -x "$FORMULA" ] || ac_fail "formulas/run-experiment.sh is not executable"
ac_log "formula: exists, parses, no LLM, executable"

# ── 2. policy: run-experiment = medium ──────────────────────────────────────

grep -qE '^run-experiment[[:space:]]*=[[:space:]]*"medium"' "$POLICY" \
  || ac_fail "policy.toml: run-experiment is not tiered \"medium\""
ac_log "policy: run-experiment = medium"

# ── 3. example TOML: VALID, formula + SSH secrets ───────────────────────────

V_OUT="$(bash "$VALIDATE" "$EXAMPLE" 2>&1)" || ac_fail "example run-experiment.toml is not VALID: ${V_OUT:0:300}"
grep -q "VALID" <<<"$V_OUT" || ac_fail "validate.sh did not report VALID for the example"
grep -qE '^formula[[:space:]]*=[[:space:]]*"run-experiment"' "$EXAMPLE" \
  || ac_fail "example: formula is not run-experiment"
grep -q 'SSH_KEY' "$EXAMPLE" || ac_fail "example: SSH_KEY secret not declared"
grep -q 'SSH_KNOWN_HOSTS' "$EXAMPLE" || ac_fail "example: SSH_KNOWN_HOSTS secret not declared"
ac_log "example: VALID, formula=run-experiment, SSH secrets declared"

# ── hermetic setup ───────────────────────────────────────────────────────────

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Factory root for the formula: real lib/ (sourced by the formula), no
# RESOURCES.md — so "no RESOURCES.md" scenarios hold.
TFACT="$TMP_DIR/factory"
mkdir -p "$TFACT"
ln -s "$REPO_ROOT/lib" "$TFACT/lib"

DOCKER_CALLS="$TMP_DIR/docker-calls.txt"
SSH_CALLS="$TMP_DIR/ssh-calls.txt"
REMOTE_FS="$TMP_DIR/remote-fs"
: > "$DOCKER_CALLS"
: > "$SSH_CALLS"
mkdir -p "$REMOTE_FS" "$TMP_DIR/home"
export DOCKER_CALLS SSH_CALLS REMOTE_FS

# Stub `docker run --rm -v src:dst -e K=V ... <image> <argv...>` — emulates
# the mount by writing into src (the host side of the bind mount).
docker() {
  local -a args=("$@")
  [ "${args[0]:-}" = "run" ] || return 2
  local n=${#args[@]} i=1 a mount_full="" image=""
  local -a rest=()
  local j
  while [ "$i" -lt "$n" ]; do
    a="${args[$i]}"
    case "$a" in
      -v) mount_full="${args[$((i + 1))]-}"; i=$((i + 2)) ;;
      -e) i=$((i + 2)) ;;
      -*) i=$((i + 1)) ;;
      *)
        image="$a"
        for ((j = i + 1; j < n; j++)); do
          rest+=("${args[$j]}")
        done
        i=$n
        ;;
    esac
  done
  [ -n "$image" ] || return 2
  local host_side="${mount_full%%:*}"
  printf 'run image=%s mount=%s argv=%s\n' "$image" "$mount_full" "${rest[*]-}" >> "$DOCKER_CALLS"
  mkdir -p "$host_side"
  if [ "$image" = "busybox" ] && [ "${rest[0]:-}" = "echo" ]; then
    mkdir -p "$host_side/out"
    printf '%s\n' "${rest[1]:-}" > "$host_side/out/ok.txt"
  fi
  return 0
}
export -f docker

# Stub `ssh -o ... <target> <command>` — records the call, simulates the
# remote docker run by staging files under $REMOTE_FS, and serves the pull
# with a real tar.
ssh() {
  local target="" cmd=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -o) shift 2 ;;
      *)
        target="$1"
        shift
        cmd="$*"
        break
        ;;
    esac
  done
  [ -n "$target" ] || return 2
  printf '%s :: %s\n' "$target" "$cmd" >> "$SSH_CALLS"
  case "$cmd" in
    *docker\ run*)
      local rel
      rel="$(printf '%s\n' "$cmd" | sed -E "s/.*mkdir -p '([^']+)'.*/\1/")"
      rel="${rel#/}"
      mkdir -p "$REMOTE_FS/$rel"
      printf 'remote-out\n' > "$REMOTE_FS/$rel/remote.txt"
      ;;
    *tar\ -C*)
      local rel
      rel="$(printf '%s\n' "$cmd" | sed -E "s/.*tar -C '([^']+)'.*/\1/")"
      rel="${rel#/}"
      if [ -d "$REMOTE_FS/$rel" ]; then
        ( cd "$REMOTE_FS/$rel" && tar -cf - . )
      fi
      ;;
  esac
  return 0
}
export -f ssh

# run_formula <action-id> <toml> <ops-dir> <artifacts-dir>
run_formula() {
  local action_id="$1" toml="$2" ops="$3" arts="$4"
  mkdir -p "$ops" "$arts" "$TMP_DIR/home"
  VAULT_ACTION_TOML="$toml" \
  OPS_REPO_ROOT="$ops" \
  FACTORY_ROOT="$TFACT" \
  VAULT_ARTIFACTS_DIR="$arts" \
  HOME="$TMP_DIR/home" \
  timeout 30 bash "$FORMULA" "$action_id"
}

# ── 4. local dispatch: busybox echo ok ──────────────────────────────────────

OPS4="$TMP_DIR/ops-local"
ARTS4="$TMP_DIR/arts-local"
TOML4="$TMP_DIR/toml4.toml"
cat > "$TOML4" <<'EOF'
id = "acc-1308-local"
formula = "run-experiment"
context = "echo ok"
secrets = ["SSH_KEY"]
image = "busybox"
artifacts = ["out/*.txt"]
timeout_minutes = 5
EOF

_RC=0
run_formula "acc-1308-local" "$TOML4" "$OPS4" "$ARTS4" || _RC=$?
[ "$_RC" -eq 0 ] || ac_fail "local run: formula exited ${_RC} (expected 0)"

grep -q "image=busybox" "$DOCKER_CALLS" || ac_fail "local run: docker stub did not receive the busybox image (calls: $(cat "$DOCKER_CALLS"))"
grep -q "mount=.*:/artifacts" "$DOCKER_CALLS" || ac_fail "local run: /artifacts mount missing from the docker run"
grep -q "argv=echo ok" "$DOCKER_CALLS" || ac_fail "local run: argv line not passed to docker (calls: $(cat "$DOCKER_CALLS"))"

ROWS4="$(find "$OPS4/runs" -name '*.json' 2>/dev/null | sort)"
[ "$(printf '%s\n' "$ROWS4" | grep -c .)" -eq 1 ] || ac_fail "local run: expected exactly 1 ledger row"
ROW4="$(head -n1 <<<"$ROWS4")"
ROW4_JSON="$(cat "$ROW4")"
ac_assert_jq '.exit == 0' "$ROW4_JSON" "local run: ledger row exit != 0"
ac_assert_jq '.action_id == "acc-1308-local"' "$ROW4_JSON" "local run: ledger row action_id wrong"
ac_assert_jq '.image == "busybox"' "$ROW4_JSON" "local run: ledger row image wrong"
ac_assert_jq '.host == ""' "$ROW4_JSON" "local run: ledger row host should be empty (local dispatch)"
ac_assert_jq '.argv == ["echo","ok"]' "$ROW4_JSON" "local run: ledger row argv mismatch"
ac_assert_jq '.id | startswith("acc-1308-local-")' "$ROW4_JSON" "local run: ledger row id does not derive from the action id"
ac_assert_jq '.artifacts | index("acc-1308-local/out/ok.txt") != null' "$ROW4_JSON" "local run: artifact not recorded in the ledger row"

ac_assert_file "$OPS4/artifacts/acc-1308-local/out/ok.txt" "local run: artifact payload missing in ops/artifacts"
[ "$(cat "$OPS4/artifacts/acc-1308-local/out/ok.txt")" = "ok" ] || ac_fail "local run: artifact payload content wrong"
ac_log "local: busybox echo ok → exit 0 row, artifact collected"

# ── 5. unresolvable host: failed run, not a hang ─────────────────────────────

# 5a: host set, RESOURCES.md nowhere.
TOML5="$TMP_DIR/toml5.toml"
cat > "$TOML5" <<'EOF'
id = "acc-1308-ghost"
formula = "run-experiment"
context = "echo ok"
secrets = ["SSH_KEY", "SSH_KNOWN_HOSTS"]
image = "busybox"
host = "ghost-host"
artifacts = ["out/*.txt"]
EOF

OPS5="$TMP_DIR/ops-ghost"
_RC=0
run_formula "acc-1308-ghost" "$TOML5" "$OPS5" "$TMP_DIR/arts-ghost" || _RC=$?
[ "$_RC" -ne 0 ] || ac_fail "host without RESOURCES.md: formula exited 0 (expected a failed run)"
[ "$_RC" -ne 124 ] || ac_fail "host without RESOURCES.md: formula timed out (hang)"
ROW5="$(find "$OPS5/runs" -name '*.json' 2>/dev/null | head -n1)"
[ -n "$ROW5" ] || ac_fail "host without RESOURCES.md: no ledger row written"
ROW5_JSON="$(cat "$ROW5")"
ac_assert_jq '.exit != 0' "$ROW5_JSON" "host without RESOURCES.md: row exit == 0"
ac_assert_jq '.host == "ghost-host"' "$ROW5_JSON" "host without RESOURCES.md: row host should record the requested alias"

# 5b: resource_class set, RESOURCES.md nowhere.
TOML5B="$TMP_DIR/toml5b.toml"
cat > "$TOML5B" <<'EOF'
id = "acc-1308-gpu"
formula = "run-experiment"
context = "echo ok"
secrets = ["SSH_KEY", "SSH_KNOWN_HOSTS"]
image = "busybox"
resource_class = "gpu"
artifacts = ["out/*.txt"]
EOF

OPS5B="$TMP_DIR/ops-gpu"
_RC=0
run_formula "acc-1308-gpu" "$TOML5B" "$OPS5B" "$TMP_DIR/arts-gpu" || _RC=$?
[ "$_RC" -ne 0 ] || ac_fail "resource_class without RESOURCES.md: formula exited 0 (expected a failed run)"
[ "$_RC" -ne 124 ] || ac_fail "resource_class without RESOURCES.md: formula timed out (hang)"
ROW5B="$(find "$OPS5B/runs" -name '*.json' 2>/dev/null | head -n1)"
[ -n "$ROW5B" ] || ac_fail "resource_class without RESOURCES.md: no ledger row written"
ac_assert_jq '.exit != 0' "$(cat "$ROW5B")" "resource_class without RESOURCES.md: row exit == 0"
ac_log "no-RESOURCES: failed runs recorded (exit 1), no hang"

# ── 6. remote dispatch: host via RESOURCES.md over ssh ───────────────────────

OPS6="$TMP_DIR/ops-remote"
mkdir -p "$OPS6"
cat > "$OPS6/RESOURCES.md" <<'EOF'
## Compute

### box-a
- class: cpu
- ssh: dev@box-a.example
- cap: 2
EOF

TOML6="$TMP_DIR/toml6.toml"
cat > "$TOML6" <<'EOF'
id = "acc-1308-remote"
formula = "run-experiment"
context = "echo ok"
secrets = ["SSH_KEY", "SSH_KNOWN_HOSTS"]
image = "busybox"
host = "box-a"
artifacts = ["*"]
timeout_minutes = 5
EOF

_RC=0
run_formula "acc-1308-remote" "$TOML6" "$OPS6" "$TMP_DIR/arts-remote" || _RC=$?
[ "$_RC" -eq 0 ] || ac_fail "remote run: formula exited ${_RC} (expected 0)"

grep -q "dev@box-a.example" "$SSH_CALLS" || ac_fail "remote run: ssh target from RESOURCES.md not used"
grep -q "docker run" "$SSH_CALLS" || ac_fail "remote run: no docker run over ssh"
grep -q "arts-remote/acc-1308-remote" "$SSH_CALLS" || ac_fail "remote run: remote artifacts dir not in the ssh command"

ROWS6="$(find "$OPS6/runs" -name '*.json' 2>/dev/null | sort)"
[ "$(printf '%s\n' "$ROWS6" | grep -c .)" -eq 1 ] || ac_fail "remote run: expected exactly 1 ledger row"
ROW6_JSON="$(cat "$(head -n1 <<<"$ROWS6")")"
ac_assert_jq '.exit == 0' "$ROW6_JSON" "remote run: ledger row exit != 0"
ac_assert_jq '.host == "box-a"' "$ROW6_JSON" "remote run: ledger row host should be the alias"
ac_assert_jq '.artifacts | index("acc-1308-remote/remote.txt") != null' "$ROW6_JSON" "remote run: remote artifact not recorded"
ac_assert_file "$OPS6/artifacts/acc-1308-remote/remote.txt" "remote run: remote artifact not collected into ops/artifacts"
[ "$(cat "$OPS6/artifacts/acc-1308-remote/remote.txt")" = "remote-out" ] || ac_fail "remote run: collected artifact content wrong"
ac_log "remote: host resolved via RESOURCES.md, docker run over ssh, artifact collected"

ac_pass
