# Organs that propose: planner, predictor, capabilities

From the owner's direction of 2026-10-07, with the owner's decisions of the
same day (end of this note); this note is the detail behind
`proposal-loop.md` §8. The vision gives the goal. The organs need to
know what they can touch, so they can propose the next step toward it.

## Capabilities are claims

A capability is a claim (§6) about the factory's own reach:

```toml
# claims/can-reach-porter.toml
statement = "the factory can log in to the porter host over ssh"
class     = "internal"
check     = "probes/can-reach-porter.sh"   # reads the vault loop, below
expect    = ">= 1"
window    = "7d"
rests_on  = []
```

The check does not act. It reads the evidence of acting, which is the
vault-loop outcomes of the action formula that exercises the capability
(`can-reach-porter`), plus every other action whose report says it used
the porter. It prints the number of successful uses in the window. No
use in the window means no evidence, so the probe exits 1. The planner
then schedules a dedicated exercise: a low-tier action where the tier
allows it. For a gated capability, a real use waiting for approval
counts as the exercise.

Naming: `can-<verb>[-<target>]`. A capability that depends on another
names it in `rests_on`. For example, `can-deploy-porter` rests on
`can-reach-porter`, so losing the reach challenges the deploy, and both
return the sprints that rest on them.

## The capability ladder

The order is a dependency, not a schedule: each rung's actions need the
rung below.

| rung | claim | first action | tier | unlocks |
|---|---|---|---|---|
| 1 sense | `can-sense-<host>` | an action container on `<host>` runs a read-only inventory (CPU, memory, disk, docker, LXD) and stores it as an artifact | low, no gate | the resources inventory; pitches that know their cost |
| 2 provision | `can-provision` | an action starts a named LXC container in its own LXD project, on `ai-pool` (`/opt/ai`) only, reports its address, deletes it | medium | sandboxes for the predictor; test instances |
| 3 reach | `can-reach-porter` | an action container with the `ssh` mount logs in to the porter host, `disinto.ai`, and runs `whoami` and `uname` | low once access exists | remote work |
| 4 deploy | `can-deploy-porter` | an action runs `porter-install.sh` at a ref on `disinto.ai` and verifies it with the `status` verb | high | shipping: Fold 1 → 2 in `VISION.md` |
| 5 replicate | `can-replicate` | provision, install disinto at a ref, run its acceptance tests and claim checks against the new instance, report | high | testing new versions of itself; **move** is a separate, later decision |

**Asking you.** When a rung fails for want of access, such as a key
the porter host does not accept, the planner proposes a request to you.
It is an `action` issue, or `run-rent-a-human` where that fits, and it
names exactly what to grant: host, account, key fingerprint, scope. Your
grant is the decision. The outcome is the next exercise: the request
terminates `ok` when the exercise succeeds within its window, and
`returned` when you decline.

**Self-versions.** Rung 5 is where "develops new versions of itself"
becomes concrete. The dev loop already changes the code. Replication
deploys a factory at a ref on a fresh container and holds it to the
same claims as the live one. Testing new versions is the requirement.
Whether and how the factory then **moves** is decided later, by what
works. Any move is never automatic, and its effect probe is the claims
holding on the new instance for a full window.

**Disk decides the shape of rung 5.** The sandbox pool (`ai-pool`, a
directory on the host's `ai` volume) had 43 GiB free of 368 GiB (88%
used) on 2026-10-07. The host root had 17 GiB free (83%). The live
factory alone carries about 22 GB of docker images. A full copy does
not fit the starting limits, so the first test instance is slim: only
the services and images a test needs, sharing the host's llama-server
through the proxy. The first sense report sets the numbers.

## The planner

The cycle:

1. Read `VISION.md`, the held claims, the capability claims and the
   resources inventory. Claims reach the prompt, not prose (§6).
2. If the lowest missing or contradicted rung blocks every next step
   toward the vision, pitch that rung's sprint, and nothing else.
3. Otherwise pitch the next vision step as a sprint. It gets a class, a
   probe (existing, or a new one drafted in the same ops PR), `expect`,
   `soak` and `rests_on`, including the capability claims it needs. It
   declares its expected use of resources.
4. Nothing worth proposing: write nothing.

This retires today's prose: the prerequisite tree (`prerequisites.md`)
and `planner-memory.md` become capability claims and held claims, or
are dropped (`world-model.md`, 5a).

**Pitches go through the existing vault gate.** It is the same flow
the gardener's `pitch-vision` pitches use today:

1. The organ opens an ops-repo PR (`architect: <title>`) carrying the
   pitch and its sprint block.
2. When the pitch carries no sub-issues, the architect drafts them and
   commits them to the PR branch as `architect-bot`; it answers your
   questions in PR comments and revises the draft. A comment
   starting `Reject:` closes the PR.
3. **Merging the pitch PR is the decision**, as for every vault action;
   closing it unmerged rejects the pitch.
