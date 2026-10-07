# The proposal loop

One mechanism for every loop the factory runs. Dev, sprint, repair,
vault, claim — the same shape at different levels and triggers. This
document defines that shape, the records it writes, and where they
are kept. It replaced the 5-minute tick learner (retired, #1390): the
unit of decision is the **proposal**, not the tick.

Every record family serves one pair:

```text
what was proposed   ↔   what came back
```

That pair is the atom of experience. A forecast is a claim about what
will come back; an outcome is what actually came back; a grade is the
human's reading of what came back. If a piece of data is not part of a
pair, it is a payload — kept for audit, never learned from directly.

**Stage.** Stage 1 writes the tape and reads one thing: the
calibration table, *promised vs. actual* per (loop, class). It is live
for dev and repair. Forecasts are off until that table is honest (§3).
Stage 2's first target is **sprint approval**: a sprint arrives with a
forecast of its effect, drawn from past sprints of its class, and the
error between forecast and measured effect calibrates whoever proposed
it — you or an agent. Claims (§6), the world model, need no forecast
and start in stage 1. The rest of the ladder, the representation
research and the open questions are in `notes/` (list at the end).

---

## 1. One shape

Every loop is five moments:

```text
propose ──► decide ──► run ──► outcome ──► (grade)
```

Loops are named by **level and trigger**, not by activity:

| loop | proposed | expected back | outcome carries |
|---|---|---|---|
| dev | a backlog issue | a merge, or a refusal with a reason | merged / rejected, signature, CI-red rounds, review rounds, duration, cost |
| sprint | a milestone with a sprint block (§2) | its effect: a measurement in deployment or an experiment result | effect met, effect value, returned, children rollup |
| repair | a remedy for a failure (`caused_by`) | the remedy's own check | remedy acted, condition cleared in its window |
| vault | a gated action (vault PR) | the action's report | returned, ok, report payload |
| claim | a new, revised or retired claim (ops PR, §6) | its check, over its window | held / contradicted |

**Class is nature.** A sprint's class is its nature: `deploy` (the
effect is measured in deployment), `experiment` (the effect is an
experiment result), `internal` (the effect is on the factory itself).
A dev issue takes the class of its sprint; an issue outside any sprint
is `backlog`. A claim's class is the nature of what it predicts, from
the same three. Research is an experiment-class sprint. There is no
separate research loop and no hunt level.

In Sutton's terms: a proposal is an **option**. Initiation is the
decision. The inner policy is the organ/formula — not learned.
Termination is the outcome record. The reward is the grade, which may
be null.

What varies per deployment of disinto: which organs exist, which
classes and outcome bits exist, which probes measure effects, which
claims it holds, how deep the tree goes. That lives in the
deployment's ops repo (§7). What does
not vary: the five moments, the pair, the four records, the stores.
That is the portable mechanism.

---

## 2. The hierarchy

Loops nest. A sprint rides on its issues; a vault action or an
experiment run may serve a sprint; a repair rides on whatever it
fixes. A flat log of these muddies everything:

- the same work counted twice (once as a sprint, once as N issues);
- a grade on the sprint leaking into the issues' rows;
- "sprints of this class fail" confounded with "sprints of this class
  were fed underspecified issues."

So the tape is a **forest**: every proposal may name a `parent`, and
every node is a complete pair in its own right.

```text
sprint ──┬── issue → merge | refusal
         ├── issue → merge | refusal
         └── vault action / experiment run → report
```

Rules that keep the tree learnable:

1. **Each level pairs independently.** An issue's outcome is its merge
   or refusal. A sprint's outcome is its **effect** (below). Neither
   borrows the other's termination. A sprint is not "done when its
   issues are done".
2. **Children are context, not reward.** At the parent's outcome time,
   child aggregates are code-derived counts on the parent's outcome
   (`n_children`, `n_merged`, `n_rejected`, `n_failed`). Child outcomes
   never appear as samples of the parent's class. Counts only; resist
   derived scores.
3. **A grade lands where it was given.** A grade on a sprint is not
   divided among its issues — do not split the float. Children earn
   credit through their own pairs and as context of the next sprint
   over the same ground. Credit flows through context and bootstrap,
   never by splitting a grade.
4. **Statistics are per (loop, class), never pooled across depths.**
   "Sprint classes whose issues were rejected" is a join at read time,
   not a pooling at write time.
