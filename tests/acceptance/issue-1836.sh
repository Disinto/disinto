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
#   4. (#2009) DSH_PROVIDER selects the settings template, defaulting to
#      llamacpp when unset; an invalid or template-less provider warns on
#      stderr and seeds no settings.yaml.
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
printf '%s\n' 'provider: xai' > "$SEED_DIR/settings-xai.yaml"

# seed_call — source the helper in a fresh shell so a return 1 cannot trip
# this test's set -e, and so a prior call cannot leak files into the next.
# Args: <home> <url> [provider]; an empty provider means DSH_PROVIDER unset.
# stderr lands in ERR_LOG.
ERR_LOG="$TMP_DIR/seed-err.log"
seed_call() {
  local home="$1"
  local url="${2-}"
  local provider="${3-}"
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
if [ -n "$provider" ]; then
  export DSH_PROVIDER="$provider"
else
  unset DSH_PROVIDER
fi
# shellcheck source=lib/dsh-seed.sh
source "$SEED_LIB"
dsh_seed_home
EOF
  rc=0
  bash "$driver" 2>"$ERR_LOG" || rc=$?
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

# ── 4. DSH_PROVIDER selects the settings template (#2009) ────────────────────
ac_log "AC 4: DSH_PROVIDER selects the template, defaulting to llamacpp"
P_HOME="$TMP_DIR/provider-home"
mkdir -p "$P_HOME"
rc="$(seed_call "$P_HOME" "http://127.0.0.1:9/v1" "")"
[ "$rc" = "0" ] \
  || ac_fail "unset DSH_PROVIDER must seed the llamacpp template (rc=$rc, stderr: $(cat "$ERR_LOG"))"
expected_llamacpp="$(sed 's|__DSH_BASE_URL__|http://127.0.0.1:9/v1|' "$SEED_DIR/settings-llamacpp.yaml")"
ac_assert_eq "$(cat "$P_HOME/settings.yaml")" "$expected_llamacpp" \
  "AC 4: unset DSH_PROVIDER must seed the llamacpp template with DSH_BASE_URL substituted"

XAI_HOME="$TMP_DIR/xai-home"
mkdir -p "$XAI_HOME"
rc="$(seed_call "$XAI_HOME" "http://127.0.0.1:9/v1" "xai")"
[ "$rc" = "0" ] \
  || ac_fail "DSH_PROVIDER=xai must return 0 (rc=$rc, stderr: $(cat "$ERR_LOG"))"
cmp -s "$XAI_HOME/settings.yaml" "$SEED_DIR/settings-xai.yaml" \
  || ac_fail "DSH_PROVIDER=xai must seed the xai template (got: $(cat "$XAI_HOME/settings.yaml"))"

BAD_HOME="$TMP_DIR/bad-home"
mkdir -p "$BAD_HOME"
rc="$(seed_call "$BAD_HOME" "http://127.0.0.1:9/v1" "nope")"
[ "$rc" = "0" ] \
  || ac_fail "a template-less DSH_PROVIDER must warn but not fail (rc=$rc)"
[ ! -f "$BAD_HOME/settings.yaml" ] \
  || ac_fail "DSH_PROVIDER=nope must not seed settings.yaml (got: $(cat "$BAD_HOME/settings.yaml"))"
grep -q 'DSH_PROVIDER' "$ERR_LOG" \
  || ac_fail "stderr must name DSH_PROVIDER (got: $(cat "$ERR_LOG"))"

PATH_HOME="$TMP_DIR/path-home"
mkdir -p "$PATH_HOME"
seed_call "$PATH_HOME" "http://127.0.0.1:9/v1" "../x" >/dev/null
[ ! -f "$PATH_HOME/settings.yaml" ] \
  || ac_fail "DSH_PROVIDER=../x must not seed settings.yaml (got: $(cat "$PATH_HOME/settings.yaml"))"
grep -q 'DSH_PROVIDER' "$ERR_LOG" \
  || ac_fail "stderr must name DSH_PROVIDER for a path-shaped provider (got: $(cat "$ERR_LOG"))"
ac_log "AC 4 OK"

ac_pass
