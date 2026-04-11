<!-- last-reviewed: 8137410e7e62fb9862cac2c1917ee56f3876d9d7 -->
# Architect — Agent Instructions

## What this agent is

The architect is a strategic decomposition agent that breaks down vision issues
into development sprints. It proposes sprints via PRs on the ops repo and
converses with humans through PR comments.

## Role

- **Input**: Vision issues from VISION.md, prerequisite tree from ops repo
- **Output**: Sprint proposals as PRs on the ops repo, sub-issue files
- **Mechanism**: Bash-driven orchestration in `architect-run.sh`, pitching formula via `formulas/run-architect.toml`
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

The architect pitching is driven by `formulas/run-architect.toml`. This formula defines
the steps for:
- Research: analyzing vision items and prerequisite tree
- Pitch: creating structured sprint PRs
- Sub-issue filing: creating concrete implementation issues

## Bash-driven orchestration

Bash in `architect-run.sh` handles state detection and orchestration:

- **Deterministic state detection**: Bash reads the Forgejo reviews API to detect
  ACCEPT/REJECT decisions — no model-dependent API parsing
- **Human guidance injection**: Review body text from ACCEPT reviews is injected
  directly into the research prompt as context
- **Response processing**: When ACCEPT/REJECT responses are detected, bash invokes
  the agent with appropriate context (session resumed for questions phase)

### State transitions

```
New vision issue → pitch PR (model generates pitch, bash creates PR)
  ↓
APPROVED review → start design questions (model posts Q1:, adds Design forks section)
  ↓
Answers received → continue Q&A (model processes answers, posts follow-ups)
  ↓
All forks resolved → sub-issue filing (model files implementation issues)
  ↓
REJECT review → close PR + journal (model processes rejection, bash merges PR)
```

### Session management

The agent maintains a global session file at `/tmp/architect-session-{project}.sid`.
When processing responses, bash checks if the PR is in the questions phase and
resumes the session using `--resume session_id` to preserve codebase context.

## Execution

Run via `architect/architect-run.sh`, which:
- Acquires a poll-loop lock (via `acquire_lock`) and checks available memory
- Cleans up per-issue scratch files from previous runs (`/tmp/architect-{project}-scratch-*.md`)
- Sources shared libraries (env.sh, formula-session.sh)
- Uses FORGE_ARCHITECT_TOKEN for authentication
- Processes existing architect PRs via bash-driven design phase
- Loads the formula and builds context from VISION.md, AGENTS.md, and ops repo
- Bash orchestrates state management:
  - Fetches open vision issues, open architect PRs, and merged sprint PRs from Forgejo API
  - Filters out visions already with open PRs, in-progress label, sub-issues, or merged sprint PRs
  - Selects up to `pitch_budget` (3 - open architect PRs) remaining vision issues
  - For each selected issue, invokes stateless `claude -p` with issue body + context
  - Creates PRs directly from pitch content (no scratch files)
- Agent is invoked only for response processing (ACCEPT/REJECT handling)

**Multi-sprint pitching**: The architect pitches up to 3 sprints per run. Bash handles all state management:
- Fetches Forgejo API data (vision issues, open PRs, merged PRs)
- Filters and deduplicates (no model-level dedup or journal-based memory)
- For each selected vision issue, bash invokes stateless `claude -p` to generate pitch markdown
- Bash creates the PR with pitch content and posts ACCEPT/REJECT footer comment
- Branch names use issue number (architect/sprint-vision-{issue_number}) to avoid collisions

## Schedule

The architect runs every 6 hours as part of the polling loop in
`docker/agents/entrypoint.sh` (iteration math at line 196-208).

## State

Architect state is tracked in `state/.architect-active` (disabled by default —
empty file not created, just document it).

## Related issues

- #96: Architect agent parent issue
- #100: Architect formula — research + design fork identification
- #101: Architect formula — sprint PR creation with questions
- #102: Architect formula — answer parsing + sub-issue filing
- #491: Refactor — bash-driven design phase with stateful session resumption
