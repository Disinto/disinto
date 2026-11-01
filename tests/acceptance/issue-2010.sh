#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2010.sh
#
# Issue #2010: docker/agents/entrypoint.sh seeded $DSH_HOME/settings.yaml with
# `sed ... > "$dsh_home/settings.yaml"` and never created $dsh_home. The
# entrypoint runs under `set -euo pipefail`, so a custom DSH_HOME that does not
# exist yet (a Nomad host-volume path, a mount that failed to init) made the
# redirect fail, aborted the entrypoint, and the organ never reached its poll
# loop. lib/dsh-seed.sh already does `mkdir -p "$DSH_HOME"` before the same
# write; the entrypoint now does the same, and hands the fresh directory to the
# agent user (it runs as root under umask 077).
#
# The seeding block comes from the shared ac_dsh_seed_block helper (issue-2004
# uses it too) and is run in a throwaway subshell under the entrypoint's own
# errexit context. No docker, no network.
#
# Run via: tools/run-acceptance.sh 2010
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep awk cmp
SEED_BLOCK="$(ac_dsh_seed_block "$REPO_ROOT/docker/agents/entrypoint.sh")"
[ -n "$SEED_BLOCK" ] || ac_fail "could not extract the seeding block from docker/agents/entrypoint.sh"

# ── AC1: the mkdir of the home sits before the settings.yaml redirect ────────
ac_log "AC1: a guarded mkdir of the DSH_HOME precedes the settings.yaml write"
mkdir_line="$(grep -n "mkdir -p \"\$dsh_home\"" <<< "$SEED_BLOCK" | head -n1 | cut -d: -f1)"
sed_line="$(grep -n "> \"\$dsh_home/settings.yaml\"" <<< "$SEED_BLOCK" | head -n1 | cut -d: -f1)"
[ -n "$mkdir_line" ] || ac_fail "AC1: the seeding block must mkdir the DSH_HOME before writing into it"
[ -n "$sed_line" ] || ac_fail "AC1: the seeding block must contain the settings.yaml redirect"
[ "$mkdir_line" -lt "$sed_line" ] \
  || ac_fail "AC1: the mkdir (line $mkdir_line) must precede the settings.yaml redirect (line $sed_line)"
grep -q "mkdir -p \"\$dsh_home\" 2>/dev/null || true" "$REPO_ROOT/docker/agents/entrypoint.sh" \
  || ac_fail "AC1: the mkdir must be guarded so an unwritable mount cannot abort the entrypoint"
chown_line="$(grep -n "chown agent:agent \"\$dsh_home\"" <<< "$SEED_BLOCK" | head -n1 | cut -d: -f1)"
[ -n "$chown_line" ] \
  || ac_fail "AC1: a freshly created DSH_HOME must be handed to the agent user (the entrypoint runs as root)"
[ "$chown_line" -lt "$sed_line" ] \
  || ac_fail "AC1: the chown (line $chown_line) must precede the settings.yaml redirect (line $sed_line)"

# run_seed_block <home-dir> <provider> — run the block with the entrypoint's
# errexit context; an empty provider means DSH_PROVIDER is unset. Exit status
# lands in run_rc, stderr in err.log.
run_seed_block() {
  local home="$1" provider="$2"
  run_rc=0
  if [ -n "$provider" ]; then
    DSH_HOME="$home" DSH_SEED_DIR="$TMP_DIR" DSH_BASE_URL="http://x/v1" DSH_PROVIDER="$provider" \
      bash -c 'set -euo pipefail; '"$SEED_BLOCK" >/dev/null 2>"$TMP_DIR/err.log" || run_rc=$?
  else
    DSH_HOME="$home" DSH_SEED_DIR="$TMP_DIR" DSH_BASE_URL="http://x/v1" \
      bash -c 'set -euo pipefail; '"$SEED_BLOCK" >/dev/null 2>"$TMP_DIR/err.log" || run_rc=$?
  fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
ac_dsh_seed_fixtures "$TMP_DIR"

ac_log "AC2: a DSH_HOME that does not exist yet is created and seeded, exit 0"
run_seed_block "$TMP_DIR/x/a/b" ""
ac_assert_eq "$run_rc" "0" "AC2: seeding into a missing dir exited $run_rc (stderr: $(cat "$TMP_DIR/err.log"))"
ac_assert_file "$TMP_DIR/x/a/b/settings.yaml" "AC2: settings.yaml must be seeded into the created DSH_HOME"
want_llamacpp="$(sed 's|__DSH_BASE_URL__|http://x/v1|' "$TMP_DIR/settings-llamacpp.yaml")"
ac_assert_eq "$(cat "$TMP_DIR/x/a/b/settings.yaml")" "$want_llamacpp" \
  "AC2: settings.yaml must equal the llamacpp seed with the placeholder replaced"

ac_log "AC3: a nested missing DSH_HOME still seeds the provider DSH_PROVIDER names"
run_seed_block "$TMP_DIR/y/z" "xai"
ac_assert_eq "$run_rc" "0" "AC3: seeding into a missing dir exited $run_rc (stderr: $(cat "$TMP_DIR/err.log"))"
cmp -s "$TMP_DIR/y/z/settings.yaml" "$TMP_DIR/settings-xai.yaml" \
  || ac_fail "AC3: settings.yaml must be a byte-identical copy of the xai template"

ac_log "AC4: an existing settings.yaml is left byte-identical"
mkdir -p "$TMP_DIR/custom"
printf 'operator customisation\n' > "$TMP_DIR/custom/settings.yaml"
run_seed_block "$TMP_DIR/custom" ""
cmp -s "$TMP_DIR/custom/settings.yaml" <(printf 'operator customisation\n') \
  || ac_fail "AC4: an existing settings.yaml must never be overwritten"

ac_log "AC5: a malformed DSH_PROVIDER on a missing DSH_HOME warns, seeds nothing, exit 0"
run_seed_block "$TMP_DIR/bad/home" "../x"
ac_assert_eq "$run_rc" "0" "AC5: an invalid provider must warn, not abort (exit $run_rc, stderr: $(cat "$TMP_DIR/err.log"))"
[ ! -f "$TMP_DIR/bad/home/settings.yaml" ] \
  || ac_fail "AC5: DSH_PROVIDER=../x must not seed settings.yaml"
grep -q 'DSH_PROVIDER' "$TMP_DIR/err.log" \
  || ac_fail "AC5: stderr must name DSH_PROVIDER (got: $(cat "$TMP_DIR/err.log"))"

ac_log "AC6: bash -n passes, issue-2004 still passes, and no pinned default is set here"
bash -n "$REPO_ROOT/docker/agents/entrypoint.sh" \
  || ac_fail "bash -n docker/agents/entrypoint.sh failed"
rc2004=0
out2004="$(bash "$REPO_ROOT/tests/acceptance/issue-2004.sh")" || rc2004=$?
ac_assert_eq "$rc2004" "0" "issue-2004.sh must still pass (got: $out2004)"

for pinned in DSH_CONTEXT_WINDOW CLAUDE_TIMEOUT MAX_DIFF DIFF_THRESHOLD DIGEST_CAP; do
  assigned="$(grep -c "$pinned=" "$REPO_ROOT/docker/agents/entrypoint.sh" || true)"
  ac_assert_eq "$assigned" "0" \
    "AC6: docker/agents/entrypoint.sh must not assign the pinned default $pinned (#1261)"
done

ac_pass
