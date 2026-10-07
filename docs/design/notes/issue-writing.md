# Issue writing

Moved from `proposal-loop.md` §3 (scope discipline), 2026-09-30, with
what the 2026-09 sprints taught. The design keeps one rule: small,
uniform completions are the statistics, and the implementer rejects
what it cannot digest (`scope-explosion`, counted against the
proposal). This note is how to write issues that pass.

## Write for the slowest implementer

A proposal is written for the slowest implementer, not for the
reader. Today's implementer is a local model at ~22 tokens/s under a
2-hour wall clock; an issue that needs more than one concept dies
mid-thought, and a timeout teaches nothing about the proposal's class.
Eliminate complexity *before* filing:

- One issue = one organ, one repo, one observable behavior. "And" in
  the title is two issues.
- Two files touched is the ceiling, not the floor (the acceptance test
  does not count). New vocabulary (a rubric, a pack, a block format)
  and new behavior never share an issue.
- Cross-repo writes are out of scope for dev issues. Ops-repo files
  (packs, rubrics, probes) are created by an ops PR a human merges;
  code references them.
- The body lands whole in the implementer's prompt: ≤ 100 lines.
  Reference code by path, don't explain the architecture.
- Acceptance = one command whose output can be checked. If you cannot
  name it, the issue is not ready.
- No human steps, no deploy gates. A backlog issue is pure
  code-into-repo; anything a bot cannot do in CI does not belong in
  the body. Deploys, restarts and probes happen out of band after
  merge — mentioning them arms the reviewer's deploy gate and
  livelocks the loop (observed on #1411).
- Split triggers, mechanical: > 2 files, > 1 concept, a repo boundary,
  or a spec you cannot read aloud without a breath.
- Two files is not small when one of them is a large jq program. #1615
  (a counting change inside the 297-line `tools/calibration.sh`) ran
  the local model into 2-hour timeouts five times on 2026-09-30 and
  never refused. Prefer a new small file with one function over an
  edit deep inside a big one. The pattern that replaced it: a separate
  tool computes the new thing, and the big file gets an exactly spelled
  wiring edit (#1648/#1649), or none at all — calibration columns are
  appended to the finished table by their own tools (#1650–#1652).

## Disinto conventions (learned 2026-09)

- Headings the gardener and implementer rely on: `## Problem`,
  `## Proposed solution`, `## Affected files`, `## Documentation`,
  `## Existing tests` (when existing code changes), `## Acceptance criteria`
  (at least one `- [ ]`), `## Acceptance test` (one line naming
  `tests/acceptance/issue-<N>.sh`).
- `## Dependencies` is **blocking**: `lib/parse-deps.sh` also treats
  inline "depends on #N" and "blocked by #N" as blocking. Use
  `## Related` for references that must not block.
- `## Documentation`: name the `AGENTS.md` (or `docs/`) sentence the
  change makes wrong, and give the new wording. The reviewer sends
  back any behaviour change whose doc is not updated in the same PR
  (review formula 3b); on 2026-10-02 that cost #1672 three rounds and
  #1677 and #1681 one each, each round over an hour. When nothing
  documents the code yet, write "None" and why.
- Never anchor additions from different issues at the same spot. On
  2026-10-03 several issues said "add a row after `lib/sprint-tape.sh`"
  in `lib/AGENTS.md`; PRs written in parallel then conflict (#1700 vs
  #1699), and a conflicting PR fails to merge and is not retried. Give
  each issue its own anchor row, not adjacent to another open issue's
  anchor or to a row another open issue edits. The `lib/AGENTS.md` table
  is not sorted, so "alphabetical" is no guide.
- `## Existing tests`: list the tests that already cover the code you
  change (`grep -rl <function> tests/`), so the implementer runs them
  and updates any that pin the old behaviour. #1672 broke
  `issue-1613.sh` that way, and the review caught it a round later.
  Grep for the code's shape too, not only its name. Many acceptance
  tests grep source text (`^repair_tape_tick$`, a line to extract)
  and break when the code is indented, gated or removed: #1713 broke
  `issue-1408.sh`, #1646 broke `issue-1478.sh`, and #1337 broke
  `issue-1295.sh`. Acceptance tests run once, after their own merge,
  so nothing reruns them. The 2026-10-04 sweep of all 178 on main
  found five stale (#1750–#1753, plus `issue-1537.sh`).
- Acceptance tests are bash, `set -euo pipefail`, source
  `tests/lib/acceptance-helpers.sh`, end with `ac_pass`. Stub forge
  calls with `ac_write_curl_stub` / `ac_extract_fn`;
  `tests/acceptance/issue-1598.sh` is the model. CI rejects new
  duplicate 5-line windows, so reuse helpers instead of copying.
  Since PR #1763, CI runs a test on every PR that changes a path the
  test names, inside `disinto/agents:local`, which has no forge, no
  nomad and no daemon env. When the test needs the live box, the issue
  must say so: "header line `# acceptance-ci: skip (<what it needs>)`".
- Labels `formula`, `vision`, `experiment`, `run`, `judgment`,
  `bug-report` make an issue unclaimable.
- File an issue body unlabeled when it still has placeholders; add
  `backlog` last. A backlog issue can be picked within minutes.
- File under the proposer's forge account. The proposer is derived
  from the author: an organ files as its bot (`gardener-bot`,
  `architect-bot`, …); the human, and any agent session working for
  the human, files as `disinto-admin`. Never file as `dev-bot`, the
  implementer. (#1605–#1629 were; #1630 onward are right.)
- To reject an issue, label it `rejected` and close it
  (`prediction/dismissed` for predictor issues). The gardener records
  the rejection on the tape.

## Sprints

A sprint is a milestone. Put the sprint block in its description when
you create it (`class`, `effect`, `expect`, `soak`, optional
`rests_on`; see `proposal-loop.md` §2). Issues added to the milestone
take its class and the claims it rests on. If a claim it rests on is
challenged, the sprint returns and its queued issues leave the
backlog.
The probe the block names must already exist in the ops repo's
`probes/`, merged by a human.
