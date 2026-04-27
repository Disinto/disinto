# Acceptance tests

Acceptance criteria must be **runnable on the live box**, not aspirational.
Every command in the `## Acceptance test` section must execute verbatim and
produce the expected output when run against the current deployment.

## Why this matters

Two consecutive sprints shipped work that passed acceptance criteria as written
but did not survive contact with the live data path. The pattern was consistent
enough to be the process, not the bug:

- Agents pattern-match issue text into code that *looks like* the requested code.
- Reviewers read diffs and prose, not behavior.
- CI runs unit-test-shaped pipelines, not end-to-end on the live data path.
- Nobody runs the AC commands on the live box before closing.

The fix: **every acceptance test is a shell command with expected output.**
If you can't run it on the box, it doesn't belong in the acceptance test.

## The convention

Every backlog issue MUST include an `## Acceptance test` section at the bottom
with explicit shell commands and their expected output.

### Format

```markdown
## Acceptance test

Run on `disinto-nomad-box` after deploy:

```bash
$ jq '.collectors | keys' /srv/disinto/snapshot-state/state.json
[ "agents", "forge", "inbox", "nomad" ]

$ jq '.collectors.nomad.jobs | length' /srv/disinto/snapshot-state/state.json
12
```
```

### Rules

1. **Every command must be runnable verbatim.** No "and verify it works."
   No "ensure X is correct." The command must be copy-paste-runnable.
2. **Include expected output.** Each command is followed by the exact expected
   output on the next line(s). If the output is non-deterministic (e.g., a
   count), add a comment explaining the expected range.
3. **Use absolute paths.** Never rely on working directory.
4. **Reference the right file.** If the issue touches a state file, the AC
   must query that file — not a stub or a different path.
5. **Keep it under 10 commands.** If you need more, the issue is too large.

### Positive example

```markdown
## Acceptance test

After deploying the snapshot daemon and running one tick:

```bash
$ jq '.collectors | keys | sort' /srv/disinto/snapshot-state/state.json
[ "agents", "forge", "inbox", "nomad" ]

$ jq '.collectors.agents.version' /srv/disinto/snapshot-state/state.json
1
```
```

### Negative example (aspirational — do NOT use)

```markdown
## Acceptance criteria

- [ ] The daemon collects data from all agents
- [ ] The data is correct
- [ ] CI is green
```

Problems:
- "collects data" is not a command anyone can run.
- "is correct" is subjective — who decides?
- "CI is green" is a CI check, not an AC command.

### Negative example (partially runnable)

```markdown
## Acceptance test

```bash
$ # Make sure the daemon is running
$ systemctl status snapshot-daemon

$ # Check the output is valid
$ cat /srv/disinto/snapshot-state/state.json | jq .
```

Problems:
- `systemctl status` output is not deterministic — no expected output shown.
- `jq .` will succeed on any valid JSON — no assertion on structure or content.
```

## How reviewers check

When reviewing a PR, the reviewer checks that:

1. The `## Acceptance test` section exists.
2. Every command references the correct file/path (not a stub).
3. The expected output matches the schema described in the issue.
4. If a command cannot be run on the live box, it is flagged as
   `needs-deploy-verification` and the PR is not approved until
   a human or supervisor confirms it works.

## How the process works post-merge

After a PR merges:

1. The issue receives the `awaiting-live-verification` label.
2. A human (or supervisor agent, when functional) runs the AC commands on
   `disinto-nomad-box`.
3. All pass → remove label, close issue.
4. Any fail → reopen with reproduction; dev-agent reclaims.

This replaces the old "merge → close" pattern where "closed" meant
"the diff was merged" rather than "the behavior was proven."
