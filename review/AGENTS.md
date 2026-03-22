<!-- last-reviewed: ac51497489abc5412bc47f451facc30b0455cbd2 -->
# Review Agent

**Role**: AI-powered PR review — post structured findings and formal
approve/request-changes verdicts to Codeberg.

**Trigger**: `review-poll.sh` runs every 10 min via cron. It scans open PRs
whose CI has passed and that lack a review for the current HEAD SHA, then
spawns `review-pr.sh <pr-number>`.

**Key files**:
- `review/review-poll.sh` — Cron scheduler: finds unreviewed PRs with passing CI
- `review/review-pr.sh` — Creates/reuses a tmux session (`review-{project}-{pr}`), injects PR diff, waits for Claude to write structured JSON output, posts markdown review + formal Codeberg review, auto-creates follow-up issues for pre-existing tech debt

**Environment variables consumed**:
- `CODEBERG_TOKEN` — Dev-agent token (must not be the same account as REVIEW_BOT_TOKEN)
- `REVIEW_BOT_TOKEN` — Review-agent token for approvals (use human/admin account; branch protection: in approvals whitelist)
- `CODEBERG_REPO`, `CODEBERG_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`
- `PRIMARY_BRANCH`, `WOODPECKER_REPO_ID`
- `MATRIX_TOKEN`, `MATRIX_ROOM_ID`, `MATRIX_HOMESERVER`
