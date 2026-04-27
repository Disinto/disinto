# ack-inbox — dismiss / accept / snooze inbox items

> Trigger phrases: "skip", "later", "remind me later", "ignore that",
> "walk me through it" (accept + follow-up), "snooze".

This skill records the operator's reaction to a surfaced inbox item by
writing the corresponding sentinel under `/var/lib/disinto/inbox/.acked`,
`/.shown`, or `/.snoozed`. It is a thin wrapper over `bin/inbox-ack.sh`,
parallel to how `narrate` wraps qwen and `factory-state` wraps the
snapshot read.

The voice/chat model surfaces an item via `factory-state.sh inbox` (or
the inbox tool), the operator reacts, and the model calls this skill to
persist the decision so the item is filtered on the next snapshot tick.

## When to use

- Operator says "skip", "ignore", "dismiss" → action `dismiss`.
- Operator says "walk me through it", "yes show me", "open it" → action
  `accept`. Storage is identical to dismiss; the semantic distinction is
  for the model to do whatever follow-up the operator implied (spawn a
  delegate, switch context, etc.). Either way, the item should not be
  surfaced again.
- Operator says "later", "remind me in an hour", "snooze" → action
  `snooze`. Item reappears after 1 hour.

## Commands

| Command | Purpose |
| --- | --- |
| `ack-inbox.sh <id> dismiss` | Mark item acknowledged; never surface again. Prints `dismissed`. |
| `ack-inbox.sh <id> accept`  | Same storage as dismiss; semantic "user is acting on it now". Prints `accepted`. |
| `ack-inbox.sh <id> snooze`  | Snooze for 1h via `--snooze`. Prints `snoozed for 1h`. |

## Exit codes

- `0` — success.
- `1` — id not found in current snapshot, invalid action, or missing args.

## Examples

Operator: "skip that prediction"
→ `ack-inbox.sh forge-issue-901 dismiss`
→ Outputs `dismissed`. Item disappears from `factory-state.sh inbox`
  on the next snapshot tick (≤5 s).

Operator: "remind me about the architect draft in an hour"
→ `ack-inbox.sh av-sprint-draft.toml snooze`
→ Outputs `snoozed for 1h`. Item filtered until sentinel mtime passes.

Operator: "walk me through the completed delegate"
→ `ack-inbox.sh thread-del-abc123 accept`
→ Outputs `accepted`. Model then calls `narrate.sh` (or similar) to
  follow up.

## Data source

- Reads `/var/lib/disinto/snapshot/state.json` (`.collectors.inbox.items[].id`) to
  validate the id exists before writing the sentinel.
- Delegates the write to `bin/inbox-ack.sh`, which manages the per-item
  sentinel files atomically.

## Errors

- Unknown id → stderr `inbox item not found: <id>` and exit 1.
- Invalid action → stderr `invalid action: <action> (expected dismiss|accept|snooze)` and exit 1.
- Missing args → stderr usage line and exit 1.
