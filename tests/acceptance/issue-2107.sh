#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2107.sh
#
# Issue #2107: docker/agents/entrypoint.sh gives each agent job its own factory
# ref (FACTORY_REF, default: the primary branch) and its own checkout when
# FACTORY_CHECKOUT is set.  Before each poll the entrypoint resets the job's
# factory checkout to the ref, but only when that ref is a commit of the
# primary branch; otherwise it keeps the current checkout.
#
# ACs:
#   1. FACTORY_REF unset, PRIMARY_BRANCH=main: factory_reset returns 0 and the
#      clone's HEAD is main's head.
#   2. FACTORY_REF=canary (canary at main's first commit): HEAD is that commit.
#   3. A third commit pushed to canary only (not on main), FACTORY_REF=canary:
#      factory_reset returns non-zero and HEAD is unchanged.
#   4. grep -cF 'DISINTO_LIVE="${FACTORY_CHECKOUT:-/home/agent/repos/_factory}"'
#      docker/agents/entrypoint.sh prints 1.
#   5. bash -n docker/agents/entrypoint.sh passes.
#
# Hermetic: a local bare repo is the origin (never the forge); gosu() is
# stubbed as `gosu() { shift; "$@"; }` and log() as a no-op.  factory_ref and
# factory_reset are extracted with ac_extract_fn and eval'd in a subshell.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash git awk mktemp grep
ENTRYPOINT="$REPO_ROOT/docker/agents/entrypoint.sh"
ac_assert_file "$ENTRYPOINT" "docker/agents/entrypoint.sh must exist"

REF_SRC="$(ac_extract_fn factory_ref "$ENTRYPOINT")"
[ -n "$REF_SRC" ] || ac_fail "could not extract factory_ref() from the entrypoint"
RESET_SRC="$(ac_extract_fn factory_reset "$ENTRYPOINT")"
[ -n "$RESET_SRC" ] || ac_fail "could not extract factory_reset() from the entrypoint"

# ── Hermetic git fixture: bare origin + main (2 commits) + canary at main^ ──
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ORIGIN="$TMP_DIR/origin"
git init --quiet --bare "$ORIGIN"

WORK="$TMP_DIR/work"
git init --quiet "$WORK"
git -C "$WORK" config user.email ac@example.com
git -C "$WORK" config user.name acceptance
git -C "$WORK" remote add origin "$ORIGIN"
git -C "$WORK" checkout -q -B main
printf 'one\n' > "$WORK/file.txt"
git -C "$WORK" add -A
git -C "$WORK" commit -q -m "commit 1"
COMMIT1="$(git -C "$WORK" rev-parse HEAD)"
printf 'two\n' >> "$WORK/file.txt"
git -C "$WORK" add -A
git -C "$WORK" commit -q -m "commit 2"
COMMIT2="$(git -C "$WORK" rev-parse HEAD)"
git -C "$WORK" push -q origin main
git -C "$WORK" branch -q canary "$COMMIT1"
git -C "$WORK" push -q origin canary

LIVE="$TMP_DIR/live"
git clone -q "$ORIGIN" "$LIVE"

# run_factory_reset <ref-or-empty> — run the extracted factory_reset against
# $LIVE with the entrypoint's gosu/env pattern stubbed.
run_factory_reset() {
  REF="$1" LIVE_DIR="$LIVE" REF_SRC="$REF_SRC" RESET_SRC="$RESET_SRC" \
  bash -c '
    set -u
    eval "$REF_SRC"
    eval "$RESET_SRC"
    gosu() { shift; "$@"; }
    log() { :; }
    DISINTO_LIVE="$LIVE_DIR"
    PRIMARY_BRANCH=main
    FACTORY_REF="$REF"
    factory_reset
  '
}

head_of_live() { git -C "$LIVE" rev-parse HEAD; }

# ── AC1: no ref set — reset returns 0, HEAD is main's head ───────────────────
if ! run_factory_reset ""; then
  ac_fail "AC1: factory_reset must return 0 when FACTORY_REF is unset"
fi
ac_assert_eq "$(head_of_live)" "$COMMIT2" "AC1: HEAD must be main's head"
ac_log "AC1: FACTORY_REF unset -> HEAD is main's head"

# ── AC2: FACTORY_REF=canary (ancestor of main) — HEAD is that commit ─────────
if ! run_factory_reset canary; then
  ac_fail "AC2: factory_reset must return 0 when canary is a commit of main"
fi
ac_assert_eq "$(head_of_live)" "$COMMIT1" "AC2: HEAD must be main's first commit"
ac_log "AC2: FACTORY_REF=canary -> HEAD is main's first commit"

# ── AC3: canary diverges — the ref is refused, HEAD unchanged ─────────────────
git -C "$WORK" checkout -q canary
printf 'three\n' >> "$WORK/file.txt"
git -C "$WORK" add -A
git -C "$WORK" commit -q -m "commit 3 (canary only)"
git -C "$WORK" push -q origin canary
BEFORE="$(head_of_live)"
if run_factory_reset canary; then
  ac_fail "AC3: factory_reset must fail when FACTORY_REF is not a commit of the primary branch"
fi
ac_assert_eq "$(head_of_live)" "$BEFORE" "AC3: HEAD must be unchanged when the ref is refused"
ac_log "AC3: divergent FACTORY_REF=canary -> factory_reset returned non-zero, HEAD unchanged"

# ── AC4: the FACTORY_CHECKOUT seam is present exactly once ───────────────────
# AC4: the single quotes are deliberate — the grep pattern is a literal.
# shellcheck disable=SC2016
count="$(grep -cF 'DISINTO_LIVE="${FACTORY_CHECKOUT:-/home/agent/repos/_factory}"' "$ENTRYPOINT" || true)"
ac_assert_eq "$count" "1" "AC4: the FACTORY_CHECKOUT seam must appear exactly once in the entrypoint"
ac_log "AC4: FACTORY_CHECKOUT seam present exactly once"

# ── AC5: the entrypoint still parses ──────────────────────────────────────────
bash -n "$ENTRYPOINT" \
  || ac_fail "AC5: bash -n failed on docker/agents/entrypoint.sh"
ac_log "AC5: bash -n passes on docker/agents/entrypoint.sh"

ac_log "issue-2107 acceptance: all 5 ACs passed"
