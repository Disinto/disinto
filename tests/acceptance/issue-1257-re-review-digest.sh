#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1257-re-review-digest.sh
#
# Issue #1257: re-reviews appended the FULL previous review body plus a
# second incremental diff (up to ~40KB extra) — the worst prompts in the
# system. The fix replaces full prior review bodies with compact digests
# (verdict + findings list per round, capped at DIGEST_CAP ≈ 2KB/round) and
# bounds the incremental diff at DIFF_THRESHOLD (12KB — the number this
# issue proposed for full diffs; #1256 landed it first, so it is reused).
#
# Acceptance (read-only — review_digest() and build_re_review_context() are
# extracted from the checkout with ac_extract_fn and run in-process against
# a synthetic git repo and synthetic forge comments; no live forge, no agent
# started — same approach as issue-1164):
#   1. a 3rd-round re-review prompt is bounded: with two prior rounds and a
#      small incremental diff, the re-review context stays within
#      2×(DIGEST_CAP + overhead) + the small diff + section text
#   2. the 3rd-round prompt references EVERY finding from EVERY prior round
#      — including a finding that the later round's review did not re-list
#      (a "dropped thread" is still referenced)
#   3. review_digest keeps the round's verdict line + every findings list
#      line and drops prose (summaries, posted footer)
#   4. a findings list larger than DIGEST_CAP is truncated with a note
#      pointing at the PR, and the digest stays bounded
#   5. an incremental diff above DIFF_THRESHOLD is not pasted (bounded by
#      diff_block, #1256 — 12KB)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk
ac_require_cmd jq
ac_require_cmd git

TARGET="$REPO_ROOT/review/review-pr.sh"
ac_assert_file "$TARGET" "review/review-pr.sh must exist"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Extract the functions under test from review-pr.sh ──────────────────────
# review-pr.sh is a top-level executable (sourcing it would run the whole
# review), so the functions are extracted by header (column-0 `name() {` to
# the next column-0 `}`) — the same approach as issue-1164.
for fn in review_digest build_re_review_context diff_block; do
  body="$(ac_extract_fn "$fn" "$TARGET")"
  [ -n "$body" ] || ac_fail "could not locate ${fn}() in review/review-pr.sh"
  eval "$body"
  type "$fn" >/dev/null 2>&1 || ac_fail "${fn}() did not evaluate to a function"
done

# Constants the extracted functions read (must match review-pr.sh).
grep -q '^DIFF_THRESHOLD=12000$' "$TARGET" \
  || ac_fail "review-pr.sh must keep DIFF_THRESHOLD=12000 (the 12KB bound #1257 proposed; #1256 landed it)"
DIGEST_CAP="$(grep -oP '^DIGEST_CAP=\K[0-9]+' "$TARGET" || true)"
[ -n "$DIGEST_CAP" ] || ac_fail "review-pr.sh must define DIGEST_CAP"
# shellcheck disable=SC2034 # consumed by the extracted functions, not this file
DIFF_THRESHOLD=12000

# Stubs for the calls the functions make (no network, no real log).
log() { :; }
forge_api_all() { :; }

# ── Synthetic git repo: 3 review rounds (commits A → B → C) ─────────────────
REPO="$TMP_DIR/repo"
git init -q "$REPO"
git -C "$REPO" config user.email review@test
git -C "$REPO" config user.name review-test
cd "$REPO"
echo 1 > f.txt
git add f.txt
git commit -qm "round 1"
SHA_A=$(git rev-parse HEAD)
echo 2 >> f.txt
git commit -qam "round 2"
SHA_B=$(git rev-parse HEAD)
echo 3 >> f.txt
git commit -qam "round 3"
SHA_C=$(git rev-parse HEAD)

# Bare "remote" so `git fetch <remote> <branch>` inside the function works.
BARE="$TMP_DIR/bare.git"
git init -q --bare "$BARE"
git push -q "$BARE" "HEAD:refs/heads/pr-1257"

# ── Synthetic forge comments (the exact shape review-pr.sh posts) ───────────
# Round 1 (at SHA_A): two findings + prose that must NOT reach the digest.
BODY_A=$(printf '## AI Review\n<!-- reviewed: %s -->\n\n### Summary\nRound one. Long prose about the change that must not appear in the digest at all, and must not count toward the cap.\n\n### Findings\n- **high** `lib/foo.sh:42`: unquoted variable under set -u\n- **medium** `docker/entrypoint.sh:10`: missing restart policy\n\n### Verdict\n**REQUEST_CHANGES** — two real issues\n\n---\n*Reviewed at `%s` | [AGENTS.md](AGENTS.md)*' \
  "$SHA_A" "${SHA_A:0:7}")

