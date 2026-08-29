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

## Applying the gate to a live forge

The payload in `lib/branch-protection.sh` is the source of truth, but the
function only runs when it is invoked (e.g. via `bin/disinto` hire/setup
paths). Applying the gate to an already-running forge is a deliberate human
step, not something the code does on its own.
