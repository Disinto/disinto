<!-- last-reviewed: a2016db5c35ee3429ebaa212192983a03c4e4cb8 -->
# Vault Agent

**Role**: Dual-purpose gate — action safety classification and resource procurement.

**Pipeline A — Action Gating (*.json)**: Actions enter a pending queue and are
classified by Claude via `vault-agent.sh`, which can auto-approve (call
`vault-fire.sh` directly), auto-reject (call `vault-reject.sh`), or escalate
to a human by writing `PHASE:escalate` to a phase file and sending a Matrix
message — using the same unified escalation path as dev/action agents.

**Pipeline B — Procurement (*.md)**: The planner files resource requests as
markdown files in `vault/pending/`. `vault-poll.sh` notifies the human via
Matrix. The human fulfills the request (creates accounts, provisions infra,
adds secrets to `.env`) and moves the file to `vault/approved/`.
`vault-fire.sh` then extracts the proposed entry and appends it to
`RESOURCES.md`.

**Trigger**: `vault-poll.sh` runs every 30 min via cron.

**Key files**:
- `vault/vault-poll.sh` — Processes pending items: retry approved, auto-reject after 48h timeout, invoke vault-agent for JSON actions, notify human for procurement requests
- `vault/vault-agent.sh` — Classifies and routes pending JSON actions via `claude -p`: auto-approve, auto-reject, or escalate to human
- `vault/PROMPT.md` — System prompt for the vault agent's Claude invocation
- `vault/vault-fire.sh` — Executes an approved action (JSON) or writes RESOURCES.md entry (procurement MD)
- `vault/vault-reject.sh` — Marks a JSON action as rejected

**Procurement flow**:
1. Planner drops `vault/pending/<name>.md` with what/why/proposed RESOURCES.md entry
2. `vault-poll.sh` notifies human via Matrix
3. Human fulfills: creates account, adds secrets to `.env`, moves file to `vault/approved/`
4. `vault-fire.sh` extracts proposed entry, appends to RESOURCES.md, moves to `vault/fired/`
5. Next planner run reads RESOURCES.md → new capability available → unblocks prerequisite tree

**Environment variables consumed**:
- All from `lib/env.sh`
- `MATRIX_TOKEN`, `MATRIX_ROOM_ID`, `MATRIX_HOMESERVER` — Escalation channel
