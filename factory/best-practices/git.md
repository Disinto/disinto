# Git Best Practices

## Environment
- Repo: `$PROJECT_REPO_ROOT`, remote: `$PROJECT_REMOTE`
- Branch: `$PRIMARY_BRANCH` (protected — no direct push, PRs only)
- Worktrees: `/tmp/${PROJECT_NAME}-worktree-<issue>/`

## Safe Fixes
- Abort stale rebase: `cd $PROJECT_REPO_ROOT && git rebase --abort`
- Switch to $PRIMARY_BRANCH: `git checkout $PRIMARY_BRANCH`
- Prune worktrees: `git worktree prune`
- Reset dirty state: `git checkout -- .` (only uncommitted changes)
- Fetch latest: `git fetch origin $PRIMARY_BRANCH`

## Auto-fixable by Supervisor
- **Merge conflict on approved PR**: rebase onto $PRIMARY_BRANCH and force-push
  ```bash
  cd /tmp/${PROJECT_NAME}-worktree-<issue> || git worktree add /tmp/${PROJECT_NAME}-worktree-<issue> <branch>
  cd /tmp/${PROJECT_NAME}-worktree-<issue>
  git fetch origin $PRIMARY_BRANCH
  git rebase origin/$PRIMARY_BRANCH
  # If conflict is trivial (NatSpec, comments): resolve and continue
  # If conflict is code logic: escalate to Clawy
  git push origin <branch> --force
  ```
- **Stale rebase**: `git rebase --abort && git checkout $PRIMARY_BRANCH`
- **Wrong branch**: `git checkout $PRIMARY_BRANCH`

## Dangerous (escalate)
- `git reset --hard` on any branch with unpushed work
- Deleting remote branches
- Force-pushing to any branch
- Anything on the $PRIMARY_BRANCH branch directly

## Known Issues
- Main repo MUST be on $PRIMARY_BRANCH at all times. Dev work happens in worktrees.
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

### PR #608 Post-Mortem (2026-03-12/13)
PR sat blocked for 24 hours while 21 other PRs merged. Root causes:
1. **Supervisor didn't detect merge conflicts** — only checked CI state, not `mergeable`. Fixed: now checks `mergeable=false` as first condition.
2. **Supervisor didn't detect stale REQUEST_CHANGES** — review bot requested changes, dev-agent never came back to fix them, moved on to other issues. Need: detect "PR has REQUEST_CHANGES older than N hours with no new push."
3. **No staleness kill switch** — after N merge conflicts or N days, a PR should be auto-closed and the issue reopened for a fresh attempt. Rebasing across 21 commits is more work than starting over.

**Rules derived:**
- Supervisor should close PRs that are >24h old with merge conflicts and no recent activity. Reopen the parent issue with a note pointing to the closed PR as prior art.
- Dev-agent must not abandon a PR with REQUEST_CHANGES — either fix or close it before moving to new work.
