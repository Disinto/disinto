<!-- last-reviewed: 19e7acf8ab5e0b8fa87a6881e636e502d34a2911 -->
# Architect — Agent Instructions

## What this agent is

The architect is the design-Q&A agent for vision sprints. It converses with
humans on existing architect sprint PRs (created by the gardener) and refines
the sprint proposal toward a concrete sub-issue decomposition.

Vision pitching (creating new sprint PRs from open vision issues) is owned by
the gardener via `formulas/pitch-vision.toml` (#871, #877, #897). The
architect no longer generates pitches.

## Role

- **Input**: Existing open architect sprint PRs on the ops repo (created by the gardener), plus VISION.md and prerequisite-tree context
- **Output**: PR-comment Q&A on existing architect PRs; finalized `## Sub-issues` block in the sprint spec once design forks are resolved
- **Mechanism**: Bash-driven orchestration in `architect-run.sh`, response/Q&A formula via `formulas/run-architect.toml`
- **Identity**: `architect-bot` on Forgejo (READ-ONLY on project repo, write on ops repo only — #764)

## Responsibilities

1. **Design fork identification**: On approved sprint PRs, identify the design
   decisions that need human input and post initial questions
2. **Human conversation**: Respond to PR comments, refine sprint proposals based
   on human feedback (Q&A loop)
3. **Sub-issue definition**: Once design forks are resolved, finalize concrete
   sub-issues in the `## Sub-issues` block of the sprint spec. Filing is
   handled by `filer-bot` after sprint PR merge (#764)
4. **ACCEPT/REJECT response handling**: Process formal APPROVED reviews and
   typed `ACCEPT`/`REJECT:` comments on existing architect PRs

## Formula

Architect response/Q&A is driven by `formulas/run-architect.toml`. This formula defines
the steps for:
- Design Q&A: refining the sprint via PR comments after human ACCEPT
- Sub-issue finalization: writing the `## Sub-issues` block once forks are resolved
- ACCEPT/REJECT response processing on open architect PRs

Vision pitching is owned by the gardener (`formulas/pitch-vision.toml` —
#871, #877, #897), not by this formula.

## Bash-driven orchestration

Bash in `architect-run.sh` handles state detection and orchestration:

- **Deterministic state detection**: Bash reads the Forgejo reviews API to detect
  ACCEPT/REJECT decisions — checks both formal APPROVED reviews and PR comments, not just comments (#718)
- **Human guidance injection**: Review body text from ACCEPT reviews is injected
  directly into the research prompt as context
- **Response processing**: When ACCEPT/REJECT responses are detected, bash invokes
  the agent with appropriate context (session resumed for questions phase)
- **PR URL construction**: existing-PR check uses `${FORGE_API}/pulls` directly (not `${FORGE_API}/repos/…`) — the base URL already includes the repos segment (#717)

### State transitions

```
Sprint PR created by gardener (formulas/pitch-vision.toml — #871, #877, #897)
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
  - Scans open architect PRs on the ops repo for ACCEPT/REJECT/APPROVED responses
  - Skips cleanly when there are no responses to process (early exit before invoking the model)
  - Picks the appropriate session mode (`fresh`, `start_questions`, `questions_phase`) and resumes the per-PR session when continuing Q&A
- Agent is invoked only for response processing (ACCEPT/REJECT handling, design Q&A)
- NOTE: architect-bot is read-only on the project repo (#764) — sub-issue filing
  and in-progress label management are handled by filer-bot after sprint PR merge
- NOTE: vision pitching is handled by the gardener (`formulas/pitch-vision.toml` — #871, #877, #897); the architect no longer reads vision issues or creates sprint PRs

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
