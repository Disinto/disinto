# Self-update: the canary rung

The owner's direction of 2026-11-04. The machine lacks the memory for
LXD sandboxes, so the provision rung waits. It will run on DigitalOcean,
later. The next rung is the factory updating itself in place, through
a canary. "Updating itself to a new version" was one of the owner's own
examples of a good effect (2026-11-02). This note is the detail behind
rung 2 of the capability ladder (`organs.md`, `proposal-loop.md` §8).

## Today

At the start of each 5-minute poll, every agent container resets its
factory checkout to `origin/main` (`pull_factory_repo` in
`docker/agents/entrypoint.sh`, #593). So a merge reaches every agent
within five minutes, all at once:
- CI and the reviewer check it before the merge;
- nothing measures it after the merge;
- the only way back is another merge.

On 2026-11-01 two `docker/agents/` merges redeployed the agents and
killed the dev sessions in flight. That is an image change, a class
the first version of the canary does not cover (Not in it yet).

So the factory already updates itself in place. This rung does not add
that power. It puts the update through a canary, measures it, and makes
it reversible.

## The flow

Two branches on the forge, `live` and `canary`, each hold a commit of
`main`. Each agent job follows one of them, set by `FACTORY_REF` in its
jobspec. `pull_factory_repo` resets to `origin/$FACTORY_REF` instead of
`main`. All jobs follow `live` except one, the canary. At first the
canary is the review agent, for three reasons:
- it polls every 5 minutes, with or without work, and loads most of
  `lib/`;
- it reviews every dev PR within minutes;
- it fails closed: a broken reviewer approves nothing, so nothing
  merges until it is back.

After each reset, every agent records the commit it now runs and the
result of each poll's role script (exit code), so the evidence is per
commit. When the commit changed, it also runs the smoke
(`.woodpecker/agent-smoke.sh`: syntax, and every called function
defined), which takes under 10 s.

The rollout tool, `tools/rollout.sh`, runs at each supervisor tick
(every 20 minutes). It runs on `live` code, never on the canary:

1. **Start.** When `canary` equals `live` and `main` is ahead, move
   `canary` to `main`'s head. Append a proposal, loop `rollout`, with the
   commit as its ref (§3 records).
2. **Watch.** Read the canary's evidence since the move:
   - it runs the commit;
   - the smoke passed on it;
   - its role script exited 0 on every poll since, and at least one
     poll did real work when there was work to do (a PR to review).
3. **Promote** after the soak (`packs/rollout.toml`; 30 minutes, about
   six polls, to begin with), when all of that holds. Fast-forward `live`
   to `canary`, and every agent takes it at its next poll. The outcome
   has bit `promoted` 1.
4. **Roll back** when any of it fails, or when the canary has not taken
   the commit within two polls:
   - reset `canary` to `live`; the canary runs the old version again at
     its next poll;
   - the outcome has `promoted` 0;
   - open an issue for dev with the commit and the evidence;
   - start no new rollout until `main`'s head changes, so the fix is the
     next thing rolled out.

Rules the tool keeps:
- `live` and `canary` only ever point at commits on `main`;
- `live` only moves to a commit that soaked on `canary`;
- one rollout at a time;
- `main` keeps moving during a soak, and the next rollout takes its head.

If the tool itself breaks, nothing moves, and every agent keeps running
the last good version: it fails closed. One check sits outside it. The
healer runs from `/opt/disinto`, not from `live`. When `live` has lagged
`main` for more than 24 hours, it queues one notice to the owner
(`lib/notice.sh`).

Only the rollout tool's account (`supervisor-bot`) and `disinto-admin`
may push `live` and `canary`, a forge branch rule. The owner can freeze
rollouts with a hold file, `${TAPE_DIR}/rollout/HOLD`, as for sprints.

**Cost:** no new container and no new memory. The canary is an agent
that already runs, following another branch.

## Not in it yet

- **Images and jobspecs.** CI rebuilds the agents image and restarts
  every agent when a merge touches `docker/agents/`
  (`ci.yml`, `rebuild-and-deploy-agents`). Jobspecs are applied by
  hand. The canary does not gate either: the 2026-11-01 incident above
  could happen again. What closes the gap is the follow-up that builds
  the image, applies the jobspecs and fast-forwards `/opt/disinto` from
  `live` instead of `main`.
- **`/opt/disinto`.** CI fast-forwards it to `main`, and the edge, the
  healer and the box's tools run from it. Moving it to `live` is the next
  step once the flow holds.
- **One canary.** A change to code that only another role runs
  (`dev/`, `gardener/`) meets the canary only through the smoke. If
  rollbacks or post-promotion failures show the gap, per-role canaries
  come next.

## Records and the grade

- Loop `rollout` uses the records of §3:
  - a proposal at the start, with the commit as its ref;
  - runs, the tool's ticks;
  - an outcome at promotion or rollback, with bits `promoted` and
    `smoke`, and numbers `soak_s` and `polls`;
  - no grade per rollout. The grade belongs to the rung's sprint.
  `packs/loops.toml` lists `promoted` as the loop's competence bit, and
  `packs/rollout.toml` holds the soak (§7).
- The capability claim is `can-update-self`: "the factory updates itself
  through a canary: a new version runs beside the old one and replaces
  it only after it held". Its probe, `probes/can-update-self.sh`, counts
  the promoted rollouts in the window: `>= 1` over 7 days.
- A rollback is not a failure of the capability. It is the capability
  working, because the bad version never reached the other agents. A
  window with only rollbacks and no promotion is a miss: the factory
  could not update itself.
- The rung's sprint aims at level `made`. The scale lists "a new version
  of itself running beside the old" under `made` (§3). The probe is
  merged with the pitch, before the work starts. A grade of 0.5 is not
  above 0.5, so the gate stays transparent.

## The wall

This rung lets the factory roll out changes to itself. It could also
roll out changes to what grades it, what stops it and what gates it.
That is the shortcut the owner named on 2026-11-02: "the human brain is
also grading itself, drugs being a shortcut".

The wall is the forge's protected file patterns on `main`. The bots have
write access, not admin, so they cannot merge a PR that changes a
protected file; the owner merges it as `disinto-admin`. The list stays
short, because each entry means a PR waits for the owner:

| what | files |
|---|---|
| what grades it | `tools/sprint-grades.sh`, `tools/sprint-held.sh`, `tools/grade.sh`, `tools/grade-threshold.sh`, `lib/sprint-block.sh` |
| what stops it | `lib/repair-suspend.sh` |
| what gates it | `action-vault/policy.toml` |
| what rolls it out | `tools/rollout.sh`, `.woodpecker/**` |
| the design | `docs/design/**` |

The ops repo has no branch rule today, and the gardener pushes to it
directly. Checked on the live forge on 2026-11-04: the ops repo lists no
branch protection, and the gardener's catalog commits land on `main`.
`setup_vault_branch_protection` (`lib/branch-protection.sh`, run by
`bin/disinto` init) is not in place on this deployment. A rule on its
`main` protects `vault/policy.toml`, `packs/repair.toml` and
`packs/rollout.toml`, and leaves every other push as it is.

A PR that waits on a protected file tells the owner once, through
`lib/notice.sh`, so it does not sit unseen.

## Build order

The rung's sprint, pitched through the gate, carries these as
sub-issues:

1. `FACTORY_REF` in `pull_factory_repo`: the factory checkout resets
   to `origin/${FACTORY_REF:-$PRIMARY_BRANCH}`. `PRIMARY_BRANCH` stays
   the project's branch, and with `FACTORY_REF` unset nothing changes
   until the branches exist. Each agent records its
   commit, its smoke result and its role script's exits.
2. The `live` and `canary` branches at `main`'s head, with their push
   rule. `supervisor-bot` needs write on the repo: the live forge has
   it, but `lib/forge-setup.sh` grants it read, so a fresh install
   would not.
3. `tools/rollout.sh`, `packs/rollout.toml` and loop `rollout` on the
   tape; the supervisor calls the tool each tick.
4. The jobspecs: review follows `canary`, the others follow `live`
   (applied with `nomad job run`).
5. The healer's lag notice.
6. The wall: the protected file patterns on both repos, and the notice
   for a PR waiting on one.
7. The ladder: `planner/ladder.sh` and `planner/pitch-or-idle.sh` learn
   `update-self` as rung 2 and the DigitalOcean provision rung. The
   numbered rung references in `planner/gaps.sh` and
   `planner/AGENTS.md` become names.

The claim `can-update-self` follows as an ops PR once the sprint's
effect is met (§8).
