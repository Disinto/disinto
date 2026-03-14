# Disk Best Practices

## Safe Fixes
- Docker cleanup: `sudo docker system prune -f` (keeps images, removes stopped containers + dangling layers)
- Truncate factory logs >5MB: `truncate -s 0 <file>`
- Remove stale worktrees: check `/tmp/${PROJECT_NAME}-worktree-*`, only if dev-agent not running on them
- Woodpecker log_entries: `DELETE FROM log_entries WHERE id < (SELECT max(id) - 100000 FROM log_entries);` then `VACUUM;`
- Node module caches in worktrees: `rm -rf /tmp/${PROJECT_NAME}-worktree-*/node_modules/`
- Git garbage collection: `cd $PROJECT_REPO_ROOT && git gc --prune=now`

## Dangerous (escalate)
- `docker system prune -a --volumes` — deletes ALL images including CI build cache
- Deleting anything in `$PROJECT_REPO_ROOT/` that's tracked by git
- Truncating Woodpecker DB tables other than log_entries

## Known Disk Hogs
- Woodpecker `log_entries` table: grows to 5GB+. Truncate periodically.
- Docker overlay layers: survive normal prune. `-a` variant kills everything.
- Git worktrees in /tmp: accumulate node_modules, build artifacts
- Forge cache in `~/.foundry/cache/`: can grow large with many compilations

## Lessons Learned
- After truncating log_entries, run VACUUM FULL (reclaims actual disk space)
- Docker ghost overlay layers need `prune -a` but that kills CI images — only do this if truly desperate
