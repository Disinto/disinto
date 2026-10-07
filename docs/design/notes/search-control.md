# Search control (experiment sprints and repair only)

Moved from `proposal-loop.md` §13, 2026-09-30, and updated: the hunt
level is gone; research is an experiment-class sprint.

Concluded September 2026 against Dream-RSI (Zheng et al., arXiv
2609.14858) and the proposal-loop forest. The steal is the tree
*shape*, not their meta-loop.

The forest is **composition**. Siblings are parts. Replay of
exploration needs siblings that are **rivals**: alternative attempts
at the same objective, each with a score, each started from some
earlier attempt's workspace. Those are different relations. Putting
search-control records on composition parents does not make a search
tree.

## Where

- experiment sprints: experiment runs under one sprint
- repair: remedies under one incident
- nowhere else. A sprint of unlike issues is not a search tree. A dev
  issue's inner retries stay `run.attempts`. Transcripts stay
  payloads.

## Shape, when it exists

One experiment sprint (or repair) = one search tree. It is a
**projection** of that parent's child proposals, not a fifth record
family and not a blob store.

```text
root = the experiment sprint
 ├─ run A          continued_from empty     # new branch
 │    └─ run A2    continued_from = A       # refine A
 └─ run B          continued_from empty     # other branch
```

**Bouquet of chains.** Only the root may have several search-children.
A non-root attempt has at most one continuation. To fork a workspace,
open a new root-child — do not split a node. (This is the paper's
`Child(v)`: unique recorded child off a non-root; earliest unrevealed
child off the root.)

Three pointers, orthogonal:

| field | relation |
|---|---|
| `parent` | composition — this run serves this sprint |
| `caused_by` | causation — this repair answers that failure |
| `continued_from` | search — this attempt resumed that attempt |

`continued_from` is nullable and legal only on experiment-sprint and
repair children. The tree id is the sprint's proposal id. Order among
siblings of the same `continued_from` (empty = branches of the root)
is tape time. Score on a run is its own `outcome.numbers` (the eval
metric). The sprint's effect and grade stay on the sprint. Workspace
state is a payload hash, not a field.

## Replay (not built)

Eligible set = {root} ∪ current leaves of chains. Expand the root →
new branch. Expand a leaf → its unique continuation, or nothing.
Replay reveals only recorded children, in recorded order. Unseen
branches do not exist — the same honesty constraint the design took
from PPM.

Width on this deployment is 1. Parallel batching is not a decision
until a second worker is real; do not log it, do not reward it.

The exploration policy is a **named heuristic**, competing on the
calibration table like every other predictor (refine-while-moving;
open-or-stop-on-plateau). Not LLM-written controller code. Not a
prompt stuffed with prior "insights" — that over-constrains parallel
threads; the paper measured it and it lost.

## When to build

Do not add `continued_from`. Do not add an `alloc` record. Add
`continued_from` the first time an experiment sprint actually launches
a second run as a rival or a refinement. The selenocyte stack is the
likely first tenant: its hunts today (teacher batches, mesh rounds,
kept/dropped) are exactly this shape, run by hand. Until then the field
is fiction, and a writer with no callers is a stub.
