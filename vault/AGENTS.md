<!-- last-reviewed: 80a64cd3e4d2836bfab3c46230a780e3e233125d -->
# Vault Agent

**Role**: Safety gate for dangerous or irreversible actions. Actions enter a
pending queue and are classified by Claude via `vault-agent.sh`, which can
auto-approve (call `vault-fire.sh` directly), auto-reject (call
`vault-reject.sh`), or escalate to a human via Matrix for APPROVE/REJECT.

**Trigger**: `vault-poll.sh` runs every 30 min via cron.

**Key files**:
- `vault/vault-poll.sh` — Processes pending actions: retry approved, auto-reject after 48h timeout, invoke vault-agent for new items
- `vault/vault-agent.sh` — Classifies and routes pending actions via `claude -p`: auto-approve, auto-reject, or escalate to human
- `vault/PROMPT.md` — System prompt for the vault agent's Claude invocation
- `vault/vault-fire.sh` — Executes an approved action
- `vault/vault-reject.sh` — Marks an action as rejected

**Environment variables consumed**:
- All from `lib/env.sh`
- `MATRIX_TOKEN`, `MATRIX_ROOM_ID`, `MATRIX_HOMESERVER` — Escalation channel
