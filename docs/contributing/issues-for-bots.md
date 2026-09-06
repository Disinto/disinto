# Filing issues the bots can actually work

Two rules, learned the hard way. They apply to humans, walk-agents, and the
gardener alike.

## 1. dev-bot implements — it does not investigate

dev-bot's loop is claim → implement → PR → CI → merge. It picks up issues
labeled `backlog` (plus `tech-debt`) and implements each one **whole**, in a
single session with a bounded context. Consequences:

- **File dev-sized tasks, not epics.** One issue = one implementable change
  with affected files and acceptance criteria (the templates below enforce
  this — use them). A 5-part epic will either stall in the queue or get
  "implemented" as the first part with the rest silently dropped.
- **Investigation first, spec second.** Anything starting with "find out…",
  "trace…", or "propose…" is not dev-work. Investigate it yourself (or hand
  it to an operator session), then file the result as a specified task with
  a finding section. Never file the question and hope.
- **Decompose, then close the epic.** When an epic exists, file the pieces,
  link them, and close the epic — a claimable epic will get claimed whole.
- **Bugs go through triage.** The bug template labels `bug-report`, which
  dev-bot deliberately does not claim (see #608). Triage reproduces and
  re-files (or re-labels) as a dev-sized `backlog` item. Don't skip this by
  labeling raw bug reports `backlog`.

## 2. Bodies are the record — comments are noise

The bots read issue **bodies** when claiming work; they do not reliably read
comment threads (long threads also burn context on every poll that lists
them). Therefore:

- **Fold updates into the body.** Status changes, refined scope, new
  findings, corrected measurements — edit the body via the API, don't
  append a comment. Keep the title accurate too.
- **No status comments, no "+1", no play-by-play.** If a human needs to know
  something, it belongs in the body where the next claimant will see it.
- **Comments are for the review trail only** (bot verdicts, CI links), never
  for carrying the task state.
