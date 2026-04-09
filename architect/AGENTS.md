<!-- last-reviewed: d5e63a801ed48f9bd54c77e4915bc076b7490958 -->
# Architect — Agent Instructions

## What this agent is

The architect is a strategic decomposition agent that breaks down vision issues
into development sprints. It proposes sprints via PRs on the ops repo and
converses with humans through PR comments.

## Role

- **Input**: Vision issues from VISION.md, prerequisite tree from ops repo
- **Output**: Sprint proposals as PRs on the ops repo, sub-issue files
- **Mechanism**: Formula-driven execution via `formulas/run-architect.toml`
- **Identity**: `architect-bot` on Forgejo

## Responsibilities

1. **Strategic decomposition**: Break down large vision items into coherent
   sprints that can be executed by the dev agent
2. **Design fork identification**: When multiple implementation approaches exist,
   identify the forks and file sub-issues for each path
3. **Sprint PR creation**: Propose sprints as PRs on the ops repo with clear
   acceptance criteria and dependencies
4. **Human conversation**: Respond to PR comments, refine sprint proposals based
   on human feedback
5. **Sub-issue filing**: After design forks are resolved, file concrete sub-issues
   for implementation

## Formula

The architect is driven by `formulas/run-architect.toml`. This formula defines
the steps for:
- Research: analyzing vision items and prerequisite tree
- Design: identifying implementation approaches and forks
- Sprint proposal: creating structured sprint PRs
- Sub-issue filing: creating concrete implementation issues

## Execution

Run via `architect/architect-run.sh`, which:
- Acquires a cron lock and checks available memory
- Cleans up per-issue scratch files from previous runs (`/tmp/architect-{project}-scratch-*.md`)
- Sources shared libraries (env.sh, formula-session.sh)
- Uses FORGE_ARCHITECT_TOKEN for authentication
- Loads the formula and builds context from VISION.md, AGENTS.md, and ops repo
- Executes the formula via `agent_run`

**Multi-sprint pitching**: The architect pitches up to 3 sprints per run. The pitch budget is `3 − <open architect PRs>`. After handling existing PRs (accept/reject/answer parsing), the architect selects up to `pitch_budget` vision issues (skipping any already with an open architect PR or `in-progress` label), then writes one per-issue scratch file (`/tmp/architect-{project}-scratch-{issue_number}.md`) and creates one sprint PR per scratch file.

**Session resumption (answer_parsing)**: When processing human answers on a PR in the `questions` phase (PR body has `## Design forks` + question comments), `architect-run.sh` resumes the prior Claude session (from `SID_FILE`) rather than starting fresh. This preserves deep codebase understanding from the research phase so sub-issues include specific file references.

## Cron

Suggested cron entry (every 6 hours):
```cron
0 */6 * * * cd /path/to/disinto && bash architect/architect-run.sh
```

## State

Architect state is tracked in `state/.architect-active` (disabled by default —
empty file not created, just document it).

## Related issues

- #96: Architect agent parent issue
- #100: Architect formula — research + design fork identification
- #101: Architect formula — sprint PR creation with questions
- #102: Architect formula — answer parsing + sub-issue filing
