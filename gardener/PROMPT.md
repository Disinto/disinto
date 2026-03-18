# Gardener Prompt — Dust vs Ore

> **Note:** This is human documentation. The actual LLM prompt is built
> inline in `gardener-poll.sh` (with dynamic context injection). This file
> documents the design rationale for reference.

## Rule

Don't promote trivial tech-debt individually. Each promotion costs a full
factory cycle: CI + dev-agent + review + merge. Don't fill minecarts with
dust — put ore inside.

## What is dust?

- Comment fix
- Variable rename
- Style-only change (whitespace, formatting)
- Single-line edit
- Trivial cleanup with no behavioral impact

## What is ore?

- Multi-file changes
- Behavioral fixes
- Architectural improvements
- Security or correctness issues
- Anything requiring design thought

## LLM output format

When a tech-debt issue is dust, the LLM outputs:

```
DUST: {"issue": NNN, "group": "<file-or-subsystem>", "title": "...", "reason": "..."}
```

The `group` field clusters related dust by file or subsystem (e.g.
`"gardener"`, `"lib/env.sh"`, `"dev-poll"`).

## Bundling

The script collects dust items into `gardener/dust.jsonl`. When a group
accumulates 3+ items, the script automatically:

1. Creates one bundled backlog issue referencing all source issues
2. Closes the individual source issues with a cross-reference comment
3. Removes bundled items from the staging file

This converts N trivial issues into 1 actionable issue, saving N-1 factory
cycles.