# Round 2 (at SHA_B): re-lists ONLY the first finding — the second one was
# "dropped" from the later review. That thread must still reach the 3rd
# round, because every round is digested independently.
BODY_B=$(printf '## AI Re-review (round 2)\n<!-- reviewed: %s -->\n\n### Previous Findings\n- unquoted variable under set -u → FIXED\n\n### New Issues\n- **low** `lib/foo.sh:88`: dead debug printf\n\n### Verdict\n**REQUEST_CHANGES** — one new issue\n\n---\n*Reviewed at `%s` | Previous: `%s` | [AGENTS.md](AGENTS.md)*' \
  "$SHA_B" "${SHA_B:0:7}" "${SHA_A:0:7}")

# SC2034: consumed by the extracted functions (eval'd), not by this file.
# shellcheck disable=SC2034
ALL_COMMENTS=$(jq -n --arg a "$BODY_A" --arg b "$BODY_B" '[
  {id: 1, body: $a},
  {id: 2, body: $b}
]')

# Globals build_re_review_context() needs (review-pr.sh sets them at startup).
# shellcheck disable=SC2034
PROJECT_REPO_ROOT="$REPO"
# shellcheck disable=SC2034
FORGE_REMOTE="$BARE"
# shellcheck disable=SC2034
PR_HEAD="pr-1257"
# shellcheck disable=SC2034
PR_SHA="$SHA_C"
# shellcheck disable=SC2034
REVIEW_TMPDIR="$TMP_DIR"
# shellcheck disable=SC2034
WORKTREE="$TMP_DIR/worktree"

# ── 1+2. 3rd-round re-review: bounded, every prior finding referenced ───────
build_re_review_context
[ "$IS_RE_REVIEW" = true ] || ac_fail "two prior review rounds must set IS_RE_REVIEW=true"
[ "$PREV_SHA" = "$SHA_B" ] \
  || ac_fail "PREV_SHA must be the most recent prior review (${SHA_B:0:7}), got ${PREV_SHA:0:7}"

ROUND1_HDR="### Round 1 — reviewed \`${SHA_A:0:7}\`"
ROUND2_HDR="### Round 2 — reviewed \`${SHA_B:0:7}\`"
case "$PREV_CONTEXT" in
  *"$ROUND1_HDR"*"$ROUND2_HDR"*) ;;
  *) ac_fail "both prior rounds must be digested (headers missing), got: $PREV_CONTEXT" ;;
esac
# Every finding of every prior round — including the one round 2 did not
# re-list (no dropped threads).
case "$PREV_CONTEXT" in *"lib/foo.sh:42"*) ;; *)
  ac_fail "round-1 finding (dropped by the later review) must still be referenced" ;; esac
case "$PREV_CONTEXT" in *"docker/entrypoint.sh:10"*) ;; *)
  ac_fail "round-1 finding 2 must be referenced" ;; esac
case "$PREV_CONTEXT" in *"lib/foo.sh:88"*) ;; *)
  ac_fail "round-2 new finding must be referenced" ;; esac
VERD1='**REQUEST_CHANGES** — two real issues'
VERD2='**REQUEST_CHANGES** — one new issue'
case "$PREV_CONTEXT" in
  *"$VERD1"*"$VERD2"*) ;;
  *) ac_fail "both verdicts must be digested, got: $PREV_CONTEXT" ;;
esac
# Prose must NOT be in the context (digests, not full bodies).
case "$PREV_CONTEXT" in
  *"must not appear in the digest"*)
    ac_fail "prose from the full review body must not reach the re-review prompt" ;;
esac
case "$PREV_CONTEXT" in *"Reviewed at"*)
  ac_fail "the posted footer must not reach the re-review prompt" ;;
esac
# The small incremental diff (B..C) is pasted in full by diff_block.
case "$PREV_CONTEXT" in *"Incremental Diff"*) ;;
  *) ac_fail "the incremental diff section must be present" ;; esac
