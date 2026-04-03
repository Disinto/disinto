# Vault PR Workflow

This document describes the vault PR-based approval workflow for the ops repo.

## Overview

The vault system enables agents to request execution of privileged actions (deployments, token operations, etc.) through a PR-based approval process. This replaces the old vault directory structure with a more auditable, collaborative workflow.

## Branch Protection

The `main` branch on the ops repo (`johba/disinto-ops`) is protected via Forgejo branch protection to enforce:

- **Require 1 approval before merge** — All vault PRs must have at least one approval from an admin user
- **Admin-only merge** — Only users with admin role can merge vault PRs (regular collaborators and bot accounts cannot)
- **Block direct pushes** — All changes to `main` must go through PRs

### Protection Rules

| Setting | Value |
|---------|-------|
| `enable_push` | `false` |
| `enable_force_push` | `false` |
| `enable_merge_commit` | `true` |
| `required_approvals` | `1` |
| `admin_enforced` | `true` |

## Vault PR Lifecycle

1. **Request** — Agent calls `lib/vault.sh:vault_request()` with action TOML content
2. **Validation** — TOML is validated against the schema in `vault/vault-env.sh`
3. **PR Creation** — A PR is created on `disinto-ops` with:
   - Branch: `vault/<action-id>`
   - Title: `vault: <action-id>`
   - Labels: `vault`, `pending-approval`
   - File: `vault/actions/<action-id>.toml`
   - **Auto-merge enabled** — Forgejo will auto-merge after approval
4. **Approval** — Admin user reviews and approves the PR
5. **Auto-merge** — Forgejo automatically merges the PR once required approvals are met
6. **Execution** — Dispatcher (issue #76) polls for merged vault PRs and executes them
7. **Cleanup** — Executed vault items are moved to `fired/` (via PR)

## Bot Account Behavior

Bot accounts (dev-bot, review-bot, vault-bot, etc.) **cannot merge vault PRs** even if they have approval, due to the `admin_enforced` setting. This ensures:

- Only human admins can approve sensitive vault actions
- Bot accounts can only create vault PRs, not execute them
- Bot accounts cannot self-approve vault PRs (Forgejo prevents this automatically)
- Manual admin review is always required for privileged operations

## Setup

To set up branch protection on the ops repo:

```bash
# Source environment
source lib/env.sh
source lib/branch-protection.sh

# Set up protection
setup_vault_branch_protection main

# Verify setup
verify_branch_protection main
```

Or use the CLI directly:

```bash
export FORGE_TOKEN="<admin-token>"
export FORGE_URL="https://codeberg.org"
export FORGE_OPS_REPO="johba/disinto-ops"

# Set up protection
bash lib/branch-protection.sh setup main

# Verify
bash lib/branch-protection.sh verify main
```

## Testing

To verify the protection is working:

1. **Bot cannot merge** — Attempt to merge a PR with a bot token (should fail with HTTP 405)
2. **Admin can merge** — Attempt to merge with admin token (should succeed)
3. **Direct push blocked** — Attempt `git push origin main` (should be rejected)

## Related Issues

- #73 — Vault redesign proposal
- #74 — Vault action TOML schema
- #75 — Vault PR creation helper (`lib/vault.sh`)
- #76 — Dispatcher rewrite (poll for merged vault PRs)
- #77 — Branch protection on ops repo (this issue)

## See Also

- [`lib/vault.sh`](../lib/vault.sh) — Vault PR creation helper
- [`vault/vault-env.sh`](../vault/vault-env.sh) — TOML validation
- [`lib/branch-protection.sh`](../lib/branch-protection.sh) — Branch protection helper
