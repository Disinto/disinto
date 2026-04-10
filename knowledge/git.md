# Git State Recovery — Best Practices

## Git State Issues (P2)

When git repo is on wrong branch or in broken rebase state:

### Wrong Branch Recovery
```bash
cd "$PROJECT_REPO_ROOT"
git checkout "$PRIMARY_BRANCH" 2>/dev/null || git checkout master 2>/dev/null
```

### Broken Rebase Recovery
```bash
cd "$PROJECT_REPO_ROOT"
git rebase --abort 2>/dev/null || true
git checkout "$PRIMARY_BRANCH" 2>/dev/null || git checkout master 2>/dev/null
```

### Stale Lock File Cleanup
```bash
rm -f /path/to/stale.lock
```

### Prevention
- Always checkout primary branch after rebase conflicts
- Remove lock files after agent sessions complete
- Use `git status` to verify repo state before operations