5. **Depth is small and named per deployment.** Here: issue < sprint.
   The mechanism only requires that every node has at most one parent
   and every node is a full pair.

Aborted parents: if a sprint is abandoned, its outcome says so, and
its children's pairs stand on their own. Orphans are data, not errors.

Rival attempts at one objective — experiment runs that refine or fork
each other — are a different relation from `parent`. Do not overload
it; see `notes/search-control.md`.

### The sprint block

On this deployment a sprint is a Forgejo milestone. Its description
carries:

```text
class: deploy            deploy | experiment | internal
effect: probes/<name>.sh a probe in the ops repo, or none
expect: >= 3             operator and number the probe must meet
soak: 7d                 wait after the work is done, before measuring
rests_on: <claim ids>    optional: the claims (§6) this sprint depends on
```

- A **probe** measures; it does not do the work. It prints one number.
  An experiment is run by the sprint's children; its probe reads the
  result. Probes live in the ops repo, so a human merges every one.
- A sprint terminates one of two ways. **Effect**: the milestone has
  no open issues, the soak passes, the probe runs; the outcome carries
  `bits.effect` (met or not) and `numbers.effect_value`. **Returned**:
  a child is rejected with `design-conflict`, or a claim the sprint
  rests on is challenged (§6); the sprint comes back at once with
  `bits.returned`, and its queued children leave the backlog.
- `effect: none` is allowed for a sprint with nothing to measure; its
  effect is then "no child failed". Most sprints have a measurable
  effect, and that effect is what the grade reads.

---

## 3. Records

Four record types. Append-only. Narrow.

**proposal**

| field | what |
|---|---|
| `id` | unique string (ULID preferred; older rows carry UUIDs) |
| `loop` | dev / sprint / repair / vault |
| `class` | the aggregation key: a sprint's nature (inherited by its issues), a repair's condition, a vault action's type, a claim's nature |
| `parent` | optional id of the proposal this one serves (§2) |
| `caused_by` | optional **record id** of what this proposal answers: the id of the proposal whose outcome failed (outcomes have no id of their own). Never a label; empty when the cause is a health check with no record. Orthogonal to `parent`: parent is composition, caused_by is causation |
| `context` | state at proposal time that cannot be recomputed later (rule below) |
| `forecast` | the proposer's claim about what comes back, with its method named inside. Off until calibration is honest |
| `decision` | approved / rejected / auto. A rejected proposal reaches the tape too: written when rejected, never run. `auto` means no human gate |
| `ref` | pointer to the full text (issue, milestone, vault action) |
| `payloads` | hash of the proposal text as it stood at proposal time |

The **proposer** is not a field. It is derived at read time from the
forge author of `ref`, and it is either an organ or the human. Every
organ files under its own bot account (`gardener-bot`,
`architect-bot`, `planner-bot`, `predictor-bot`, `supervisor-bot`,
`filer-bot`); the human files as `disinto-admin`, and so does any
agent session working on the human's behalf. The implementer
(`dev-bot`) never proposes. (#1605–#1629 were filed as `dev-bot` on
the human's behalf; read them as the human's.)

**Rejecting.** A human or an organ rejects an issue by labelling it
`rejected` and closing it; a predictor issue is rejected with
`prediction/dismissed`. The gardener writes the rejected proposal to
the tape. Vault actions closed unmerged will follow the same rule when
the first one exists.

**Context rule.** Write only state that cannot be recomputed later:
open PRs, the implementer's model and version, the parent. Everything
derivable from the proposal text (size, area, scope) is a projection
over the stored payload, computed at read time. A feature that never
varies is dropped. An LLM's reading of the proposal is not context; it
is a forecast method (§4).

**run** — only under a proposal. Organ sessions that serve no
proposal (patrols, housekeeping) are metrics, not tape.

| field | what |
|---|---|
| `proposal` | id |
| `organ` / `agent` | who executed (dev-qwen, review-qwen, …) |
| `started` / `ended`, `attempts` | |
| `cost` | tokens, wall time, GPU minutes |
| `status` | completed / failed / abandoned |

**outcome** — what came back:

