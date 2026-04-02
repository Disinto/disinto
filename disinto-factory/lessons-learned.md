# Working with the factory — lessons learned

## Writing issues for the dev agent

**Put everything in the issue body, not comments.** The dev agent reads the issue body when it starts work. It does not reliably read comments. If an issue fails and you need to add guidance for a retry, update the issue body.

**One approach per issue, no choices.** The dev agent cannot make design decisions. If there are multiple ways to solve a problem, decide before filing. Issues with "Option A or Option B" will confuse the agent.

**Issues must fit the templates.** Every backlog issue needs: affected files (max 3), acceptance criteria (max 5 checkboxes), and a clear proposed solution. If you cannot fill these fields, the issue is too big — label it `vision` and break it down first.

**Explicit dependencies prevent ordering bugs.** Add `Depends-on: #N` in the issue body. dev-poll checks these before pickup. Without explicit deps, the agent may attempt work on a stale codebase.

## Debugging CI failures

**Check CI logs via Woodpecker SQLite when the API fails.** The Woodpecker v3 log API may return HTML instead of JSON. Reliable fallback:
```bash
sqlite3 /var/lib/docker/volumes/disinto_woodpecker-data/_data/woodpecker.sqlite \
  "SELECT le.data FROM log_entries le \
   JOIN steps s ON le.step_id = s.id \
   JOIN workflows w ON s.pipeline_id = w.id \
   JOIN pipelines p ON w.pipeline_id = p.id \
   WHERE p.number = <N> AND s.name = '<step>' ORDER BY le.id"
```

**When the agent fails repeatedly on CI, diagnose externally.** The dev agent cannot see CI log output (only pass/fail status). If the same step fails 3+ times, read the logs yourself and put the exact error and fix in the issue body.

## Retrying failed issues

**Clean up stale branches before retrying.** Old branches cause recovery mode which inherits stale code. Close the PR, delete the branch on Forgejo, then relabel to backlog.

**After a dependency lands, stale branches miss the fix.** If issue B depends on A, and B's PR was created before A merged, B's branch is stale. Close the PR and delete the branch so the agent starts fresh from current main.

## Environment gotchas

**Alpine/BusyBox differs from Debian.** CI and edge containers use Alpine:
- `grep -P` (Perl regex) does not work — use `grep -E`
- `USER` variable is unset — set it explicitly: `USER=$(whoami); export USER`
- Network calls fail during `docker build` in LXD — download binaries on the host, COPY into images

**The host repo drifts from Forgejo main.** If factory code is bind-mounted, the host checkout goes stale. Pull regularly or use versioned releases.

## Vault operations

**The human merging a vault PR must be a Forgejo site admin.** The dispatcher verifies `is_admin` on the merger. Promote your user via the Forgejo CLI or database if needed.

**Result files cache failures.** If a vault action fails, the dispatcher writes `.result.json` and skips it. To retry: delete the result file inside the edge container.

## Breaking down large features

**Vision issues need structured decomposition.** When a feature touches multiple subsystems or has design forks, label it `vision`. Break it down by identifying what exists, what can be reused, where the design forks are, and resolve them before filing backlog issues.

**Prefer gluecode over greenfield.** Check if Forgejo API, Woodpecker, Docker, or existing lib/ functions can do the job before building new components.

**Max 7 sub-issues per sprint.** If a breakdown produces more, split into two sprints.
