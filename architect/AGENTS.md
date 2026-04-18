<!-- last-reviewed: b05a31197cc78aa28f3c3e6365e782032bfb25af -->
# Architect — Agent Instructions

## What this agent is

The architect is a strategic decomposition agent that breaks down vision issues
into development sprints. It proposes sprints via PRs on the ops repo and
converses with humans through PR comments.

## Role

- **Input**: Vision issues from VISION.md, prerequisite tree from ops repo
- **Output**: Sprint proposals as PRs on the ops repo (with embedded `## Sub-issues` blocks)
- **Mechanism**: Bash-driven orchestration in `architect-run.sh`, pitching formula via `formulas/run-architect.toml`
- **Identity**: `architect-bot` on Forgejo (READ-ONLY on project repo, write on ops repo only — #764)

## Responsibilities

1. **Strategic decomposition**: Break down large vision items into coherent
   sprints that can be executed by the dev agent
2. **Design fork identification**: When multiple implementation approaches exist,
   identify the forks and file sub-issues for each path
3. **Sprint PR creation**: Propose sprints as PRs on the ops repo with clear
   acceptance criteria and dependencies
4. **Human conversation**: Respond to PR comments, refine sprint proposals based
   on human feedback
5. **Sub-issue definition**: Define concrete sub-issues in the `## Sub-issues`
   block of the sprint spec. Filing is handled by `filer-bot` after sprint PR
   merge (#764)

## Formula

The architect pitching is driven by `formulas/run-architect.toml`. This formula defines
the steps for:
- Research: analyzing vision items and prerequisite tree
- Pitch: creating structured sprint PRs with embedded `## Sub-issues` blocks
- Design Q&A: refining the sprint via PR comments after human ACCEPT

## Bash-driven orchestration

Bash in `architect-run.sh` handles state detection and orchestration:

- **Deterministic state detection**: Bash reads the Forgejo reviews API to detect
  ACCEPT/REJECT decisions — checks both formal APPROVED reviews and PR comments, not just comments (#718)
- **Human guidance injection**: Review body text from ACCEPT reviews is injected
  directly into the research prompt as context
- **Response processing**: When ACCEPT/REJECT responses are detected, bash invokes
  the agent with appropriate context (session resumed for questions phase)
- **Pitch capture**: `pitch_output` is written to a temp file instead of captured via `$()` subshell, because `agent_run` writes to side-channels (`SID_FILE`, `LOGFILE`) that subshell capture would suppress (#716)
- **PR URL construction**: existing-PR check uses `${FORGE_API}/pulls` directly (not `${FORGE_API}/repos/…`) — the base URL already includes the repos segment (#717)

### State transitions

```
New vision issue → pitch PR (model generates pitch, bash creates PR)
  ↓
APPROVED review → start design questions (model posts Q1:, adds Design forks section)
  ↓
Answers received → continue Q&A (model processes answers, posts follow-ups)
  ↓
All forks resolved → finalize ## Sub-issues section in sprint spec
  ↓
Sprint PR merged → filer-bot files sub-issues on project repo (#764)
  ↓
REJECT review → close PR + journal (model processes rejection, bash merges PR)
```

### Vision issue lifecycle

Vision issues decompose into sprint sub-issues. Sub-issues are defined in the
`## Sub-issues` block of the sprint spec (between `<!-- filer:begin -->` and
`<!-- filer:end -->` markers) and filed by `filer-bot` after the sprint PR merges
on the ops repo (#764).

Each filer-created sub-issue carries a `<!-- decomposed-from: #<vision>, sprint: <slug>, id: <id> -->`
marker in its body for idempotency and traceability.

The filer-bot (via `lib/sprint-filer.sh`) handles vision lifecycle:
1. After filing sub-issues, adds `in-progress` label to the vision issue
2. On each run, checks if all sub-issues for a vision are closed
3. If all closed, posts a summary comment and closes the vision issue

The architect no longer writes to the project repo — it is read-only (#764).
All project-repo writes (issue filing, label management, vision closure) are
handled by filer-bot with its narrowly-scoped `FORGE_FILER_TOKEN`.

### Session management

The agent maintains a global session file at `/tmp/architect-session-{project}.sid`.
When processing responses, bash checks if the PR is in the questions phase and
resumes the session using `--resume session_id` to preserve codebase context.

## Execution

Run via `architect/architect-run.sh`, which:
- Acquires a poll-loop lock (via `acquire_lock`) and checks available memory
- Cleans up per-issue scratch files from previous runs (`/tmp/architect-{project}-scratch-*.md`)
- Sources shared libraries (env.sh, formula-session.sh)
- Exports `FORGE_TOKEN_OVERRIDE="${FORGE_ARCHITECT_TOKEN}"` BEFORE sourcing env.sh, ensuring architect-bot identity survives re-sourcing (#762)
- Uses FORGE_ARCHITECT_TOKEN for authentication
- Processes existing architect PRs via bash-driven design phase
- Loads the formula and builds context from VISION.md, AGENTS.md, and ops repo
- Bash orchestrates state management:
  - Fetches open vision issues, open architect PRs, and merged sprint PRs from Forgejo API
  - Filters out visions already with open PRs, in-progress label, sub-issues, or merged sprint PRs
  - Selects up to `pitch_budget` (3 - open architect PRs) remaining vision issues
  - For each selected issue, invokes stateless `claude -p` with issue body + context
  - Creates PRs directly from pitch content (no scratch files)
- Agent is invoked for stateless pitch generation and response processing (ACCEPT/REJECT handling)
- NOTE: architect-bot is read-only on the project repo (#764) — sub-issue filing
  and in-progress label management are handled by filer-bot after sprint PR merge

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
- #764: Permission scoping — architect read-only on project repo, filer-bot files sub-issues
- #491: Refactor — bash-driven design phase with stateful session resumption
