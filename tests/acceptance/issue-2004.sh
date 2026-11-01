#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2004.sh
#
# Issue #2004: seed settings.yaml from the template DSH_PROVIDER names.
#
# docker/agents/entrypoint.sh seeds a missing $DSH_HOME/settings.yaml from
# ${DSH_SEED_DIR:-/opt/dsh}/settings-<DSH_PROVIDER>.yaml (default llamacpp),
# with __DSH_BASE_URL__ replaced by DSH_BASE_URL. A DSH_PROVIDER that is not
# a plain [a-z0-9-] name, or whose template is missing, warns on stderr and
# seeds nothing. An existing settings.yaml is never overwritten.
#
# The test extracts the seeding block from the entrypoint with the shared
# ac_dsh_seed_block helper and runs it in a throwaway subshell with DSH_HOME and
# DSH_SEED_DIR in temp dirs holding fake templates from ac_dsh_seed_fixtures.
# No docker, no network.
#
# Run via: tools/run-acceptance.sh 2004
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash sed cmp

# The seeding-block extractor and the fake provider templates are shared helpers
# in tests/lib/acceptance-helpers.sh (issue-2010.sh uses the same pair), so
# neither is copy-pasted into each test (duplicate-detection, #1134).
BLOCK="$(ac_dsh_seed_block "$REPO_ROOT/docker/agents/entrypoint.sh")"
[ -n "$BLOCK" ] || ac_fail "could not extract the seeding block from docker/agents/entrypoint.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
ac_dsh_seed_fixtures "$TMP_DIR"

# run_block <home-dir> <provider> — run the extracted block with an empty
# provider meaning unset. Exit status lands in run_rc, stderr in err.log.
run_block() {
  local home="$1" provider="$2"
  mkdir -p "$home"
  run_rc=0
  if [ -z "$provider" ]; then
    DSH_HOME="$home" DSH_SEED_DIR="$TMP_DIR" DSH_BASE_URL="http://x/v1" \
      bash -c "$BLOCK" >/dev/null 2>"$TMP_DIR/err.log" || run_rc=$?
  else
    DSH_HOME="$home" DSH_SEED_DIR="$TMP_DIR" DSH_BASE_URL="http://x/v1" DSH_PROVIDER="$provider" \
      bash -c "$BLOCK" >/dev/null 2>"$TMP_DIR/err.log" || run_rc=$?
  fi
}

ac_log "AC1: DSH_PROVIDER unset seeds the llamacpp template with DSH_BASE_URL substituted"
run_block "$TMP_DIR/home1" ""
ac_assert_eq "$run_rc" "0" "AC1: seeding block exited $run_rc (stderr: $(cat "$TMP_DIR/err.log"))"
ac_assert_file "$TMP_DIR/home1/settings.yaml" "AC1: settings.yaml was not seeded"
expected="$(sed 's|__DSH_BASE_URL__|http://x/v1|' "$TMP_DIR/settings-llamacpp.yaml")"
ac_assert_eq "$(cat "$TMP_DIR/home1/settings.yaml")" "$expected" \
  "AC1: settings.yaml must equal the llamacpp seed with the placeholder replaced by http://x/v1"

ac_log "AC2: DSH_PROVIDER=xai seeds the xai template unchanged"
run_block "$TMP_DIR/home2" "xai"
ac_assert_eq "$run_rc" "0" "AC2: seeding block exited $run_rc (stderr: $(cat "$TMP_DIR/err.log"))"
cmp -s "$TMP_DIR/home2/settings.yaml" "$TMP_DIR/settings-xai.yaml" \
  || ac_fail "AC2: settings.yaml must be a byte-identical copy of the xai template"

ac_log "AC3: a malformed DSH_PROVIDER seeds nothing and warns on stderr"
run_block "$TMP_DIR/home3" "nope"
[ -f "$TMP_DIR/home3/settings.yaml" ] \
  && ac_fail "AC3: DSH_PROVIDER=nope must not seed settings.yaml"
grep -q 'DSH_PROVIDER' "$TMP_DIR/err.log" \
  || ac_fail "AC3: stderr must name DSH_PROVIDER (got: $(cat "$TMP_DIR/err.log"))"

ac_log "AC4: a path-shaped DSH_PROVIDER seeds nothing and warns on stderr"
run_block "$TMP_DIR/home4" "../x"
[ -f "$TMP_DIR/home4/settings.yaml" ] \
  && ac_fail "AC4: DSH_PROVIDER=../x must not seed settings.yaml"
grep -q 'DSH_PROVIDER' "$TMP_DIR/err.log" \
  || ac_fail "AC4: stderr must name DSH_PROVIDER (got: $(cat "$TMP_DIR/err.log"))"

ac_log "AC5: an existing settings.yaml is left byte-identical"
mkdir -p "$TMP_DIR/home5"
printf 'operator customisation\n' > "$TMP_DIR/home5/settings.yaml"
run_block "$TMP_DIR/home5" ""
cmp -s "$TMP_DIR/home5/settings.yaml" <(printf 'operator customisation\n') \
  || ac_fail "AC5: an existing settings.yaml must never be overwritten"

ac_log "AC6: bash -n passes and issue-1682 still passes"
bash -n "$REPO_ROOT/docker/agents/entrypoint.sh" || ac_fail "bash -n docker/agents/entrypoint.sh failed"
rc1682=0
out1682="$(bash "$REPO_ROOT/tests/acceptance/issue-1682.sh")" || rc1682=$?
ac_assert_eq "$rc1682" "0" "issue-1682.sh must still pass (got: $out1682)"

ac_pass
