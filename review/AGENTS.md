<!-- last-reviewed: e5360777096d323ba88086ae26726842d7e2e3ae -->
# Review Agent

**Role**: AI-powered PR review — post structured findings and formal
approve/request-changes verdicts to forge.

**Trigger**: `review-poll.sh` is invoked by the polling loop in `docker/agents/entrypoint.sh`
every 5 minutes (iteration math at line 163-167). It scans open PRs whose CI has passed and
that lack a review for the current HEAD SHA, then spawns `review-pr.sh <pr-number>`.

**Key files**:
- `review/review-poll.sh` — Polling loop participant: finds unreviewed PRs with passing CI.
Invoked by `docker/agents/entrypoint.sh` every 5 minutes. Sources `lib/guard.sh` and calls
`check_active reviewer` — skips if `$FACTORY_ROOT/state/.reviewer-active` is absent.
**Circuit breaker**: counts existing `<!-- review-error: <sha> -->` comments; skips a PR
if ≥3 consecutive errors for the same HEAD SHA (prevents flooding on repeated review failures).
- `review/review-pr.sh` — Polling loop participant: Creates/reuses a tmux session
(`review-{project}-{pr}`), injects PR diff, waits for Claude to write structured JSON output,
posts markdown review + formal forge review, auto-creates follow-up issues for pre-existing
tech debt. **cd at startup**: changes to `$PROJECT_REPO_ROOT` early in the script — before
any git commands — because the factory root is not a git repo after image rebuild (#408).
Calls `resolve_forge_remote()` at startup to determine the correct git remote name (avoids
hardcoded 'origin'). (The former per-PR structural-graph step — running
`lib/build-graph.py --changed-files` and appending a JSON structural analysis to the
prompt — was removed in #1258: the project root holds no objective/prerequisite
sources (they live in the ops repo), so the report carried no PR-relevant content,
the formula never referenced the section, and in-container it was a ~527B stub.)
**Acceptance test checking**: if the issue has an `## Acceptance test`
section, the reviewer verifies commands reference correct file paths/schema, expected output
matches actual behavior, and flags `needs-deploy-verification` for live-box-only commands.
**Diff threshold (#1256)**: the fetch-diff step saves the PR diff to a temp file and
records its size. At prompt assembly (`diff_block`), diffs ≤ `DIFF_THRESHOLD` (12KB) are
pasted in full — the common case, no extra round-trips. Larger diffs are NOT pasted:
the prompt keeps the "Changed Files" list (always pasted) and adds the worktree path
(`REVIEW_WORKTREE`, checked out at the PR head) plus the exact git command
(`git diff <merge-base>..HEAD` for full diffs, `git diff <prev-sha>..<pr-sha>` for
re-review incremental diffs) so the agent reads the diff/files locally. This keeps file
coverage intact under auto-compaction, which can compact away a pasted 25KB diff mid-review
(#1260). The old truncated paste (capped at `MAX_DIFF`) remains only as a fallback when
the PR's base ref cannot be fetched (merge-base unavailable).
**Re-review context budget (#1257)**: prior review rounds are injected as compact
digests instead of full review bodies — `review_digest` in `review-pr.sh` keeps each
round's verdict line + findings list (list items and section headings of the review
markdown), capped at `DIGEST_CAP` (2KB) per round, with a truncation note pointing at
the PR comments. Findings in the posted review are list items (formula section 9), so
every finding line of a round survives the digest: a 3rd-round re-review still sees
every finding from every prior round (no dropped threads) while the prompt stays
bounded. `build_re_review_context` digests EVERY prior round (not just the last) and
bounds the incremental diff (most recently reviewed SHA → head) through `diff_block`
at `DIFF_THRESHOLD` (12KB — the number #1257 proposed for full diffs; #1256 landed
it first, so it is reused).
**Stale-base regression check (#896)**: before assembling the prompt, calls `stale_base_check`
from `lib/stale-base-check.sh` to detect PRs whose merged result would silently revert upstream
changes that landed on `$PRIMARY_BRANCH` since the PR's merge-base. When triggered, the
orchestrator injects a `## Stale-base regression check (BLOCKER)` section listing the affected
files; the formula instructs Claude to set verdict=REQUEST_CHANGES unless the reverts are
explicitly intentional. A CI guard (`.woodpecker/check-stale-rebase.sh`) runs the same check
as belt-and-braces.

**Environment variables consumed**:
- `FORGE_TOKEN` — Dev-agent token (must not be the same account as FORGE_REVIEW_TOKEN)
- `FORGE_REVIEW_TOKEN` — Review-agent token for approvals (use human/admin account; branch protection: in approvals whitelist)
- `FORGE_REPO`, `FORGE_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`
- `PRIMARY_BRANCH`, `WOODPECKER_REPO_ID`
