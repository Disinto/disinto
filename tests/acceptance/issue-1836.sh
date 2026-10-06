#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1836.sh
#
# Issue #1836: dsh_seed_home seeds a one-shot DSH_HOME; the vault runner
# uses it instead of an inline copy of the seed block.
#
# Acceptance (no network, no model):
#   1. docker/runner/entrypoint-runner.sh does not name settings-llamacpp.yaml.
#   2. docker/runner/entrypoint-runner.sh names dsh_seed_home exactly once.
#   3. With an empty DSH_HOME, DSH_BASE_URL set, and a fake DSH_SEED_DIR:
#      dsh_seed_home returns 0 and writes both files, settings.yaml contains
#      the URL; a second call leaves a hand-edited settings.yaml unchanged;
#      with DSH_BASE_URL empty it returns 1 and writes nothing.
#
# Run via: tools/run-acceptance.sh 1836
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep sed

ENTRYPOINT="$REPO_ROOT/docker/runner/entrypoint-runner.sh"
SEED_LIB="$REPO_ROOT/lib/dsh-seed.sh"
ac_assert_file "$ENTRYPOINT" "docker/runner/entrypoint-runner.sh must exist"
ac_assert_file "$SEED_LIB" "lib/dsh-seed.sh must exist"

# ── 1. The inline seed template name is gone from the runner ────────────────
ac_log "AC 1: entrypoint-runner.sh does not name settings-llamacpp.yaml"
yaml_hits="$(grep -n 'settings-llamacpp.yaml' "$ENTRYPOINT" || true)"
[ -z "$yaml_hits" ] \
  || ac_fail "entrypoint-runner.sh must not name settings-llamacpp.yaml (got: ${yaml_hits})"
ac_log "AC 1 OK"

# ── 2. The runner calls the shared helper once ──────────────────────────────
ac_log "AC 2: entrypoint-runner.sh names dsh_seed_home exactly once"
seed_count="$(grep -c 'dsh_seed_home' "$ENTRYPOINT" || true)"
[ "$seed_count" = "1" ] \
  || ac_fail "entrypoint-runner.sh must name dsh_seed_home exactly once (got: ${seed_count})"
ac_log "AC 2 OK"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SEED_DIR="$TMP_DIR/seed"
mkdir -p "$SEED_DIR/profiles"
printf '%s\n' '{"name":"headless"}' > "$SEED_DIR/profiles/headless.json"
printf '%s\n' 'baseURL: __DSH_BASE_URL__' > "$SEED_DIR/settings-llamacpp.yaml"

# seed_call — source the helper in a fresh shell so a return 1 cannot trip
# this test's set -e, and so a prior call cannot leak files into the next.
seed_call() {
  local home="$1"
  local url="${2-}"
  local driver rc
  driver="$(mktemp "${TMP_DIR}/seed.XXXXXX.sh")"
  cat > "$driver" <<EOF
set -euo pipefail
export DSH_HOME="$home"
export DSH_SEED_DIR="$SEED_DIR"
if [ -n "$url" ]; then
  export DSH_BASE_URL="$url"
else
  unset DSH_BASE_URL
fi
# shellcheck source=lib/dsh-seed.sh
source "$SEED_LIB"
dsh_seed_home
EOF
  rc=0
  bash "$driver" || rc=$?
  printf '%s\n' "$rc"
}

# ── 3. Seeds missing files, leaves edits, refuses an empty URL ──────────────
ac_log "AC 3: dsh_seed_home writes both files, then leaves an edit, then refuses an empty URL"
HOME_DIR="$TMP_DIR/dsh-home"
mkdir -p "$HOME_DIR"
rc="$(seed_call "$HOME_DIR" "http://127.0.0.1:9/v1")"
[ "$rc" = "0" ] \
  || ac_fail "dsh_seed_home must return 0 when DSH_HOME and DSH_BASE_URL are set (rc=$rc)"
[ -f "$HOME_DIR/profiles/headless.json" ] \
  || ac_fail "dsh_seed_home must write \$DSH_HOME/profiles/headless.json"
cmp -s "$SEED_DIR/profiles/headless.json" "$HOME_DIR/profiles/headless.json" \
  || ac_fail "headless.json must be a copy of the seed profile"
[ -f "$HOME_DIR/settings.yaml" ] \
  || ac_fail "dsh_seed_home must write \$DSH_HOME/settings.yaml"
grep -qF 'http://127.0.0.1:9/v1' "$HOME_DIR/settings.yaml" \
  || ac_fail "settings.yaml must contain DSH_BASE_URL (got: $(cat "$HOME_DIR/settings.yaml"))"

printf '%s\n' 'hand-edited' > "$HOME_DIR/settings.yaml"
rc="$(seed_call "$HOME_DIR" "http://127.0.0.1:9/v1")"
[ "$rc" = "0" ] \
  || ac_fail "a second dsh_seed_home must return 0 when the files already exist (rc=$rc)"
got="$(cat "$HOME_DIR/settings.yaml")"
[ "$got" = "hand-edited" ] \
  || ac_fail "a second dsh_seed_home must leave a hand-edited settings.yaml unchanged (got: $got)"

EMPTY_HOME="$TMP_DIR/empty-home"
mkdir -p "$EMPTY_HOME"
rc="$(seed_call "$EMPTY_HOME" "")"
[ "$rc" = "1" ] \
  || ac_fail "dsh_seed_home must return 1 when DSH_BASE_URL is empty (rc=$rc)"
if [ -n "$(find "$EMPTY_HOME" -mindepth 1 -print)" ]; then
  ac_fail "dsh_seed_home must write nothing when DSH_BASE_URL is empty (got: $(find "$EMPTY_HOME" -mindepth 1 -print))"
fi
ac_log "AC 3 OK"

ac_pass
