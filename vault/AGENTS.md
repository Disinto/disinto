<!-- last-reviewed: f32707ba659de278a3af434e3549fb8a8dce9d3a -->
# Vault Agent

**Role**: Three-pipeline gate — action safety classification, resource procurement, and human-action drafting.

**Pipeline A — Action Gating (*.json)**: Actions enter a pending queue and are
classified by Claude via `vault-agent.sh`, which can auto-approve (call
`vault-fire.sh` directly), auto-reject (call `vault-reject.sh`), or escalate
to a human by writing `PHASE:escalate` to a phase file — using the same
unified escalation path as dev/action agents.

**Pipeline B — Procurement (*.md)**: The planner files resource requests as
markdown files in `$OPS_REPO_ROOT/vault/pending/`. `vault-poll.sh` notifies the human via
vault/forge. The human fulfills the request (creates accounts, provisions infra,
adds secrets to `.env`) and moves the file to `$OPS_REPO_ROOT/vault/approved/`.
`vault-fire.sh` then extracts the proposed entry and appends it to
`$OPS_REPO_ROOT/RESOURCES.md`.

**Pipeline C — Rent-a-Human (outreach drafts)**: Any agent can dispatch the
`run-rent-a-human` formula (via an `action` issue) when a task requires a human
touch — posting on Reddit, commenting on HN, signing up for a service, etc.
Claude drafts copy-paste-ready content to `vault/outreach/{platform}/drafts/`
and notifies the human via vault/forge for one-click execution. No vault approval
needed — the human reviews and publishes directly.

**Trigger**: `vault-poll.sh` runs every 30 min via cron.

**Key files**:
- `vault/vault-poll.sh` — Processes pending items: retry approved, auto-reject after 48h timeout, invoke vault-agent for JSON actions, notify human for procurement requests
- `vault/vault-agent.sh` — Classifies and routes pending JSON actions via `claude -p`: auto-approve, auto-reject, or escalate to human
- `vault/vault-env.sh` — Shared env setup for vault sub-scripts: sources `lib/env.sh`, overrides `FORGE_TOKEN` with `FORGE_VAULT_TOKEN`, sets `VAULT_TOKEN` for runner container
- `formulas/run-vault.toml` — Source-of-truth formula for the vault agent's classification and routing logic
- `vault/vault-fire.sh` — Executes an approved action (JSON) in an **ephemeral Docker container** with vault-only secrets injected (GITHUB_TOKEN, CLAWHUB_TOKEN — never exposed to agents). For deployment actions, calls `lib/ci-helpers.sh:ci_promote()` to gate production promotes via Woodpecker environments. Writes `$OPS_REPO_ROOT/RESOURCES.md` entry for procurement MD approvals.
- `vault/vault-reject.sh` — Marks a JSON action as rejected
- `formulas/run-rent-a-human.toml` — Formula for human-action drafts: Claude researches target platform norms, drafts copy-paste content, writes to `vault/outreach/{platform}/drafts/`, notifies human via vault/forge

**Procurement flow** (all vault items live in `$OPS_REPO_ROOT/vault/`):
1. Planner drops `$OPS_REPO_ROOT/vault/pending/<name>.md` with what/why/proposed RESOURCES.md entry
2. `vault-poll.sh` notifies human via vault/forge
3. Human fulfills: creates account, adds secrets to `.env`, moves file to `approved/`
4. `vault-fire.sh` extracts proposed entry, appends to `$OPS_REPO_ROOT/RESOURCES.md`, moves to `fired/`
5. Next planner run reads RESOURCES.md → new capability available → unblocks prerequisite tree

**Environment variables consumed**:
- All from `lib/env.sh`