case "$PREV_CONTEXT" in *'+3'*) ;;
  *) ac_fail "the small incremental diff must be pasted in full, got: $PREV_CONTEXT" ;;
esac
# Bounded: the context is at most the two digest caps + verdicts + the
# incremental diff + fixed section overhead — NOT the two full review bodies.
CTX_SIZE=$(printf '%s' "$PREV_CONTEXT" | wc -c | tr -d '[:space:]')
MAX=$(( 2 * (DIGEST_CAP + 256) + 1536 ))
[ "$CTX_SIZE" -le "$MAX" ] \
  || ac_fail "3rd-round re-review context must be bounded (≤ ${MAX} bytes), got ${CTX_SIZE}"

# ── 3. digest keeps verdict + every findings line, drops prose ──────────────
DIGEST_A=$(review_digest "$BODY_A")
case "$DIGEST_A" in *"**REQUEST_CHANGES** — two real issues"*) ;;
  *) ac_fail "digest must keep the verdict line, got: $DIGEST_A" ;; esac
case "$DIGEST_A" in *"lib/foo.sh:42"*"docker/entrypoint.sh:10"*) ;;
  *) ac_fail "digest must keep every findings list line, got: $DIGEST_A" ;; esac
case "$DIGEST_A" in *"### Findings"*) ;;
  *) ac_fail "digest must keep section headings (structure), got: $DIGEST_A" ;;
esac
case "$DIGEST_A" in *"must not appear in the digest"*)
  ac_fail "digest must drop prose (summaries), got: $DIGEST_A" ;; esac
case "$DIGEST_A" in *"Reviewed at"*)
  ac_fail "digest must drop the posted footer, got: $DIGEST_A" ;; esac

# ── 4. findings above DIGEST_CAP are truncated with a note, stay bounded ───
BIG_MD=""
for n in $(seq 1 40); do
  BIG_MD="${BIG_MD}- **medium** \`lib/file${n}.sh:$(( n * 10 ))\`: synthetic finding number ${n} to push the digest over the cap
"
done
BODY_BIG=$(printf '## AI Review\n<!-- reviewed: %s -->\n\n%s\n### Verdict\n**REQUEST_CHANGES** — too many issues\n\n---\n*Reviewed at `%s` | [AGENTS.md](AGENTS.md)*' \
  "$SHA_A" "$BIG_MD" "${SHA_A:0:7}")
DIGEST_BIG=$(review_digest "$BODY_BIG")
case "$DIGEST_BIG" in *"truncated at ${DIGEST_CAP} bytes"*) ;;
  *) ac_fail "over-cap digest must carry the truncation note, got: $DIGEST_BIG" ;; esac
case "$DIGEST_BIG" in *"lib/file1.sh:10"*) ;;
  *) ac_fail "truncated digest must keep the earliest findings, got: $DIGEST_BIG" ;; esac
case "$DIGEST_BIG" in *"lib/file40.sh:400"*)
  ac_fail "truncated digest must drop the tail findings, got: $DIGEST_BIG" ;; esac
BIG_SIZE=$(printf '%s' "$DIGEST_BIG" | wc -c | tr -d '[:space:]')
# verdict line + findings ≤ DIGEST_CAP + the truncation note.
[ "$BIG_SIZE" -le $(( DIGEST_CAP + 256 )) ] \
  || ac_fail "truncated digest must stay bounded (≤ $(( DIGEST_CAP + 256 )) bytes), got ${BIG_SIZE}"

# ── 5. incremental diff above DIFF_THRESHOLD is not pasted (#1256) ──────────
# 300 × ~62B ≈ 18.6KB > DIFF_THRESHOLD (12KB); single process (no SIGPIPE).
printf 'filler line with padding so the incremental diff exceeds the bound\n%.0s' \
  $(seq 300) > big.txt
git add big.txt
git commit -qm "round 4"
# shellcheck disable=SC2034
PR_SHA=$(git rev-parse HEAD)
build_re_review_context
[ "$IS_RE_REVIEW" = true ] || ac_fail "re-review detection must hold for the 4th round"
case "$PREV_CONTEXT" in *"not pasted, read it locally"*) ;;
  *) ac_fail "large incremental diff must be referenced, not pasted, got: $PREV_CONTEXT" ;;
esac
case "$PREV_CONTEXT" in *"filler line with padding"*)
  ac_fail "large incremental diff content must not be pasted into the prompt" ;;
esac

ac_pass
