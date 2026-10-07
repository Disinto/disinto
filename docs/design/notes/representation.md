# The representation space

Moved from `proposal-loop.md` §5 and §6, 2026-09-30. Research notes;
the only rule that stayed in the design is the context rule (write
only state that cannot be recomputed; derive the rest from the stored
proposal text at read time).

Researched September 2026 against the question: what are the intrinsic
shapes of the nervous system, given that disinto changes under it
constantly and the data will never be big.

## Findings

**Our niche has a name: predictive process monitoring (PPM).** Twenty
years of literature on forecasting outcomes of business-process cases
from event-prefix logs, at 10³–10⁵ cases per log — our data scale, our
record shape, our question ("what comes back"). Cases are our proposal
trees; events are our records; outcome prediction is our forecast. This
is the methodological template we steal from, including its failure
modes (over-generalizing sequence models that hallucinate impossible
traces; scarce-data warnings in every survey).

**At our scale, nobody trains a latent space.** The evidence:

- A count-based argmax baseline matches fine-tuned GPT-2/Qwen-3 on
  real process logs (Weytjens & Weber 2026). **Baselines run always,
  as the honesty check.** Any fancier predictor must beat counting.
- Gradient-boosted trees beat deep nets on tabular data at small n
  (Grinsztajn et al. 2022; Shwartz-Ziv & Armon 2022).
- **TabPFN v2** (Hollmann et al., Nature 2025): a transformer
  pretrained on millions of *synthetic* tables, doing in-context
  Bayesian prediction with no training, dominant for n ≤ 10⁴ rows.
  Berti & van der Aalst (2026) apply the same pattern to event logs
  directly — pretrained on synthetic logs, predicts next
  event/outcome in-context, designed for data-scarce logs. These are
  the two evidence-backed predictors at exactly our scale.
- From-scratch joint-embedding spaces (JEPA lineage) have no evidence
  base below ~10⁴ samples and are validated at 10⁵–10⁶. LLM
  embeddings as *predictive* features lose to raw fields (Gao et al.
  2024; TEmBed 2026). Embeddings are retrieval, not state.

**Schema drift is solved by the log, not by the space.** The
drift-proof representation is the event-sourced spine itself:
immutable typed records; every learned view (catalog, predictor
features) is a *replayable projection* of it. When disinto changes,
history is not migrated — projections are rebuilt. This is the
event-sourcing pattern, with live 2026 adoption in agent engineering
(ESAA; "the log is the agent"). Corrections use bi-temporal versioning
(valid-time vs. record-time), the accepted answer from temporal
knowledge graphs. Renamed/added fields are absorbed by embedding-based
semantic matching at the *projection* layer, where text similarity is
actually the right tool.

**One bet, flagged as a bet:** hyperdimensional computing / vector
symbolic architectures. Role-filler binding (`role ⊗ value`, bundled)
is literally our record shape; a new field is one new random role
vector and old encodings degrade gracefully by theorem (concentration
of measure); few-shot classification is the field's strongest
empirical claim (Vergés et al. 2025, 121 datasets); the PathHD
pattern — HDC as state, LLM as judgment — is our division of labor.
Honest status: drift-immunity is algebraic inference, not published
evidence; accuracy is kernel-machine quality, below GBDT. Admitted
only as an optional similarity/composition layer, behind the count
baseline like everything else.

## The commitment

- **State of a case = its event prefix, featurized at read time.**
  Aggregate and index-based features over the prefix (PPM-style), not
  an embedding, not a trained encoder. Features derivable from the
  proposal text are computed from its stored payload, not written at
  proposal time.
- **Prediction = standing forecast questions over the stable core
  vocabulary** (did it merge or get rejected, duration, cost, effect
  met, grade — the fields whose meaning survives any refactor)
  answered by: count baseline first, GBDT or TabPFN per (loop, class)
  when n suffices, LLM readings (Jev) as one more named method. Every
  forecast names its method, so methods compete on the calibration
  table.
- **Similarity = shared typed fields** (tabular conditioning), or HDC
  bundle overlap if composition is needed later. Never embedding
  retrieval passed off as knowledge.
- **Drift is absorbed by construction**: immutable spine, additive
  nullable fields with pack/rubric versions, semantic field matching
  at projection time, crushed fields re-derivable from payloads.

Sources: Weytjens & Weber 2026 (arXiv 2606.15868); Grinsztajn et al.
2022 (arXiv 2207.08815); Hollmann et al. 2025 (TabPFN v2, Nature);
Berti & van der Aalst 2026 (in-context PPM); Gao et al. 2024 (EMNLP
Findings); Vogel et al. 2026 (TEmBed, PVLDB); ESAA (arXiv 2602.23193);
Graphiti/Zep (arXiv 2501.13956); Vergés et al. 2025 (HDC survey,
AI Review); Kleyko et al. 2022 (VSA framework, Proc. IEEE); PathHD
(arXiv 2512.09369).

## Superseded: per-loop context lists

The old §6 listed context features per loop (repo area, size class,
open PRs, agent backend, …). On the live tape they carried almost
nothing: `open_prs` was 0 in 74 of 84 dev rows, `size_class` always
`M`, `backend` constant, `area` never written. Replaced 2026-09-30 by
the context rule in `proposal-loop.md` §3. The lists are in the 2026-09-21 version of the design, kept with
the owner's research notes (WhySutton), not in this repo.
