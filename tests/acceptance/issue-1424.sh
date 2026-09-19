#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1424.sh
#
# Issue #1424: lib/tape.sh defaulted PAYLOAD_DIR to /srv/disinto/payloads,
# a path that is not a host_volume in any jobspec — tape_payload's
# `mkdir -p` + copy died inside the container. The tape volume is already
# mounted at /srv/disinto/tape, so the default must sit under it.
#
# Verifies (hermetic — no services, no state mutation):
#   1. With TAPE_DIR and PAYLOAD_DIR both UNSET, sourcing lib/tape.sh yields
#      PAYLOAD_DIR=/srv/disinto/tape/payloads (and TAPE_DIR=/srv/disinto/tape).
#   2. The env override still wins when PAYLOAD_DIR is pre-set (tests keep
#      their isolation path).
#
# Run via: tools/run-acceptance.sh 1424
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

TARGET="$REPO_ROOT/lib/tape.sh"
ac_assert_file "$TARGET" "lib/tape.sh must exist"

# ── 1. Unset both vars: the default is under the mounted tape volume ───────
OUT="$(unset TAPE_DIR PAYLOAD_DIR; source "$TARGET"; printf '%s\n' "$TAPE_DIR $PAYLOAD_DIR")" \
  || ac_fail "sourcing lib/tape.sh with both vars unset must succeed"

ac_assert_eq "$OUT" "/srv/disinto/tape /srv/disinto/tape/payloads" \
  "unset TAPE_DIR/PAYLOAD_DIR must default to /srv/disinto/tape /srv/disinto/tape/payloads"

# ── 2. Env override still wins (the test isolation path) ───────────────────
OUT="$(export PAYLOAD_DIR=/tmp/override-payloads; source "$TARGET"; printf '%s\n' "$PAYLOAD_DIR")" \
  || ac_fail "sourcing lib/tape.sh with PAYLOAD_DIR pre-set must succeed"
ac_assert_eq "$OUT" "/tmp/override-payloads" \
  "a pre-set PAYLOAD_DIR must survive sourcing lib/tape.sh"

# The source itself must not carry the old dead default.
if grep -Fq '/srv/disinto/payloads' "$TARGET"; then
  ac_fail "lib/tape.sh must not reference the old default /srv/disinto/payloads"
fi

ac_pass
