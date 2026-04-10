# Dev Agent — Best Practices

## Dev Agent Issues (P2)

When dev-agent is stuck, blocked, or in bad state:

### Dead Lock File
```bash
# Check if process still exists
ps -p $(cat /path/to/lock.file) 2>/dev/null || rm -f /path/to/lock.file
```

### Stale Worktree Cleanup
```bash
cd "$PROJECT_REPO_ROOT"
git worktree remove --force /tmp/stale-worktree 2>/dev/null || true
git worktree prune 2>/dev/null || true
```

### Blocked Pipeline
- Check if PR is awaiting review or CI
- Verify no other agent is actively working on same issue
- Check for unmet dependencies (issues with `Depends on` refs)

### Prevention
- Single-threaded pipeline per project (AD-002)
- Clear lock files in EXIT traps
- Use phase files to track agent state