| field | what |
|---|---|
| `proposal` | id |
| `bits` | code-derived, per loop: merged, rejected, effect, returned, acted, cleared |
| `numbers` | a few floats: duration, CI-red rounds, review rounds, effect value |
| `children` | code-derived rollup at this node's outcome time (§2 rule 2) |
| `payloads` | hashes into the payload store (CI log, transcript, probe output). Never inlined |
| `signature` | nullable reason label from the versioned rubric (`rubrics/<loop>.toml`, ≤ 8 labels per loop). Doubles as **attribution**, three ways: work-signatures (agent-loop, ci-exhausted, review-exhausted) are the implementer's failures and count in the class's competence statistics; world-signatures (env-broken) feed the repair loop and reliability stats only; proposal-signatures (scope-explosion, needs-ops, design-conflict, already-done) mark a correct refusal — they count *for* the implementer and *against* the proposal, and roll up to its parent. Without this split, infrastructure noise and bad issues poison per-class learning |

**grade**

| field | what |
|---|---|
| `proposal` | id |
| `value` | a number in [−1, 1], or null. Negative: moved away from the vision. Null is the common case and is honest |
| `when` | `at_approval` or `at_outcome` |
| `who` | you, or a named calibrator. Never an organ |

**The vision** is the project's `VISION.md`, in the project repo —
the document the planner plans against. A grade answers one question:
did this move the project toward its `VISION.md`? Nothing else defines
purpose; a vision that lives only in someone's head cannot be graded
against, and one that changes is read as it stood at grading time (git
history). On this deployment that is `VISION.md` in the disinto repo.

On this deployment grades are given per sprint, at outcome, reading
the sprint's measured effect (`tools/grade.sh milestone:N <value>`).
Issues are not graded; they earn credit through their sprint (§2
rule 3).

Two channels, kept separate forever:

- **Competence**: the outcome bits and numbers. Dense, automatic,
  derived by code. Trains "can the factory do X."
- **Purpose**: the grade. Sparse, human, nullable. Trains "does X move
  the vision."

Never collapse them into one number. A learner fed only dev-loop
success learns to propose small safe issues. That is the hallway: the
inside view is a model, not the objective. A sprint's measured effect
sits on the border: it is an outcome number (competence — did the
claimed effect happen), and it is what the human reads to grade
(purpose). The number does not become the grade.

**Disposition (the gut).** Competence is not "it merged". A loop is
competent when it disposes of what it was fed, one of two ways:

- **Digest** — the work comes back done: merged, including after
  recovering from red CI and review rounds (`numbers.ci_red`,
  `numbers.review_rounds` show what the recovery cost). For a sprint:
  the effect is measured and met.
- **Reject** — the work comes back refused with a reason
  (`bits.rejected`, a proposal-signature): it needs access the
  implementer does not have, it contradicts the design, it is too
  large, it is already done. A design-conflict rejection returns the
  parent sprint, not just the issue: siblings built on the same design
  stop.

The only incompetence is **stuck**: nothing comes back. Stuck is read,
not written. A proposal whose loop has no competence bit on its last
outcome after the loop's horizon counts as a failure sample in
calibration; no record is invented. Nothing coming back is an outcome
too — the same rule as the ungraded grade below.

Which bits count as competent, and each loop's horizon, are
per-deployment config (§7), never code. Here: dev `merged` or
`rejected`, 48 h; sprint `effect` or `returned`, 21 days. A bit that
is always 1 carries no information; if a loop's competence rate
saturates, the bit is wrong, not the loop perfect.

**Reward discipline.**

- A forecast is not reward. The error `grade − forecast` calibrates
  the proposer. It must never train purpose values.
- Forecasts stay off until the calibration table is honest. A forecast
  judged by a table that cannot drop below 100% teaches nothing, and a
  forecast read back from that table is circular.
- Any dense proxy (forecast error, a learned distance-to-vision, any
  shaping signal) is fuel for statistics, never purpose. If the proxy
  is noise, learning wanders — acceptable, and honest. If the proxy is
  biased — a systematic hill, "nice README, distance up" — learning
  climbs it. Bias is worse than noise, and the human grade is what
  catches it.
- The human grade is the only purpose-termination we trust. In a
  graded loop (§7), an outcome still ungraded after its grace period
  reads as purpose 0 to calibration; the record itself stays null.
  Null is what was given. Loops that are not graded show no purpose.
