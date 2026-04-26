# check-inbox — read prioritized inbox items, mark shown on return

> Trigger phrases: "check inbox", "what's in my inbox", "any new items",
> "inbox items", "read inbox".

This skill reads the snapshot's inbox section (`/var/lib/disinto/snapshot/state.json`
`.collectors.inbox.items`), returns a voice-friendly prioritized list of unshown
items, and marks each returned item as "shown" so the next call won't re-surface
them.

## When to use

- Voice state-machine calls `check_inbox` when the user shows readiness signals.
- Operator asks about inbox items or unread notifications.
- After a delegate thread completes and the operator is ready for results.

## Commands

| Command | Purpose |
| --- | --- |
| `check-inbox.sh` | Return all unshown items at all priorities |
| `check-inbox.sh --min-priority P0` | Return only P0 (critical) items |
| `check-inbox.sh --min-priority P1` | Return P0 and P1 items |
| `check-inbox.sh --min-priority P2` | Return all items (default) |

## Output format

Plain-text, voice-friendly:

```
3 unread inbox items:
  P0: incident-2026-04-12-sunday — "Incident analysis just finished"
  P1: action-vault/sprint-12.md — "Architect drafted sprint 12"
  P2: del-abc123def456 — "ci-flaky thread completed"
```

Items are sorted by priority (P0 first), then newest first within each priority.

**Read-side-effect**: each returned item is marked as "shown" via
`bin/inbox-ack.sh --shown <id>` before printing. The next call to this skill
will not re-surface these items unless a new item arrives.

## Empty inbox

If there are no items to surface (all shown, acked, or snoozed), the script
prints nothing and exits 0. The voice model treats empty output as "nothing to
surface" and stays silent.

## Data source

Reads `/var/lib/disinto/snapshot/state.json` — the on-box snapshot written by
the snapshot daemon. The inbox section is populated by
`bin/snapshot-inbox.sh`, which merges items from action-vault drops, Forge
issues, and completed delegate threads.

Inbox item shape:
```json
{
  "id": "thread-del-abc123",
  "kind": "thread-result",
  "title": "ci-flaky thread completed",
  "priority": "P2",
  "ts": "2026-04-12T10:00:00Z"
}
```

## Examples

User: "check my inbox"
→ `check-inbox.sh`
→ Reports items, marks them shown.

User: "any critical items?"
→ `check-inbox.sh --min-priority P0`
→ Reports only P0 items.

User: "check inbox" (again, no new items)
→ `check-inbox.sh`
→ Silent (exit 0).
