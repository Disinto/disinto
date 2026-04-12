<!-- last-reviewed: c51cc9dba649ed543b910b561231a5c8bd2130bc -->
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
hardcoded 'origin'). Before starting the session, runs `lib/build-graph.py --changed-files
<PR files>` and appends the JSON structural analysis (affected objectives, orphaned
prerequisites, thin evidence) to the review prompt. Graph failures are non-fatal — review
proceeds without it.

**Environment variables consumed**:
- `FORGE_TOKEN` — Dev-agent token (must not be the same account as FORGE_REVIEW_TOKEN)
- `FORGE_REVIEW_TOKEN` — Review-agent token for approvals (use human/admin account; branch protection: in approvals whitelist)
- `FORGE_REPO`, `FORGE_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`
- `PRIMARY_BRANCH`, `WOODPECKER_REPO_ID`
