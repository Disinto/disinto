<!-- last-reviewed: b5884e28b6016ce03ed6195e276bf6b24e046354 -->
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
- **Mechanism**: Bash-driven state machine in `architect/architect-run.sh`, response/Q&A formula via `formulas/run-architect.toml` (always loaded — the kind selection was removed, #1335)
- **Identity**: `architect-bot` on Forgejo (READ-ONLY on project repo, write on ops repo only — #764)

## Lifecycle states

The architect operates on the ops repo PRs through two states, decompose and
q_and_a; the owner merges the PR (the decision) or closes it. Each iteration
picks the head of a round-robin queue (sorted by `<!-- architect-last-seen: -->`
marker ascending), detects the state, and dispatches the appropriate action.

### [decompose] — First draft (#1910)

**Entry**: the PR adds `sprints/<slug>.md`; on the PR branch, that file has a
sprint block and no sub-issue entries; `architect-bot` has not commented yet.

**Action**: a session (formula steps `ground`, `draft`, `lint`, `reply`) writes
the `## Sub-issues` block into a local copy. Bash commits the changed file to the
PR branch through the contents API, as `architect-bot`, and posts the reply with
the `tools/pitch-lint.sh` report. No tape record: an undecided pitch serves no
proposal.

### [q_and_a] — Design Q&A

**Entry conditions**: PR is open, a new comment by
anyone but the architect (`architect-bot`) since the
last-seen marker.

**Actions**:
- If comment starts with `Reject:` → close PR with a closure comment quoting the
  reason. **Bash-only — no model call.**
- Otherwise → a session reads the pitch file from the PR branch, the new
  comments and the open backlog, and revises the sub-issue block (or drafts
  it). Bash commits a changed file to the PR branch as `architect-bot` and
  posts the session's reply with the lint report, as in decompose (#1911).

**Exit conditions**:
- Reject: → PR closed (terminal)
- New engagement → stay in q_and_a

## Round-robin scheduling

Each polling iteration:
1. List open `architect:`-prefixed PRs on ops repo
2. Sort by `<!-- architect-last-seen: <iso8601> -->` marker in PR body, ascending
3. Pick the head of the queue
4. Detect state, dispatch action
5. PATCH PR body to update the last-seen marker — cursor advances every iteration
   whether work happened or not

## Signal model

| Signal | Source | Effect |
|---|---|---|
| Comment without `Reject:` prefix, not by `architect-bot` | ops PR comment thread | q_and_a engagement, opus session |
| Comment starting `Reject:`, not by `architect-bot` | ops PR comment thread | close PR, no opus |

## Write-permission contract

Architect remains read-only on the project repo. Architect's writes:
- **ops repo**: PATCH PR body, POST comments, close PR. It never merges: merging
  a pitch is the owner's decision (#1907)
- **project repo**: NONE (only reads — issue states, acceptance scripts, vision
  titles/bodies for grounding)

The `check_architect_issue_filing` regression guard scans the architect log for
any POST to the project repo's `/issues` endpoint and fails loudly on detection.

## Formula

**Formula (#1335)**: `architect-run.sh` always loads `formulas/run-architect.toml`,
before any dispatch — the kind selection from #1315 is gone: oak instances
differ by `ops/pack.toml`, not by a project kind, so research boxes run the
same formula.

`formulas/run-architect.toml` defines the steps for:
- `ground`, `draft`, `lint`, `reply`: draft the sub-issues of a pitch that has none, or revise them on the owner's comments, by `docs/design/notes/issue-writing.md`; bash commits the pitch file and posts the reply (#1909)

Vision pitching is owned by the gardener (`formulas/pitch-vision.toml` —
#871, #877, #897), not by the formula.

## Bash-driven orchestration

Bash in `architect/architect-run.sh` handles state detection and orchestration:

- **Deterministic state machine**: bash reads the PR's comments; the owner's merge or close ends the lifecycle
- **Reject detection**: `Reject:`-prefixed comments trigger PR close (bash-only)
- **Round-robin**: PRs sorted by last-seen marker; head of queue processed per tick
- **Last-seen cursor**: `<!-- architect-last-seen: ... -->` updated every iteration
- **Opus gating**: Model only called when actual engagement or state change detected
- **Bash-only paths**: Reject handling — no model overhead

### State transitions

```
Sprint PR on the ops repo (adds sprints/<slug>.md)
  ↓
decompose (first draft) → q_and_a (operator engagement, design conversation)
  ↓
the owner merges it (the gardener files the sprint, #1892) or closes it
Reject: comment at any point → PR closed (bash-only)
```

### Vision issue lifecycle

Vision issues decompose into sprint sub-issues. Sub-issues are defined in the
`## Sub-issues` block of the sprint spec (between `<!-- filer:begin -->` and
`<!-- filer:end -->` markers) and filed by `filer-bot` after the sprint PR merges
on the ops repo (#764).

The sprint spec also carries its sprint block between `<!-- sprint:begin -->`
and `<!-- sprint:end -->`: the `class`, `effect`, `expect`, `soak` and optional
`rests_on` lines of a sprint milestone's description (`lib/sprint-block.sh`).
Its purpose is the first paragraph under `## What this enables`. `lib/pitch.sh`
reads both.

Each filer-created sub-issue carries a `<!-- decomposed-from: #<vision>, sprint: <slug>, id: <id> -->`
marker in its body for idempotency and traceability.
A sub-issue filed with the sprint's milestone carries `<!-- decomposed-from: milestone:<id>, sprint: <slug>, id: <id> -->` instead, and the vision steps below do not apply to it.

The filer-bot (via `lib/sprint-filer.sh`) handles vision lifecycle:
1. After filing sub-issues, adds `in-progress` label to the vision issue
2. On each run, checks if all sub-issues for a vision are closed
3. If all closed, posts a summary comment and closes the vision issue

The architect no longer writes to the project repo — it is read-only (#764).
All project-repo writes (issue filing, label management, vision closure) are
handled by filer-bot with its narrowly-scoped `FORGE_FILER_TOKEN`.

## Schedule

The architect is poked by the polling loop in `docker/agents/entrypoint.sh`
on the ARCHITECT_INTERVAL cadence (default 15 min, #1388): the entrypoint
starts `architect-run.sh` in the background (guarded by `pgrep`), and the
script's own Forgejo state machine decides what each poke does. The `architect`
role in `AGENT_ROLES` gates it.

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
- #1294: project TOML `kind` — research vs software boxes (superseded: the kind key and its env var were removed in #1338)
- #1295: experiment issue template + research labels (`experiment` label)
- #1315: research-mode architect — kind-selected formula, experiment filer entries, run-ledger tracking green (formula + green-gate kind selection superseded by #1335)
- #1335: architect always uses run-architect.toml; research formula deleted
