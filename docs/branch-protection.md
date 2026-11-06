# Branch protection: the CI gate on project repos

`setup_project_branch_protection()` in [`lib/branch-protection.sh`](../lib/branch-protection.sh)
protects `main` on project repos (e.g. `disinto-admin/disinto`). The status-check
gate is version-controlled there: the payload declares

- `required_status_checks: true`
- `status_check_contexts: ["ci/woodpecker/pr/ci"]`

so a PR head must pass the Woodpecker **pull_request** pipeline before it can be
merged.

## Why `pr/ci` and not a push-event context

Woodpecker discriminates pipeline events by **event type** (`push` vs
`pull_request`), not by the pushing account. A force-pushed head — the normal
outcome of a rebase or a CI fix — gets **no** `ci/woodpecker/push/*` pipeline.
Requiring a push-event status check context would therefore leave any rebased PR
permanently unmergeable: the required context is never produced, and nothing the
agent can do in the repo fixes it.

`ci/woodpecker/pr/ci` is the context that actually validates the PR head, and it
is produced for every PR update including force-pushed ones. That is the route
chosen in #1084; making force-pushes emit push pipelines would be Woodpecker/
Forgejo webhook behavior this repo cannot control.

## CI triggers

`.woodpecker/ci.yml` runs on pull requests and on pushes to `main` only. A push
to a PR branch is validated by the PR's `pull_request` pipeline, which runs
the same steps plus the PR-only ones (stale-base check, defaults golden,
agent smoke). Running a `push` pipeline as well put two full pipelines on the
single runner for every push, 30–45 minutes before the head went green
(2026-10-03).

## Applying the gate to a live forge

The payload in `lib/branch-protection.sh` is the source of truth, but the
function only runs when it is invoked (e.g. via `bin/disinto` hire/setup
paths). Applying the gate to an already-running forge is a deliberate human
step, not something the code does on its own.

## Rollout branches (live, canary)

The self-update rollout moves two branches of the project repo, `live` and
`canary`, each holding a commit of `main`: every agent follows `live`, one
agent follows `canary`, and the rollout promotes `canary` to `live` after it
soaked, or rolls `canary` back to `live`. See
[`docs/design/notes/self-update.md`](design/notes/self-update.md) for the flow.

`rollout_branches_setup` in [`lib/branch-rules.sh`](../lib/branch-rules.sh)
creates the two branches that are missing, each starting at `main`, and puts a
push rule on `live`: only `supervisor-bot` and `disinto-admin` may push it, and
only `disinto-admin` may merge it. An existing branch is left where it is.

`canary` gets no rule. Forgejo refuses every non-fast-forward push to a
protected branch and its API offers no force-push allowlist, while a rollback
moves `canary` back — a rule there would block the rollback the rollout needs.
Safety comes from the tool instead: the agents take only a `canary` that is a
commit of `main`, and the rollout tool resets a `canary` it did not set.

As for the CI gate above, applying this to a live forge is a deliberate step by
a repo admin: `lib/branch-rules.sh rollout-branches <owner/repo>`, run with the
`FORGE_TOKEN` of `disinto-admin`.

## The wall: protected files

With rollouts, the factory can roll out changes to what grades it, what stops
it and what gates it. The **wall** is the forge's `protected_file_patterns` on
`main` of both repos, defined by `wall_patterns` in
[`lib/wall.sh`](../lib/wall.sh) (see
[`docs/design/notes/self-update.md`](design/notes/self-update.md), "The wall").
The bots have write, not admin, so they cannot merge a PR that changes a
protected file; the owner merges it as `disinto-admin`.

- `disinto` (`disinto-admin/disinto`): `tools/sprint-grades.sh`,
  `tools/sprint-held.sh`, `tools/grade.sh`, `tools/grade-threshold.sh`,
  `lib/sprint-block.sh` (what grades it), `lib/repair-suspend.sh` (what stops
  it), `action-vault/policy.toml` (what gates it), `tools/rollout.sh` and
  `.woodpecker/*.yml` (what rolls it out), and `docs/design/**` (the design).
  The pipelines are walled, not the scripts they run: every new sourced file
  is listed in `.woodpecker/agent-smoke.sh`, and walling that would send each
  such PR to the owner.
- `ops` (`disinto-admin/ops`): `vault/policy.toml`, `packs/repair.toml`,
  `packs/rollout.toml`.

A PR that changes a listed file merges only by a repo admin's override (as
`disinto-admin`, the API's `force_merge`); on ops `main` the new rule keeps
direct pushes open to every writer as today, but a direct push that changes one
of the listed files is refused. Each entry means a PR waits for the owner, so
the list stays short.

Applying it to a live forge is a deliberate step by a repo admin, as for the
rules above: `lib/wall.sh apply <owner/repo> <disinto|ops>`, run with the
`FORGE_TOKEN` of `disinto-admin`. `wall_hits KIND` answers which paths of a
list are walled, for the tools that must know before they merge or push.
