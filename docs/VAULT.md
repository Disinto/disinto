# Vault PR Workflow

This document describes the vault PR-based approval workflow for the ops repo.

## Overview

The vault system enables agents to request execution of privileged actions (deployments, token operations, etc.) through a PR-based approval process. This replaces the old vault directory structure with a more auditable, collaborative workflow.

Since 2026-11-02 the gate approves vault PRs itself (`docs/design/proposal-loop.md` §3): the account that opens a vault PR merges it at once and the owner is told by Telegram (`lib/notice.sh`). Ops `main` carries no branch protection on this forge.

## Vault PR Lifecycle

1. **Request** — Agent calls `lib/action-vault.sh:vault_request()` with action TOML content
2. **Validation** — TOML is validated against the schema in `action-vault/vault-env.sh`
3. **PR Creation** — A PR is created on `disinto-ops` with:
   - Branch: `vault/<action-id>`
   - Title: `vault: <action-id>`
   - Labels: `vault`, `pending-approval`
   - File: `vault/actions/<action-id>.toml`
   - **Gate merge** — the account that opened the PR merges it at once (no approval wait)
4. **Execution** — Dispatcher (issue #76) polls for merged vault PRs and executes them
5. **Cleanup** — Executed vault items are moved to `fired/` (via PR)

## Bot Account Behavior

Bot accounts open and merge their own vault PRs. The dispatcher verifies that an action arrived through a merged PR (#2034).

## Testing

1. **Merged PR runs** — a vault TOML that arrived through a merged PR is dispatched whoever merged it (#2034).
2. **Direct push rejected** — a TOML with no merge commit behind it is moved to `vault/rejected/`.

The gate's merge behavior is covered hermetically by `tests/acceptance/issue-2037.sh` (stubbed forge API, no live services); the dispatcher's merged-PR check by `tests/acceptance/issue-2034.sh`.

## Related Issues

- #73 — Vault redesign proposal
- #74 — Vault action TOML schema
- #75 — Vault PR creation helper (`lib/action-vault.sh`)
- #76 — Dispatcher rewrite (poll for merged vault PRs)
- #77 — Branch protection on ops repo (retired: ops `main` is unprotected since 2026-11-02)
- #2031 — Owner notice queue (`lib/notice.sh`)
- #2034 — Dispatcher verification that an action arrived through a merged PR
- #2037 — The gate merges a medium or high vault PR at once

## See Also

- [`lib/action-vault.sh`](../lib/action-vault.sh) — Vault PR creation helper
- [`action-vault/vault-env.sh`](../action-vault/vault-env.sh) — TOML validation
- [`lib/notice.sh`](../lib/notice.sh) — Owner notice queue