4. The gardener creates the sprint's milestone with its block, records
   the decision on the tape, and files the sub-issues into the
   milestone in dependency order. The ops-filer pipeline the architect
   flow was written for never ran (#779).
5. The milestone and the tape track the sprint. The architect's dormant
   tracking and auto-merge are retired.

The proposer is the PR's author: `planner-bot` or `predictor-bot`
(§3). Sprint 1 of the bootstrap, *A pitch becomes a sprint*, builds
steps 3 and 4.

## The predictor

Expert in the future: what will break, and what we believe wrongly.

- **Targets:**
  - claims whose last value sits close to `expect`;
  - claims held for a long time without an experiment against them;
  - resources trending toward exhaustion: disk, memory, Grok quota,
    llama slots;
  - single points of failure: one Vault root token file, one gardener,
    one runner host.
- **Proposals:** `experiment` sprints whose children are vault actions
  (`run-experiment`, mostly action containers). The probe reads the
  result. A refinement continues an earlier run (`continued_from`,
  `search-control.md`).
- **An experiment changes something.** Observation, meaning
  measurements, probes, the sense rung and analysis of the tape, yields
  correlations; it is the probes' job and needs no budget. An
  experiment intervenes: it changes one thing and measures what follows,
  which is what makes its conclusion causal.
- **Danger needs a sandbox.** An experiment that could harm the live
  factory, such as filling a disk or killing a service, runs only on a
  rung-2 sandbox. Until the factory can provision, the predictor's
  experiments are reversible changes to the live factory, through the
  vault gate: one setting, one agent, a fixed span, and the old value
  restored at the end.
- **A demonstrated danger:** the predictor drafts the claim revision
  (claim loop), and the remedy goes to the dev or repair loop.
- **Forecasts (stage 2):** the predictor is the first forecaster, a
  named method competing on the calibration table.
- **Budget:** one experiment, meaning one intervention, every 2 days.
  That means at most one experiment action started per 48 hours, and at
  most one open experiment pitch. Observation is not counted.

This retires today's `prediction/unreviewed` issues: they become
experiment-sprint pitches and claim drafts.

First experiments the factory can run on itself before it has arms.
Each is a reversible change to the live factory through the vault gate:

- the Qwen dev's thinking budget (4096 against a lower value): merge
  time and stuck rate;
- the split of backlog work between the Grok and Qwen devs;
- whether shellcheck scoped to changed files changes `dev-ci-first-green`.

## Resources

The sense rung writes a structured inventory to the ops repo, replacing
the empty `RESOURCES.md` template. For each resource it records the
kind, host, capacity, the probe that reads current use, and the cost or
owner. Live resources today:

- llama-server slots (disinto is capped at 2 of 4);
- the xAI grants;
- CI workflows (3);
- node memory (12 GiB);
- your review time.

A pitch declares its expected use. The supervisor watches utilization
as monitors (§5). Policies for using a resource are predictor
experiments.

## Safety

- **Tiers:** sense is low. Provision and access requests are medium.
  Deploy, replicate and move are high. Graduation (§5) applies only to
  exercises with n ≥ 20 and success ≥ 0.9, and never to move.
- **Credentials:** each capability's credential is a Vault secret scoped
  to it. An action gets only the secrets and mounts it names
  (`action-vault/SCHEMA.md`).
- **Provisioning is a capability the factory acquires, not containers
  we start for it.** The factory runs in an LXC container on the host,
  so starting a sibling means LXD API access on the host. That is the
  most powerful credential it would hold, so the planner requests it
  (rung 2) and you grant it scoped:
  - a dedicated LXD project, e.g. `disinto-sandbox`;
  - a client certificate restricted to that project;
  - storage on `ai-pool` (`/opt/ai/lxd`) only, never the host root;
  - no access to the default project, where the factory's own container
    lives.

  The factory then starts and deletes its own containers inside those
  bounds. The project's limits sit on the host's choke points, memory
  and disk: at first at most 2 instances, 8 GiB of memory and 20 GiB of
  disk in total, revised from the sense report.
- **Move** is never automatic.

## Decisions (owner, 2026-10-07)

1. **LXD:** provisioning is a capability the factory acquires, in a
   sandbox project to begin with, and only on `/opt/ai`. Memory and
   disk on the host are exactly the choke points, so the limits target
   them (Safety).
2. **Porter:** it runs on `disinto.ai`; rungs 3 and 4 target that host.
   Checked 2026-10-07 from the factory's container: port 22 on
   `disinto.ai` (159.89.14.107) is reachable, the server accepts only
   public keys, and the factory holds no key for it. Its edge tunnel is
   unused (`EDGE_TUNNEL_HOST` unset); public traffic reaches the host
   through cloudflared. So rung 3 begins with the access request.
3. **Approval:** reuse the vault gate the architect's pitches already go
   through: merging the pitch PR is the decision, as for every vault
   action, and closing it unmerged rejects the pitch (The planner).
4. **Move:** undecided, "depends on what works". The requirement is that
   the factory can test new versions of itself (rung 5).
5. **Predictor budget:** one experiment every 2 days. The owner asked
   what a read-only experiment is. There is none: observation is not an
   experiment (The predictor).

## Bootstrap (owner, 2026-10-07)

We write three sprints. After them the organs pitch everything else,
including the capability rungs: the planner develops its own arms.

1. **A pitch becomes a sprint** (internal). A pitch carries its sprint
   block. On merge, the filer creates the milestone with the block and
   files the sub-issues into it. The decision reaches the tape: approved
   on merge, rejected when closed, `context.pitch` = the ops PR.
   - effect: `probes/sprint-pitches-decided.sh`, expect `>= 1`, soak 14d
   - its first decision: sprint 2, pitched through the gate
2. **The planner pitches** (internal). The planner reads `VISION.md`,
   the claims, the capability claims and resources. It pitches the
   lowest missing rung, the next vision step, or an access request, or
   nothing. The prose tree is retired.
   - runs on Grok, deployed only after the 2026-10-12 readout
   - effect: a planner-authored pitch decided within 14 days; it should
     be rung 1, sense
3. **The predictor experiments.** Targets, interventions through the
   vault gate, the budget, claim drafts.
   - written once the planner shows the gate works

The organs run on Grok: they run rarely, their reasoning matters, and it
keeps them off the 2 llama slots.

## Open questions

- **The account for rungs 3 and 4:** which account on `disinto.ai`
  does the factory's key use? The `porter` user is the customer door;
  updating the porter needs an admin account. The planner's first
  access request asks for exactly this.
