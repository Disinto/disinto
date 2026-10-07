# Design: the proposal loop

How disinto decides and learns: the mechanism every deployment shares.
`VISION.md` says what disinto is for. This directory says how the
factory proposes work, records what came back, and learns from it.
Deployment-specific config (packs, rubrics, probes, claims) lives in
the deployment's ops repo (`proposal-loop.md` §7).

Moved here from the owner's research workspace (WhySutton) on
2026-10-07, so the factory's own organs can read the design they
implement. Edit it here, by PR, like any other doc.

| File | What |
|---|---|
| [proposal-loop.md](proposal-loop.md) | The design. It describes only the mechanism: one shape for all loops (dev, sprint, repair, vault, claim), the four records, the gut disposition (digest, reject, stuck), sprints that come back with a measured effect, claims as the world model, and organs that propose (§8). |
| [notes/world-model.md](notes/world-model.md) | Why claims: how humans update in one shot, what disinto had before, the decisions of 2026-09-30, open questions. |
| [notes/learning-ladder.md](notes/learning-ladder.md) | How learning plugs in after stage 1, what this is not, open questions. |
| [notes/representation.md](notes/representation.md) | The representation research (PPM, TabPFN, HDC) and the commitment it led to. |
| [notes/search-control.md](notes/search-control.md) | Rival attempts (`continued_from`) for experiment sprints and repair. Not built. |
| [notes/organs.md](notes/organs.md) | The planner and the predictor as proposers, the capability ladder, resources, safety, bootstrap sprints (2026-10-07). |
| [notes/issue-writing.md](notes/issue-writing.md) | Scope discipline and disinto conventions for whoever files issues: the owner, an agent session, or the architect. |
