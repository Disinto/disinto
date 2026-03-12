# Codeberg Best Practices

## Rate Limiting
Codeberg rate-limits SSH and HTTPS clones. Symptoms:
- Woodpecker `git` step fails with exit code 128
- Multiple pipelines fail in quick succession with the same error
- Retriggers make it WORSE by adding more clone attempts

### What To Do
- **Do NOT retrigger** during a rate-limit storm. Wait 10-15 minutes.
- Check if multiple pipelines failed on `git` step recently:
  ```bash
  wpdb -c "SELECT number, status, to_timestamp(started) FROM pipelines WHERE repo_id=2 AND status='failure' ORDER BY number DESC LIMIT 5;"
  wpdb -c "SELECT s.name, s.exit_code FROM steps s JOIN pipelines p ON s.pipeline_id=p.id WHERE p.number=<N> AND p.repo_id=2 AND s.state='failure';"
  ```
- If multiple `git` failures with exit 128 in the last 15 min → it's rate limiting. Wait.
- Only retrigger after 15+ minutes of no CI activity.

### How To Retrigger Safely
```bash
cd <worktree> && git commit --allow-empty -m "ci: retrigger" --no-verify && git push origin <branch> --force
```

### Prevention
- The factory runs 3 agents staggered by 3 minutes. During heavy development, many PRs trigger CI simultaneously.
- One pipeline at a time is ideal on this VPS (resource + rate limit reasons).
- If >3 pipelines are pending/running, do NOT create more work.

## OAuth Tokens
- OAuth tokens expire ~2h. If Codeberg is down during refresh, re-login required.
- API token is in `~/.netrc` — read via `awk` in env.sh.
- Review bot has a separate token ($REVIEW_BOT_TOKEN) for formal reviews.

## Lessons Learned
- Retrigger storm on 2026-03-12: supervisor + dev-agent both retriggered during rate limit, caused 5+ failed pipelines. Added cooldown awareness.
- Empty commit retrigger works but adds noise to git history. Acceptable tradeoff.
