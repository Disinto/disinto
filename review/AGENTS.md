<!-- last-reviewed: 5c76d4beb0f1dd75a22be81154c3a9b016a96ddf -->
# Review Agent

**Role**: AI-powered PR review — post structured findings and formal
approve/request-changes verdicts to forge.

**Trigger**: `review-poll.sh` runs every 10 min via cron. It scans open PRs
whose CI has passed and that lack a review for the current HEAD SHA, then
spawns `review-pr.sh <pr-number>`.

**Key files**:
- `review/review-poll.sh` — Cron scheduler: finds unreviewed PRs with passing CI. Sources `lib/guard.sh` and calls `check_active reviewer` — skips if `$FACTORY_ROOT/state/.reviewer-active` is absent. **Circuit breaker**: counts existing `<!-- review-error: <sha> -->` comments; skips a PR if ≥3 consecutive errors for the same HEAD SHA (prevents flooding on repeated review failures).
- `review/review-pr.sh` — Creates/reuses a tmux session (`review-{project}-{pr}`), injects PR diff, waits for Claude to write structured JSON output, posts markdown review + formal forge review, auto-creates follow-up issues for pre-existing tech debt. Calls `resolve_forge_remote()` at startup to determine the correct git remote name (avoids hardcoded 'origin'). Before starting the session, runs `lib/build-graph.py --changed-files <PR files>` and appends the JSON structural analysis (affected objectives, orphaned prerequisites, thin evidence) to the review prompt. Graph failures are non-fatal — review proceeds without it.

**Environment variables consumed**:
- `FORGE_TOKEN` — Dev-agent token (must not be the same account as FORGE_REVIEW_TOKEN)
- `FORGE_REVIEW_TOKEN` — Review-agent token for approvals (use human/admin account; branch protection: in approvals whitelist)
- `FORGE_REPO`, `FORGE_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`
- `PRIMARY_BRANCH`, `WOODPECKER_REPO_ID`
