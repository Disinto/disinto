# Agent Design Principles

> **Status:** Active design principle. All agents, reviewers, and planners should follow this.

## The Determinism / Judgment Split

Every agent has two kinds of work. The architecture should separate them cleanly.

### Deterministic (bash orchestrator)

Mechanical operations that always work the same way. These belong in bash scripts:

- Create and destroy tmux sessions
- Create and destroy git worktrees
- Phase file watching (the event loop)
- Lock files and concurrency guards
- Environment setup and teardown
- Session lifecycle (start, monitor, kill)

**Properties:** No judgment required. Never fails differently based on interpretation. Easy to test. Hard to break.

### Judgment (Claude via formula)

Operations that require understanding context, making decisions, or adapting to novel situations. These belong in the formula — the prompt Claude executes inside the tmux session:

- Read and understand the task (fetch issue body + comments, parse intent)
- Assess dependencies ("does the code this depends on actually exist?")
- Implement the solution
- Create PR with meaningful title and description
- Read review feedback, decide what to address vs push back on
- Handle CI failures (read logs, decide: fix, retry, or escalate)
- Choose rebase strategy (rebase, merge, or start over)
- Decide when to refuse vs implement

**Properties:** Benefits from context. Improves when the formula is refined. Adapts to novel situations without new bash code.

## Why This Matters

### Today's problem

Agent scripts grow by accretion. Every new lesson becomes another `if/elif/else` in bash:
- "CI failed with this pattern → retry with this flag"
- "Review comment mentions X → rebase before addressing"
- "Merge conflict in this file → apply this strategy"

This makes agents brittle, hard to modify, and impossible to generalize across projects.

### The alternative

A thin bash orchestrator handles session lifecycle. Everything that requires judgment lives in the formula — a structured prompt that Claude interprets. Learnings become formula refinements, not bash patches.

```
┌─────────────────────────────────────────┐
│ Bash orchestrator (thin, deterministic) │
│                                         │
│  - tmux session lifecycle               │
│  - worktree create/destroy              │
│  - phase file monitoring                │
│  - lock files                           │
│  - environment setup                    │
└────────────────┬────────────────────────┘
                 │ inject formula
                 ▼
┌─────────────────────────────────────────┐
│ Claude in tmux (fat formula, judgment)  │
│                                         │
│  - fetch issue + comments               │
│  - understand task                      │
│  - assess dependencies                  │
│  - implement                            │
│  - create PR                            │
│  - handle review feedback               │
│  - handle CI failures                   │
│  - rebase, merge, or escalate           │
└─────────────────────────────────────────┘
```

### Benefits

- **Adaptive:** Formula refinements propagate instantly. No bash deploy needed.
- **Learnable:** When an agent handles a new situation well, capture it in the formula.
- **Debuggable:** Formula steps are human-readable. Bash state machines are not.
- **Generalizable:** Same orchestrator, different formulas for different agents.

### Risks and mitigations

- **Fragility:** Claude might misinterpret a formula step → Phase protocol is the safety net. No phase signal = stall detected = supervisor escalates.
- **Cost:** More Claude turns = more tokens → Offset by eliminating bash dead-ends that waste whole sessions.
- **Non-determinism:** Same formula might produce different results → Success criteria in each step make pass/fail unambiguous.

## Applying This Principle

When reviewing PRs or designing new agents, ask:

1. **Does this bash code make a judgment call?** → Move it to the formula.
2. **Does this formula step do something mechanical?** → Move it to the orchestrator.
3. **Is a new `if/else` being added to handle an edge case?** → That's a formula learning, not an orchestrator feature.
4. **Can this agent's bash be reused by another agent type?** → Good sign — the orchestrator is properly thin.

## Current State

| Agent | Lines | Judgment in bash | Target |
|-------|-------|------------------|--------|
| dev-agent | 1380 (agent 732 + phase-handler 648) | Heavy — deps, CI retry, review parsing, merge strategy, recovery mode | Thin orchestrator + formula |
| review-agent | 870 | Heavy — diff analysis, review decision, approve/request-changes logic | Needs assessment |
| supervisor | 877 | Heavy — multi-project health checks, CI stall detection, container monitoring | Partially justified (monitoring is deterministic, but escalation decisions are judgment) |
| gardener | 1242 (agent 471 + poll 771) | Medium — backlog triage, duplicate detection, tech-debt scoring | Poll is heavy orchestration; agent is prompt-driven |
| vault | 442 (4 scripts) | Medium — approval flow, human gate decisions | Intentionally bash-heavy (security gate should be deterministic) |
| planner | 382 | Medium — AGENTS.md update, gap analysis | Migrating to tmux+formula (#232) |
| action-agent | 192 | Light — formula execution | Close to target |
