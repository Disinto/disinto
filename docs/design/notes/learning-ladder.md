# Learning ladder, limits, open questions

Moved from `proposal-loop.md` §9, §11, §12, 2026-09-30, and updated.
The design keeps only its stage line: stage 1 writes the tape and
reads calibration; stage 2's first target is sprint approval.

## The ladder

In order, each rung gated on the tape being thick and honest enough.
Claims (`proposal-loop.md` §6, `world-model.md`) run beside the ladder
from stage 1: they need no forecast, and the rungs verify them.

1. **Calibration report** — stage 1's only read. Per (loop, class):
   n, promised, actual, error, top signatures (incl. stuck), purpose.
   Live; honest once stuck samples and the gut bits land (#1614,
   #1615).
2. **Sprint approval (stage 2's target).** A sprint arrives with a
   forecast of its effect, drawn from past sprints of its class, and
   the error between forecast and measured effect calibrates whoever
   proposed it — you or an agent. Every forecast names its method
   (counts / gbdt / tabpfn / jev / human), so methods compete. A counts
   method already ran on dev issues 2026-09-21 to -30, against a table
   that read 100%; it was switched off until calibration is honest.
3. **Option models per level**: per class, context → (what comes back,
   cost, duration). At the dev level this is the inside view — a model
   of the factory's own competence. At the sprint level it is the
   outside view: effects in deployment and experiments. A sprint model
   is built from issue models and probe history, not learned flat. A
   held claim names a condition worth conditioning on.
4. **Planning**: two planners, never mixed. Composition questions
   (sprint → issues) chain option models; Dyna over the catalog. Search
   questions (extend this experiment chain or open another) walk
   committed experiment and repair trees (`search-control.md`). Not
   Dyna over the tape. Not a learned world model: the world model is
   the claims register — written, checked, merged.
5. **Latent features, only if earned**: an embedding of the proposal
   text, an HDC bundle over the record, or a learned encoder over
   (proposal, context) → outcome may propose features. It competes
   with code-derived features on prediction of what comes back, under a
   budget, and is culled if planning never consults it. The latent is
   perception, never knowledge. Its training pair is the tape's own:
   what was proposed ↔ what came back.
6. **Gated auto-approval**: a trust class (repair remedies with
   n ≥ 20 and success ≥ 0.9) may skip your gate. Purpose-bearing
   proposals never do. The gate comes away per class, by evidence —
   not all at once, by faith.

## What this is not

- Not a log pipeline. The tape is proposals and what came back, not
  events. Organ sessions without a proposal are metrics.
- Not flat. Every pair knows its level and its parent. Pooling across
  depths is a read-time join, never a write-time accident.
- Not a data lake. Payloads are cold storage with hashes, not a query
  surface.
- Not a trained representation. The state is the event prefix,
  featurized at read time; predictors are baselines, GBDT, or
  in-context models (`representation.md`). No latent is trained on our
  data at our scale.
- Not per-loop schemas. Loops differ in `class`, `bits`, and config —
  not in record structure.
- Not replay of text as learning. Nothing learns by re-reading
  transcripts. Re-deriving a crushed field from a payload is a rebuild
  of a projection, not a training signal. Re-reading a payload to
  draft a claim is allowed; the claim still has to pass its check.
- Not retrieval as knowledge. Similarity is shared typed fields. No
  embedding search over tape or payloads is passed off as memory.
- Not a Horde. Forecast questions are added one at a time, each gated
  on an existing signal actually moving. Thousands of questions need
  thousands of moving signals; we have a sparse grade and a few bits.
- Not obligated to act. Idle is legal: an organ cycle with nothing
  worth proposing writes nothing. A factory that cannot idle invents
  work to feed itself.
- Not LLM-written purpose. The LLM is diet: it may crush text to
  fields, draft proposals, predict as a named forecast method, and
  write the inner policy of an option, and draft claims with their
  checks as ops PRs a human merges. It never writes a grade, a table of
  statistics, or an exploration controller, and nothing it drafts
  takes effect without a merge.
- Not a generative world model. Recorded trees are exact over what
  ran; they do not predict unseen branches.
- Not search control on the composition forest. A sprint of unlike
  issues is parts, not rivals.

## Open questions

Resolved 2026-09-29/30 and folded into the design: grade protocol
(per sprint, at outcome, −1..1), termination per level (sprint effect
after soak, or returned), rollup rules (counts), compaction (none until
a read is slow), rubrics (8 signatures, three attributions), loop
naming (levels and triggers), class (sprint nature), proposer (an
organ's bot account or `disinto-admin`; the implementer never
proposes), world model (claims in the ops repo; surprise from three
sources; organs draft, the human merges; `world-model.md`).

Still open:

- **Sprint forecasts across probes.** Effects are measured by
  different probes, so `effect_value` is not comparable across
  sprints; only `effect` (met or not) is. Is "promised" for a sprint
  just P(effect met), or does each sprint also state its own expected
  value (`expect`) and the calibration read the claimed margin?
- **First projections.** Which read-time features of the stored
  proposal text actually predict rejection or stuck? Expect the first
  analysis over honest calibration to tell us.
- **HDC layer**: worth a prototype only after counts/GBDT visibly
  plateau on a real forecasting task.
- **Void detection**: how to tell "predictor too weak" from
  "representation wrong". Persistent structural error — calibration
  flat across methods, candidate features adding nothing — should
  trigger a config or rubric change, not a bigger predictor. You cannot
  fill a representational hole with the representation that created
  it. The saturated 100% of September 2026 was the first instance:
  the fix was a new bit (rejected) and a read-time rule (stuck), not a
  better reader. That path now has a name — surprise source 3, drafted
  in the claim loop — but telling the two cases apart is still open.
- **Option models used for planning**: the distinctive claim, empty
  here and in the literature. It needs many completions of the same
  class before the numbers mean anything.
- **Question generation**: which forecasts to spawn beyond the core
  vocabulary. Claims answer part of it: a new question enters as a
  drafted claim when a surprise fires. Beyond that, one at a time, only
  when an existing signal moves — never because a longer list sounds
  smarter.
