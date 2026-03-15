# Review Agent Best Practices

## Architecture
- `review-poll.sh` (cron */10) → finds open PRs with CI pass + no review → spawns `review-pr.sh`
- `review-pr.sh` uses `claude -p` to review the diff, posts structured comment
- Uses `review_bot` Codeberg account for formal reviews (separate from main account)
- Skips WIP/draft PRs (`[WIP]` in title or draft flag)

## Safe Fixes
- Manually trigger review: `bash ${FACTORY_ROOT}/review/review-pr.sh <pr-number>`
- Force re-review: `bash ${FACTORY_ROOT}/review/review-pr.sh <pr-number> --force`
- Check review log: `tail -20 ${FACTORY_ROOT}/review/review.log`

## Common Failures
- **"SKIP: CI=failure"** — review bot won't review until CI passes. Fix CI first.
- **"already reviewed"** — bot checks `<!-- reviewed: SHA -->` comment marker. Use `--force` to override.
- **Review error comment** — uses `<!-- review-error: SHA -->` marker, does NOT count as reviewed. Bot should retry automatically.
- **Self-narration collapse** — bot sometimes narrates instead of producing structured JSON. JSON output format in the prompt prevents this.
- **Hallucinated findings** — bot may flag non-issues. This needs Clawy's judgment — escalate.

## Monitoring
- Unreviewed PRs with CI pass for >1h → supervisor-poll.sh auto-triggers review
- Review errors should resolve on next poll cycle
- If same PR fails review 3+ times → likely a prompt issue, escalate

## Lessons Learned
- Review bot must output JSON — prevents self-narration collapse
- DISCUSS verdict should be treated same as REQUEST_CHANGES by dev-agent
- Error comments must NOT include `<!-- reviewed: SHA -->` — would falsely mark as reviewed
- Review bot uses Codeberg formal reviews API — branch protection requires different user than PR author
