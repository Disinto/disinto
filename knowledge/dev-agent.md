# Dev Agent — Best Practices

## Dev Agent Issues (P2)

When dev-agent is stuck, blocked, or in bad state:

### Dead Lock File
```bash
# Check if process still exists
ps -p $(cat /path/to/lock.file) 2>/dev/null || rm -f /path/to/lock.file
```

### Stale Worktree Cleanup
NEVER run a blanket `git worktree prune` — the project clone is shared across
dev/review/supervisor containers with separate /tmps, so a blanket prune
destroys the other containers' live worktree registrations (#1082). Clear only
the exact path you are reclaiming, via the scoped helpers in `lib/worktree.sh`:
```bash
worktree_cleanup /tmp/stale-worktree     # dir + registration + claude cache
worktree_clear_stale /tmp/stale-worktree # registration only (dir already gone)
```

### Blocked Pipeline
- Check if PR is awaiting review or CI
- Verify no other agent is actively working on same issue
- Check for unmet dependencies (issues with `Depends on` refs)

### Prevention
- Concurrency bounded per LLM backend (AD-002)
- Clear lock files in EXIT traps
- Use phase files to track agent state
