# Provision: the DigitalOcean rung

The owner's direction of 2026-11-04: the machine lacks the memory for
LXD sandboxes, so rung 3 of the capability ladder starts on
DigitalOcean. An action creates a throwaway droplet with a token scoped
to droplets, reports its address and deletes it (`organs.md`, Decisions
2026-11-04). This note is the detail behind that rung. It comes after
update-self (`self-update.md`).

## Today

The ladder already names the rung. `planner/ladder.sh` prints
`provision` once the sense and update-self claims exist and neither is
challenged, and `planner/pitch-or-idle.sh` opens its pitch: effect
`probes/can-provision.sh`, `expect: >= 1`. #2166 sets its level to
`made` and its soak to 7 days, and points the architect at this note.

The way an action runs is built, but unused:

1. An organ calls `vault_request` (`lib/action-vault.sh`). That opens
   an ops PR, `vault: <id>`, adding `vault/actions/<id>.toml`.
2. The gate merges a medium or high PR at once and queues one notice
   to the owner (#2037).
3. The dispatcher (`docker/edge/dispatcher.sh`, in the edge job's
   caddy task) pulls the ops repo every 60 s. It validates the TOML
   (`action-vault/vault-env.sh`), resolves each secret the TOML names
   with `load_secret` (`lib/secrets.sh`: `/secrets/<NAME>.env`, then
   the environment, then `secrets/<NAME>.enc`) and starts the runner
   with `docker run` on `disinto/agents:local`.
4. The runner (`docker/runner/entrypoint-runner.sh`) runs
   `formulas/<formula>.sh` in bash, with no model.
5. The dispatcher pushes `vault/actions/<id>.result.json` and appends a
   proposal (loop `vault`, class = the formula) and an outcome (bits
   `returned` and `ok`, the result file as payload) to the tape.

On 2026-11-07 the tape held no `vault` record at all. The last actions
in the ops repo are four releases from April, resolved by hand. So the
rung's first run is also the first run of this path since the tape
began.

What is missing:
- a DigitalOcean token, which only the owner can create;
- a way to hand a runner any secret. The allowlist
  (`VAULT_ALLOWED_SECRETS`) has eight names and none for DigitalOcean.
  The caddy task renders forge tokens only; its role reads
  `kv/disinto/chat`. The Nomad backend (`nomad/jobs/vault-runner.hcl`)
  renders six runner secrets, but the live dispatcher uses the docker
  backend, and the registered `vault-runner` job dates from 2026-04-22;
- the formula, its settings, the probe and the claim;
- something that files the action.

## The action

Formula `provision-droplet`, `formulas/provision-droplet.sh`, bash. Its
settings are in the ops repo's `packs/provision.toml`: region (`fra1` to
begin with), size (`s-1vcpu-512mb-10gb`, the smallest), a stock Debian
image, the tag `disinto-throwaway`, an SSH key id, and the limits below.

1. **Reap.** List the droplets tagged `disinto-throwaway`. Delete every
   one older than `max_age_s` (3600). These are leftovers of a run that
   died. Count them.
2. **Create** one droplet, named `disinto-throwaway-<action id>`, with
   the tag. It gets one SSH public key the owner adds to the team once,
   so DigitalOcean emails no root password for each run. Nobody holds
   the private half, and nobody logs in: this rung proves create,
   address and delete, nothing more.
3. **Wait** until it is `active` with a public IPv4 address, at most
   `active_timeout_s` (300).
4. **Delete** it. Wait until a read of it returns 404, at most
   `gone_timeout_s` (120).
5. A trap on exit deletes the droplet when any step after the create
   fails.
6. Write the result file: droplet id, region, size, address, seconds to
   active, seconds to gone, and the count reaped.

Exit 0 only when the droplet had an address and is confirmed gone.
Cost: a few minutes of the smallest droplet per run.

**Who files it.** The gardener, beside its claim checks. It calls
`vault_request provision-droplet-<YYYYMMDD>` when all three hold:
- no `provision-droplet` outcome with `ok` 1 in the last 6 days;
- no `provision-droplet` outcome of any kind in the last 24 hours, so
  a failing run is retried at most once a day;
- no `provision-droplet-*` action waiting in `vault/actions/` without a
  result.

