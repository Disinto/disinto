# Git Best Practices

## Environment
- Repo: `/home/debian/harb`, remote: `codeberg.org/johba/harb`
- Branch: `master` (protected — no direct push, PRs only)
- Worktrees: `/tmp/harb-worktree-<issue>/`

## Safe Fixes
- Abort stale rebase: `cd /home/debian/harb && git rebase --abort`
- Switch to master: `git checkout master`
- Prune worktrees: `git worktree prune`
- Reset dirty state: `git checkout -- .` (only uncommitted changes)
- Fetch latest: `git fetch origin master`

## Dangerous (escalate)
- `git reset --hard` on any branch with unpushed work
- Deleting remote branches
- Force-pushing to any branch
- Anything on the master branch directly

## Known Issues
- Main repo MUST be on master at all times. Dev work happens in worktrees.
- Stale rebases (detached HEAD) break all worktree creation — silent factory stall.
- `git worktree add` fails if target directory exists (even empty). Remove first.
- Many old branches exist locally (100+). Normal — don't bulk-delete.

## Evolution Pipeline
- The evolution pipeline (`tools/push3-evolution/evolve.sh`) temporarily modifies
  `onchain/src/OptimizerV3.sol` and `onchain/src/OptimizerV3Push3.sol` during runs.
- **DO NOT revert these files while evolution is running** (check: `pgrep -f evolve.sh`).
- If `/tmp/evolution.pid` exists and the PID is alive, the dirty state is intentional.
- Evolution will restore the files when it finishes.

## Lessons Learned
- NEVER delete remote branches before confirming merge. Close PR, rebase locally, force-push if needed.
- Stale rebase caused 5h factory stall once (2026-03-11). Auto-heal added to dev-agent.
- lint-staged hooks fail when `forge` not in PATH. Use `--no-verify` when committing from scripts.
