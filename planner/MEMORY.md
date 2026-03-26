<!-- summarized-through-run: 6 -->
# Planner Memory

## 2026-03-26 — Sixth planner run

### Milestone state
- **Foundation**: COMPLETE. All agent loops, supervisor, planner, multi-project, knowledge graph, predictor-planner feedback loop — all working.
- **Adoption**: 4/5 COMPLETE. Bootstrap (#393), docs (#394), dashboard (#395), landing page (#534) all done. Only #466 (example project) remains — stuck on human decision since 2026-03-23.
- **Ship (Fold 2)**: ENTERING SCOPE. Rent-a-human (#679) done. Exec agent (#699) done. Observable addressables (#718) filed. Deploy profiles and assumptions register not yet tracked.
- **Scale**: DEFERRED. No external users yet. Plugin system, community formulas, hosted option all premature.

### Completed since last summary (runs 2-6)
- Bootstrap fully hardened: init smoke test (#668), CI wiring (#661), Forgejo reachability (#660), 10+ bootstrap fixes
- Full stack containerized (#618, #619) with Forgejo, Woodpecker, Dendrite
- Autonomous merge pipeline (#568) — PRs auto-merge on CI pass + approval
- Unified escalation path (#510) — PHASE:escalate replaces needs_human
- Factory operational reliability — guard logging (#663), stale phase cleanup (#664)
- Prediction/backlog killed (#686) — planner now only ACTIONs or DISMISSes predictions
- Planner v2 — graph-driven formula (#667), tea CLI integration (#666)
- Exec agent (#699) — interactive assistant via Matrix
- Rent-a-human (#679) — formula-dispatchable human action drafts
- Tech-debt queue cleared (~30 items)
- Skill package initiative started (#710-#715) from research (#709)

### Patterns
- **Label loss resolved**: #535 fixed the recurring label-loss pattern. Labels now persist reliably.
- **Predictor signal quality improved**: Later runs show 100% substantive predictions. Over-signaling on transient ops issues has stopped.
- **Human bottleneck is real**: #466 escalated 2026-03-23, still no response after 3 days. When the factory needs human input and doesn't get it, work halts on that branch entirely.
- **Factory throughput is extreme when unblocked**: 50+ issues cleared in ~5 days (2026-03-20 to 2026-03-25). Pipeline processes ~10 issues/day when backlog is stocked.
- **Duplicate issues from parallel creation**: #710/#714 and #711/#715 are duplicates — likely created in separate exec/research sessions. Gardener should catch these.
- **prediction/backlog migration**: All 4 legacy prediction/backlog items dismissed and closed in run 6. prediction/dismissed label created.

### Strategic direction
- Ship milestone is the next frontier. Adoption is blocked only on #466 (human decision).
- Skill package distribution (#710→#711→#712) is the immediate pipeline work — packaging disinto for external discovery.
- Observable addressables (#718) bridges Fold 2 → Fold 3 — core vision item.
- The factory has the exec agent (#699) and rent-a-human (#679) — two vision capabilities now live.
- VISION.md updated with factory primitives (resources, addressables, observables) — formalizes the framework.

### Watch list
- #466: human response overdue (3 days) — will it ever be unblocked?
- #710-#712: skill package pipeline — first new work direction since Adoption
- #714/#715: duplicate cleanup by gardener
- prediction/backlog label: should be deleted per #686, still exists
- Ship milestone gaps: deploy profiles, assumptions register, vault-gated folds — not yet filed
