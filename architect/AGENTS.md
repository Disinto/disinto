<!-- last-reviewed: 1e3e3e61f2c6585d5279b6cc46c8cdb20a760f6c -->
# Architect — Agent Instructions

## What this agent is

The architect is the design-Q&A agent for vision sprints. It operates on existing
architect sprint PRs (created by the gardener) and converses with humans through
PR comments to refine the sprint proposal toward a concrete sub-issue decomposition.

Vision pitching (creating new sprint PRs from open vision issues) is owned by
the gardener via `formulas/pitch-vision.toml` (#871, #877, #897). The
architect no longer generates pitches.

## Role

- **Input**: Existing open architect sprint PRs on the ops repo, plus VISION.md and prerequisite-tree context
- **Output**: PR-comment Q&A on existing architect PRs; finalized `## Sub-issues` block in the sprint spec once design forks are resolved
- **Mechanism**: Bash-driven state machine in `architect/architect-run.sh`, response/Q&A formula via `formulas/run-architect.toml`
- **Identity**: `architect-bot` on Forgejo (READ-ONLY on project repo, write on ops repo only — #764)

## Lifecycle states

The architect operates on the ops repo PRs through four states. Each iteration
picks the head of a round-robin queue (sorted by `<!-- architect-last-seen: -->`
marker ascending), detects the state, and dispatches the appropriate action.

### [q_and_a] — Design Q&A

**Entry conditions**: PR is open, no APPROVED review on Forgejo, new operator
comment since last-seen marker.

**Actions**:
- If comment starts with `Reject:` → close PR with a closure comment quoting the
  reason. **Bash-only — no model call.**
- Otherwise → opus session: read pitch + new comment + transcript, refine the
  `<!-- filer:begin -->` ... `<!-- filer:end -->` block inline, post a reply
  comment.

**Exit conditions**:
- Reject: → PR closed (terminal)
- New engagement → stay in q_and_a
- APPROVED review → transitions to approved_idle

### [approved_idle] — Awaiting filer

**Entry conditions**: Forgejo review state == APPROVED, no `## Filed:` marker
in PR body.

**Actions**: Post one "Approved — awaiting filer" comment per rotation pass.
**Bash-only — no model call.**

**Exit conditions**: `## Filed: #N1 #N2 ...` marker injected by filer-bot →
transitions to tracking

### [tracking] — Sub-issue progress

**Entry conditions**: `## Filed: #N1 #N2 ...` marker present, not all listed
sub-issues are green.

**Actions**:
- For each sub-issue: read state (open/closed), check for `deployed` label,
  run `tests/acceptance/issue-<n>.sh` and capture rc.
- "Green" = closed AND has `deployed` label AND acceptance test rc=0.
- If state changed since last digest comment → opus session writes one digest
  comment.
- If no state change → skip opus call.

**Exit conditions**: All listed sub-issues green → transitions to mergeable

### [mergeable] — Auto-merge

**Entry conditions**: `## Filed:` marker present, all listed sub-issues green.

**Actions**: Merge ops PR. Post closure summary comment. **Bash-only — no model
call.**

## Round-robin scheduling

Each polling iteration:
1. List open `architect:`-prefixed PRs on ops repo
2. Sort by `<!-- architect-last-seen: <iso8601> -->` marker in PR body, ascending
3. Pick the head of the queue
4. Detect state, dispatch action
5. PATCH PR body to update the last-seen marker — cursor advances every iteration
   whether work happened or not

`approved_idle` PRs DO consume a slot and re-enter the back of the queue. This
prevents the architect from idling on a single waiting PR while others have new
state.

## Signal model

| Signal | Source | Effect |
|---|---|---|
| Operator comment without `Reject:` prefix | ops PR comment thread | q_and_a engagement, opus session |
| Operator comment starting `Reject:` | ops PR comment thread | close PR, no opus |
| Forgejo APPROVED review state | ops PR review | enters approved_idle |
| `## Filed: #N1 #N2 ...` marker in PR body | filer-bot writes (companion issue) | enters tracking |
| `deployed` label on sub-issue | external deploy script | tracking gate |
| `tests/acceptance/issue-<n>.sh` rc=0 | acceptance test | tracking gate |

## Write-permission contract

Architect remains read-only on the project repo. Architect's writes:
- **ops repo**: PATCH PR body, POST comments, close PR, merge PR
- **project repo**: NONE (only reads — issue states, acceptance scripts, vision
  titles/bodies for grounding)

The `check_architect_issue_filing` regression guard scans the architect log for
any POST to the project repo's `/issues` endpoint and fails loudly on detection.

## Formula

Architect response/Q&A is driven by `formulas/run-architect.toml`. This formula
defines the steps for:
- Design Q&A: refining the sprint via PR comments after human engagement
- Sub-issue finalization: writing the `## Sub-issues` block once forks are resolved
- Tracking digests: summarizing sub-issue progress

Vision pitching is owned by the gardener (`formulas/pitch-vision.toml` —
#871, #877, #897), not by this formula.

## Bash-driven orchestration

Bash in `architect/architect-run.sh` handles state detection and orchestration:

- **Deterministic state machine**: Bash reads the Forgejo reviews API to detect
  APPROVED state — the review state, not comment text, drives lifecycle transitions
- **Reject detection**: `Reject:`-prefixed comments trigger PR close (bash-only)
- **Round-robin**: PRs sorted by last-seen marker; head of queue processed per tick
- **Last-seen cursor**: `<!-- architect-last-seen: ... -->` updated every iteration
- **Opus gating**: Model only called when actual engagement or state change detected
- **Bash-only paths**: Reject handling, approved_idle, mergeable — no model overhead

### State transitions

```
Sprint PR created by gardener (formulas/pitch-vision.toml — #871, #877, #897)
  ↓
q_and_a ←→ q_and_a (operator engagement, design conversation)
  ↓ APPROVED review
approved_idle ←→ approved_idle (bash: "awaiting filer" comment per rotation)
  ↓ filer-bot injects ## Filed: #N1 #N2 ...
tracking ←→ tracking (opus: digest when state changes; bash: check green)
  ↓ all sub-issues green
mergeable → PR merged (bash-only)
  ↓
Reject: comment at any point → PR closed (bash-only)
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

## Schedule

The architect runs every 15 minutes as part of the polling loop in
`docker/agents/entrypoint.sh` (iteration math at line 603-614). Configurable
via `ARCHITECT_INTERVAL` environment variable (default: 900 = 15 minutes).

## State

Architect state is tracked in `state/.architect-active` (disabled by default —
empty file not created, just document it).

## Related issues

- #96: Architect agent parent issue
- #100: Architect formula — research + design fork identification
- #101: Architect formula — sprint PR creation with questions
- #102: Architect formula — answer parsing + sub-issue filing
- #764: Permission scoping — architect read-only on project repo, filer-bot files sub-issues
- #897: Vision pitching moved to gardener
- #901: Forgejo-state-driven lifecycle rewrite (Q&A + tracking + auto-merge)