- The vault gate is initiation, not reward. Your merge authorizes a
  run; it says nothing about what came back.

**Scope.** Small, uniform completions are the statistics: per-class
rates assume comparable scope, and a class whose members range from
one-liners to epics has no success rate, only noise. The implementer
enforces it — an issue too large to digest is rejected as
`scope-explosion`, which counts against the proposal. How to write
issues that pass: `notes/issue-writing.md`.

---

## 4. What we write down

The fear: logging every iteration blows up and is unstructured;
boiling text to numbers through an LLM is biased. Both true. The
answer is three tiers with different rules.

**Tier 1 — the tape.** Only the four records. Fixed schema, narrow
columns, no prose. One dev completion is ~1 KB; a busy year is a few
MB. Append-only JSONL, read directly by scripts. The tape does not
blow up because the decision to crush is made **at write time**, by
the schema. No compaction, no index, no second store until a read is
actually slow.

**Tier 2 — payloads.** CI logs, agent transcripts, probe output, the
proposal text as it stood at proposal time. Content-addressed files
(`payloads/<sha256>`), one per artifact, any size. The tape holds the
hash. Payloads are kept 90 days, the tape forever. If a payload is
gone, the tape row still says what happened — you just cannot
re-derive the crushed fields. That is the correct trade.

**Tier 3 — derived numbers, two sources.**

- **By code, wherever possible.** CI status, duration, retry and
  CI-red counts, diff size, tests, probe values, child rollups. Zero
  bias, zero tokens. The outcome `bits` are always this.
- **By LLM, only for what code cannot parse.** A reason label, an
  issue-quality tag, a one-line summary. Crushed at write time against
  a **fixed, versioned rubric** in the ops repo, with the model name
  recorded on the record. The dev agent's refusal status is this kind
  of crush: it picks from a fixed list, and the rubric maps it to a
  signature.

The bias is contained, not denied:

1. The rubric is fixed and versioned, so the bias is *systematic*, and
   systematic bias is measurable and comparable across time.
2. The payloads are retained, so any crushed field can be re-derived
   with a better rubric or model later. The tape is a cache of
   perception, not the only copy.
3. The purpose channel never passes through the LLM. Grades are yours.
   The hard bits are code's. The LLM only labels texture in between.

A language model may crush text into fields. It may not invent fields,
and it may not write grades. A language model's *prediction* about a
proposal (for example the Jev scope reading: one concept, one repo,
one behavior → a probability) is a **forecast method**: it goes into
`forecast` with its method and model named, and competes with counting
on the calibration table.

---

## 5. The repair loop (supervisor)

Failure → debugging → fixing lives in the supervisor organ. In this
mechanism it is not special machinery.

**Monitor or proposal.** A condition that clears by itself — a stale
PR that later merges, a slow queue — is a **monitor**: watched, maybe
paged, never a proposal. A condition becomes a `repair` proposal only
when a remedy is attempted against it. Otherwise "cleared" measures
the world, not the factory. On disinto: `action: direct` recipes are
remedies, `action: incident` recipes (pr-stale, ci-stuck, …) are
monitors, and an LLM escalation is one `diagnose` proposal.

1. A health check, or an outcome with bad bits, detects a failure. Its
   signature comes from code first, the rubric if ambiguous.
2. When a remedy exists, the supervisor writes a `repair` proposal:
   class = the condition, `caused_by` = the id of the proposal whose
   outcome failed, or empty.
3. Fast path stays bash: a recipe with a known remedy runs it, as a
   run under that proposal. Unknown signatures escalate to a diagnose
   proposal for an agent — or to you.
