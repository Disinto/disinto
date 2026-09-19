#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1425.sh
#
# Issue #1425: docker/agents/entrypoint.sh chowns /home/agent/data to
# agent:agent at startup but never touches the tape mount at
# /srv/disinto/tape, which lands root-owned from the host volume (#1405).
# uid 1000 (agent) then cannot append records and lib/tape.sh
# warn-and-continues on every write.
#
# The fix (one file: docker/agents/entrypoint.sh) adds, next to the existing
# /home/agent/data chown:
#   if [ -d /srv/disinto/tape ]; then
#     chown agent:agent /srv/disinto/tape 2>/dev/null || true
#     chmod 0777 /srv/disinto/tape 2>/dev/null || true
#   fi
#
# This test locks in the entrypoint:
#   1. The tape mount is chowned to agent:agent NON-recursively (no -R —
#      payloads inside the mount keep whatever ownership they already have).
#   2. The tape mount is chmod'd to 0777 (the container uid need not match
#      the host uid; world-writable on a host volume the agent writes to).
#   3. Both commands live inside a [ -d /srv/disinto/tape ] guard, so a
#      missing mount does not abort the entrypoint under set -e, and both
#      carry `|| true` so a chown/chmod failure (like the nearby sweeps)
#      does not fail the script either.
#   4. The tape addition is exactly one guard + one chown + one chmod —
#      no other mounts or users are touched.
#
# Read-only: greps the entrypoint from the checkout.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ENTRYPOINT="$REPO_ROOT/docker/agents/entrypoint.sh"
ac_assert_file "$ENTRYPOINT" "docker/agents/entrypoint.sh must exist"

# ── 1. chown the tape mount to agent:agent, non-recursive ──────────────────
# Anchored on the exact `chown agent:agent /srv/disinto/tape` form so a
# recursive (`chown -R`) or differently-owned variant fails the test.
TAPE_CHOWN_LINE="$(grep -E '^[[:space:]]*chown[[:space:]]+agent:agent[[:space:]]+/srv/disinto/tape([[:space:]]|$)' "$ENTRYPOINT" | head -n1)"
[ -n "$TAPE_CHOWN_LINE" ] \
  || ac_fail "entrypoint must contain a directory-guarded 'chown agent:agent /srv/disinto/tape'"
case "$TAPE_CHOWN_LINE" in
  *" -R"*|*" -r"*|*--recursive*) ac_fail "the tape chown must not recurse — payloads inside the mount keep their existing ownership" ;;
esac
grep -Fq '|| true' <<<"$TAPE_CHOWN_LINE" \
  || ac_fail "the tape chown must tolerate failure with '|| true' (same as the nearby chowns)"

# ── 2. chmod 0777 the tape mount, non-recursive ────────────────────────────
TAPE_CHMOD_LINE="$(grep -E '^[[:space:]]*chmod[[:space:]]+0?777[[:space:]]+/srv/disinto/tape([[:space:]]|$)' "$ENTRYPOINT" | head -n1)"
[ -n "$TAPE_CHMOD_LINE" ] \
  || ac_fail "entrypoint must contain a directory-guarded 'chmod 0777 /srv/disinto/tape'"
grep -Fq '|| true' <<<"$TAPE_CHMOD_LINE" \
  || ac_fail "the tape chmod must tolerate failure with '|| true' (same as the nearby chowns)"

# ── 3. Both live inside the [ -d /srv/disinto/tape ] guard ─────────────────
# Collect the guarded block: from the line carrying the `[ -d /srv/disinto/tape ]`
# condition to its closing `fi`.
GUARDED_BLOCK="$(awk '
  /\[ -d \/srv\/disinto\/tape \][[:space:]]*;/ { inblock = 1; next }
  inblock {
    if ($0 ~ /^[[:space:]]*fi[[:space:]]*$/) exit
    buf = buf $0 ORS
  }
  END { printf "%s", buf }
' "$ENTRYPOINT")"
[ -n "$GUARDED_BLOCK" ] \
  || ac_fail "the tape chown/chmod must sit inside an 'if [ -d /srv/disinto/tape ]' guard — a missing mount must not abort the entrypoint"
grep -Fq 'chown agent:agent /srv/disinto/tape' <<<"$GUARDED_BLOCK" \
  || ac_fail "the tape chown must live inside the [ -d /srv/disinto/tape ] guard"
grep -Fq 'chmod 0777 /srv/disinto/tape' <<<"$GUARDED_BLOCK" \
  || ac_fail "the tape chmod must live inside the [ -d /srv/disinto/tape ] guard"

# ── 4. No other mounts or users change ─────────────────────────────────────
# The whole tape addition is exactly one guard line, one chown line, one
# chmod line: three non-comment lines naming /srv/disinto/tape, no more.
TAPE_LINE_COUNT="$(grep -v '^[[:space:]]*#' "$ENTRYPOINT" | grep -c '/srv/disinto/tape')"
ac_assert_eq "$TAPE_LINE_COUNT" "3" \
  "the tape change must be exactly the guard + chown + chmod (no other mounts or users touched)"

ac_pass
