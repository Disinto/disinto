# World model

Decided 2026-09-30. The mechanism is `proposal-loop.md` §6; this note
is why, what it replaces, and what is still open.

## The question

A human updates their world model in one shot: something new happens,
one belief changes, and every plan that rested on it changes with it.
Where does the design keep its world model, and how can a surprise
reach it?

## What the design had

No world model by that name. The ladder planned Sutton's compositional
version — option models per (loop, class), learned from the tape — and
said what it is not: not learned, not Dyna over the tape, not
generative. That model learns by counting. A rate moves by 1/n per
outcome, so one surprise is one sample, indistinguishable from noise,
and with forecasts off nothing can be surprising at all.

One-shot updates did happen, in three places, none named:

- **The design-conflict return** — one refusal stops every sibling built
  on the same design. The only one-shot update in code, and it
  propagates through dependency.
- **The ops repo config** — the 100% calibration fix of 2026-09-29 was
  one-shot: one observation ("the failed rows all merged later;
  refusals are competence") became a new bit, the stuck rule and a
  rubric, merged within a day. The ladder called this void detection.
- **Prose outside the design** — per-agent `.profile` lesson digests
  (journal → LLM digest → prompt), the planner's `prerequisites.md` and
  `knowledge/planner-memory.md`. Fast, but they predict nothing, so
  nothing can refute them. Planner memory, runs 34–45: "No
  predictions. No changes. Graph stable. Same 5 constraints."

Counting is verified but slow; prose is fast but unverifiable; config
is fast and verified, by hand only.

## Why humans one-shot

1. The prior is structured: claims about mechanisms, with dependencies.
2. Blame is assigned to one claim ("which belief was wrong?") —
   abduction, not averaging.
3. The change propagates to every plan that relied on the claim.
4. The new belief is held provisionally; what comes next tests it.

Counting does none of these. A language model does (2) well and (4)
badly — it explains, it does not keep score. So: the model explains,
the tape keeps score, the human admits.

## Decisions (answers 1a 2c 3b 4a 5a)

1. **Where it lives**: a claims register in the ops repo, one file per
   claim, merged by a human like packs, rubrics and probes.
2. **Surprise**: all three sources — a contradicted claim, a forecast
   miss beyond its calibrated band, and what the vocabulary cannot
   record.
3. **Revision**: an organ drafts it as an ops PR; the human merges. That
   makes revision a proposal, hence the `claim` loop.
4. **On challenge**: every open proposal resting on the claim returns
   automatically.
5. **Existing prose**: convert what is checkable into claims, drop the
   rest.

Consequences written into the design without a separate question:
status is read from the tape, never written (as with stuck); returns
caused by a challenged claim are attributed to the claim, not to the
proposer or the implementer; only a claim's own check triggers the
automatic return, because only there is the blame unambiguous; held
claims replace lessons in prompts.

## Relation to OaK

OaK's world model is also compositional — many predictions, not one
simulator — and its open problems suggest spawning a new prediction
wherever error is high (the OaK essay's open-problems chapter, kept
with the owner's research notes, WhySutton). That is the
bottom-up, slow version. Claims are the top-down, one-shot version: a
prediction enters on one surprise, drafted by a model and admitted by a
human, and the counting layer then verifies it. A held claim names
something worth conditioning on, which is what option models (ladder
rung 3) will need.

## Defaults on this deployment

- The predictor is not deployed (2026-09-30: only dev, gardener,
  review and supervisor run). So the **gardener** turns merged claims
  into proposals, runs their checks once a day, and writes the returns,
  next to the sprint outcomes it already writes (milestone 3,
  #1640–#1645). Drafting revisions — the three surprise sources read by
  an organ and turned into `predictor-bot` ops PRs — waits for the
  predictor; its job description is already "challenges claims".
- Claim checks live in `probes/` next to sprint probes and follow the
  same rule: one number, run with `bash`. A check that has nothing to
  judge exits non-zero: no evidence is not a pass.
- First claim: `claims/dev-comes-back.toml` — a dev proposal comes back,
  merged or rejected, within 48 h (≤ 0.2 unreturned over 7 days). It
  read 0.12 on 2026-09-30, the day #1615 started looping.

## Migration of prose (5a)

- `.profile` lesson digests: inventory per agent; a lesson that states
  something checkable becomes a claim with a probe; the rest is
  dropped, and the digest step stops writing prose.
- `planner-memory.md`: run history and constraint lists are derivable
  from the forge and the tape — dropped.
- `prerequisites.md`: status lines ("exists", "closed") are derivable —
  dropped; any prerequisite that is really a belief about what the
  vision needs becomes a claim or stays in `VISION.md`.

## Open

- **Window length.** A short window makes a check one-shot but noisy: a
  false miss returns real work. A long one is safe but slow. A claim
  that flip-flops between held and challenged is the symptom; how
  should the catalog show it?
- **Claims resting on claims.** When B is challenged and A rests on B,
  is A challenged, or only marked unsupported?
- **Blame for source 2.** When a sprint misses its `expect`, the
  drafter picks the claim to revise. What keeps it from always
  blaming the newest claim, or never the one it drafted itself?
- **Rate of drafts.** Surprise sources can fire more often than a human
  can review. One draft per surprise, or batched per cycle?