4. The outcome is the **remedy's own check**: `bits.acted` (the remedy
   did what it does) and `bits.cleared` (the condition cleared within
   the recipe's window after the remedy acted). A condition that
   cleared without the remedy acting is world noise, not a success.
5. A fix that needs code goes through the dev loop: its `parent` is
   the repair proposal, its `caused_by` the original failure.

The pair that makes this valuable: **failure signature → remedy that
worked**, accumulated over incidents. That table is the factory's
immune-system memory: per signature, per remedy — attempted, worked,
mean cost.

The self-fix gradient, honestly bounded:

1. **Retry** — a remedy with good stats fires from a recipe, no human.
2. **Escalate** — a remedy whose worked-rate degrades becomes a
   `diagnose` proposal (root cause), not another retry.
3. **Graduate** — remedies with n ≥ 20 and success ≥ 0.9 may skip the
   human gate (`decision: auto`). Purpose-bearing proposals never do.
   The gate comes away per class, by evidence — not all at once, by
   faith.
4. **See** — the factory does not learn to see. A failure that
   produces no event (a wedged CI agent, a silent cron) leaves no
   trace for any of the above. Monitors over expected event rates
   ("hours since last green pipeline") are standing questions, and
   question generation is human work. Detection gaps are closed by
   hand, then become recipes.

---

## 6. Claims: the world model

The tape learns by counting. A per-class rate moves by 1/n per
outcome, and one surprise looks like noise. A human updates in one
shot: one observation refutes one specific belief, and every plan
resting on that belief changes at once. The design gets the same by
keeping the world model as **claims** — written, checkable, merged by
a human — and leaving counting to verify them.

**A claim** is a statement plus a check the factory can run itself.
One file per claim in the ops repo, `claims/<id>.toml`:

```toml
statement = "the dev agent rejects issues that touch more than two files"
class     = "internal"                 # nature of what it predicts
check     = "probes/scope-reject.sh"   # prints one number, like a sprint probe
expect    = ">= 0.8"
window    = "30d"                      # span one check reads
rests_on  = []                         # claims this one depends on
```

A belief without a check is not a claim; it stays in `VISION.md` as an
assumption, or nowhere. Claims about the factory (`internal`) and about
the world (`deploy`, `experiment`) share the format.

**Status is read, not written.** A claim is *provisional* until its
first outcome, *held* while its last outcome is `held`, *challenged*
once a check misses. Checks keep running after `held`; each is a run
under the claim's proposal, and a miss writes a new outcome at once —
the last outcome counts. Only the file is written, only by merge.
Retiring a claim is a merge that deletes its file.

**Proposals rest on claims.** A sprint block names `rests_on:` (§2);
its issues inherit it.

**Surprise** is read, not written, from three sources:

1. **A check misses its `expect`.** One miss challenges the claim, at
   once, and every open proposal resting on it returns — the
   design-conflict return, widened from one sprint to one belief. The
   returned proposals carry signature `claim-challenged`, attributed to
   the claim: it counts against neither the proposer nor the
   implementer.
2. **A forecast misses beyond its calibrated band** (once forecasts
   are on), or a sprint misses its `expect`. No claim is named, so
   nothing returns automatically; the miss needs an explanation.
3. **The vocabulary cannot record it**: a bad outcome with no
   signature, a refusal reason the rubric cannot map, a signal no probe
   watches. This is the vision's "signal detected".

**Revision is a proposal** in the `claim` loop. An organ drafts it — a
new claim, a revised or retired one, or for source 3 new vocabulary (a
probe, a signature, a bit) — as an ops PR under its bot account, with
`caused_by` the proposal whose outcome surprised it. You merge or
close. This is where a language model earns its place: explaining a
surprise with the claim that would have predicted it. Re-reading
payloads is legitimate here and only here — to draft a claim, which
must then pass its check. The loop's outcome is the check's verdict:
`bits.held` once a full window passes without a miss,
`bits.contradicted` at the first miss. A claim never checked within
its horizon is stuck: an unverifiable claim is this loop's
incompetence.

One-shot adoption, many-shot verification: a claim enters on one
surprise and one merge; counting decides whether it stays.

**Claims, not lessons, reach prompts.** Knowledge handed to an agent is
held claims: those its proposal rests on, and the `internal` claims
about its own loop. Prose memories (lesson digests, planner
memory) are retired: what is checkable becomes a claim, the rest is
dropped.

---

## 7. Stores and config

```text
moment ───► TAPE      /srv/disinto/tape/tape.jsonl   append-only, outside git
payloads ─► PAYLOADS  /srv/disinto/tape/payloads/    content-addressed, 90 days
read ─────► CATALOG   ops repo catalog/
              calibration.md   per (loop, class): n, promised, actual, error,
                               duration, top signatures (incl. stuck), purpose
              claims.md        per claim: status, checks run, last value,
                               open proposals resting on it
              remedies.toml    signature → remedy stats, once repair is honest
config ───► PER DEPLOYMENT, ops repo
              packs/loops.toml     loop → competence bit(s)
              packs/stuck.toml     loop → stuck horizon (hours)
              packs/graded.toml    graded loop → grace period (hours)
              rubrics/<loop>.toml  reason → signature, attribution
              probes/*.sh          sprint effect probes and claim checks
              claims/<id>.toml     the world model (§6)
```

The catalog lives **in** the ops repo: it is small, it is what organs
and humans read, and its history in git is a feature. The config lives
there too, so every pack, rubric, probe and claim passes a human
merge. A new
disinto deployment adopts this mechanism by writing its own config and
wiring its organs to the four records — no code change. The decision
path never scans the tape.

---

## 8. Organs that propose

Proposals come from organs, each under its own bot account (§3), and
you decide. Two organs carry the factory toward its goal: the planner
and the predictor. Neither needs a new loop or record: they propose
sprints (§2), vault actions and claims (§6).

**Capabilities are claims.** What the factory can do in the world is
part of the world model and is held like any claim: a statement plus a
check, where the check is an action that tries. Examples: read a host's
resources, start an LXC container, log in to the porter host, update
the porter, stand up a new instance of itself and move to it. A held
capability is an arm. A contradicted one is a lost arm. A capability
with no claim file is a gap. Use is evidence: every action that uses a
capability exercises it, and a dedicated exercise is needed only when
the capability went unused for its window.

**The planner** turns the vision into sprints. It reads `VISION.md`,
the held claims and the capability claims. Its first question is not
"what next for the product" but "what can I touch". Without arms and
legs no step toward the goal is possible, so its first sprints develop
them, in order (the capability ladder, `notes/organs.md`):

1. **sense**: an action container reads the resources of the host it
   is sent to;
2. **provision**: an action starts an LXC container. That is a
   credential the planner requests, scoped to its own LXD project on
   `/opt/ai`; nobody starts containers for it;
3. **reach**: an action container logs in to the porter host. If it
   cannot, the planner asks you for access, and that request is its
   proposal;
4. **deploy**: an action updates the porter on the remote host;
5. **replicate**: the factory builds a new instance of itself, tests
   it against its claims, and moves to it.

Each rung is an `internal` sprint whose effect probe is the
capability's check. A pitch goes through the existing vault gate: an
ops-repo PR, the architect's Q&A, and your merge as the decision. The
gardener then creates the milestone and files the sub-issues. Once its effect is met, the capability claim
follows as an ops PR. Once it has arms, the planner pitches steps
toward the vision as sprints with probes. Each sprint names the
capability claims it `rests_on`, so a lost arm returns the sprints
that need it (§6). Rungs above sense cross the vault gate
(`policy.toml` tiers). Moving is always `high`.

**The predictor** is the expert in the future. It reads the same claims
and the tape, picks the beliefs it doubts and the dangers it expects,
and proposes `experiment` sprints that try to prove them. An
experiment intervenes: it changes one thing and measures what follows.
Observation alone is the probes' job. The sprint's children are vault
actions, mostly action containers, and the probe reads the result. A demonstrated danger is a surprise (§6): the
predictor drafts the claim revision, and the remedy goes to the dev or
repair loop. An experiment that could do harm runs only in a sandbox
the planner can provision, so the predictor's reach is bounded by the
planner's arms. Once forecasts are on (§3), the predictor is their
first proposer. Its budget is one experiment every two days.

Both organs propose and never decide. Every sprint they pitch waits for
your decision, and every claim they draft waits for your merge. Idle
stays legal: a cycle with nothing worth proposing writes nothing.

---

## Moved to notes

- `notes/learning-ladder.md` — how learning plugs in after stage 1,
  what this is not, open questions.
- `notes/representation.md` — the representation research (PPM,
  TabPFN, HDC) and the commitment it led to.
- `notes/search-control.md` — rival attempts (`continued_from`) for
  experiment sprints and repair.
- `notes/world-model.md` — why claims, what they replace, the
  decisions of 2026-09-30, open questions.
- `notes/issue-writing.md` — scope discipline for whoever files issues.
- `notes/organs.md` — the planner and the predictor as proposers, the
  capability ladder, resources, safety, open questions (2026-10-07).
- The version before the 2026-09-30 rewrite, and the OaK research it
  draws on, stay with the owner's research notes (WhySutton).
