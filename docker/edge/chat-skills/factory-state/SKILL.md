# factory-state — read snapshot.json, return text + JSON

> Trigger phrases: "factory state", "system status", "what's going on",
> "how's the factory doing", "current state", "snapshot".

This skill reads the on-box snapshot written by the snapshot daemon at
`/var/lib/disinto/snapshot/state.json` and returns a concise plain-text
summary (for the voice/chat model to speak) plus the full JSON blob
(for the model to dig deeper if needed).

## When to use

- Anytime the operator asks about the current state of the factory.
- Voice sessions that need a quick status read before delegating.
- Chat sessions where the operator wants a snapshot overview.

## Commands

| Command | Purpose |
| --- | --- |
| `factory-state.sh [section]` | Read snapshot and return text summary + JSON. With an optional section argument (`nomad`, `forge`, `agents`, `inbox`), return only that sub-section. |

## Output format

The script emits two blocks separated by a blank line:

1. **Plain-text summary** (~10 lines) — prose form, suitable for speaking aloud.
2. **Full JSON** — the complete state.json (or sub-section) for deeper inspection.

## Staleness

If the snapshot timestamp is older than 30 seconds, a `[stale Ns]` warning
is prepended to the text output.

## Missing snapshot

If the snapshot file does not exist, return:

```
(snapshot daemon not running — check 'nomad job status snapshot')
```

## Examples

User: "what's the factory state?"
→ `factory-state.sh`
→ Report text summary, offer to dig into a section.

User: "how's the nomad job status?"
→ `factory-state.sh nomad`
→ Report nomad jobs/alerts summary.

User: "what's in the inbox?"
→ `factory-state.sh inbox`
→ Report unread items.

## Data source

The snapshot daemon (`bin/snapshot-daemon.sh`) polls every 5 seconds and
writes `/var/lib/disinto/snapshot/state.json` atomically. Collectors
(`snapshot-forge.sh`, `snapshot-nomad.sh`, `snapshot-agents.sh`,
`snapshot-inbox.sh`) merge their data into the file under keys `forge`,
`nomad`, `agents`, and `inbox` respectively.

Top-level shape:
```json
{
  "version": 1,
  "ts": "2026-01-15T12:00:00Z",
  "collectors": {},
  "forge": { "backlog_count": 12, "in_progress_count": 3, ... },
  "nomad": { "jobs": [...], "alerts": [...] },
  "agents": { "dev-opus": { "state": "working", "issue": "#891" }, ... },
  "inbox": { "items": [...], "unread_count": 3 }
}
```