That is one run a week while it works, enough for the claim's 7-day
window. Each run sends one notice to the owner, from the gate.

## The token

The owner creates it, in a DigitalOcean team of its own.

DigitalOcean scopes a token by resource type, not by droplet or by tag.
A droplet token in the team that holds `self.disinto.ai` could delete
that droplet. In a team of its own, the worst a leaked token can do is
create droplets there, up to the team's droplet limit.

- **Scopes:** droplet create, read and delete; tag create and read, for
  the throwaway tag; the read scopes DigitalOcean adds with them.
- **Where:** Vault `kv/disinto/runner/DO_TOKEN`, field `value`, the
  path every runner secret follows. The owner writes it on the host,
  so it never passes through a chat, the forge or a log.
- **Delivery:** `DO_TOKEN` joins the allowlist. The caddy task renders
  `/secrets/DO_TOKEN.env` from that path, the first place
  `load_secret` looks, through a policy `runner-DO_TOKEN` on the edge's
  role. An absent secret renders empty, and the run fails cleanly.
  `vault-runner.hcl` gets the same template as its six other secrets,
  for when the dispatcher moves to the Nomad backend.

The caddy task then holds the token for every action it dispatches.
The team is the bound: whatever runs, it reaches only throwaway
droplets. The owner can revoke the token at any time; the runs then
fail and the claim is challenged.

## Records and the grade

- No new loop. The dispatcher's records are the evidence: a proposal of
  loop `vault` and class `provision-droplet`, and an outcome with bits
  `returned` and `ok` and the result file as its payload.
- The probe, `probes/can-provision.sh`, counts the distinct
  `provision-droplet` proposals whose outcome has `ok` 1 in the window.
  It reads the tape only: no network and no token (AD-006). It is
  merged before the pitch is approved; the gate does not merge a pitch
  whose probe is missing.
- The claim is `can-provision`: "the factory provisions a machine: it
  creates a throwaway droplet on DigitalOcean, gets its address and
  deletes it", `>= 1` over 7 days. It follows as an ops PR once the
  sprint's effect is met.
- The sprint aims at level `made`: a probe merged before approval
  confirms it. A grade of 0.5 is not above 0.5, so the gate stays
  transparent.
- **Tier.** Provision is medium (`organs.md`, Safety). Neither policy
  file lists `provision-droplet` yet, so it classes as high, which the
  gate also merges at once; only the notice's tier differs. The line
  `provision-droplet = "medium"` goes in ops `vault/policy.toml`, a
  file behind the wall, so the owner merges it. It blocks nothing.

## The wall

No new entry. What bounds this rung is the token's team, not a
protected file. What gates actions (`action-vault/policy.toml`, ops
`vault/policy.toml`) is already behind the wall.

## Not in it yet

- **Logging in.** No one holds a key to the droplet. Reach (rung 4) and
  replicate (rung 6) need one.
- **The Nomad backend.** The dispatcher keeps the docker backend.
  Per-dispatch policies, which give each run only the secrets it names,
  come with the move.
- **LXD on the machine.** Deferred until the memory allows it
  (`organs.md`, Decisions 2026-11-04). Its bounds are written there.

## Build order

The rung's sprint carries these as sub-issues:

1. **The secret.** `DO_TOKEN` in the allowlist
   (`action-vault/vault-env.sh`). The caddy task's template in
   `nomad/jobs/edge.hcl`, the policy `vault/policies/runner-DO_TOKEN.hcl`
   on the edge's role in `vault/roles.yaml`, and the same template in
   `nomad/jobs/vault-runner.hcl`.
2. **The formula.** `formulas/provision-droplet.sh` and
   `packs/provision.toml`. The tests stub `curl` for the DigitalOcean
   API: create, active, delete, 404; a failure after the create still
   deletes; a leftover older than `max_age_s` is reaped and a younger
   one is not.
3. **The filing.** The gardener's step that files the action, with the
   three conditions above.

The owner's steps, outside the sprint:
- the team, its SSH key and the token, written to Vault on the host;
- the tier line in ops `vault/policy.toml`;
- applying the edge jobspec and the Vault policy after item 1 merges
  (after `main`'s pipeline finishes, since an edge restart breaks a
  starting CI clone).

The probe is in the ops repo before the pitch.
