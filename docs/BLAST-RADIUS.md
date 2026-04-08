# Vault blast-radius tiers

## Tiers

| Tier | Meaning | Dispatch path |
|------|---------|---------------|
| low | Revertable, no external side effects | Direct commit to ops main; no human gate |
| medium | Significant but reversible | PR on ops repo; blocks calling agent until merged |
| high | Irreversible or high-blast-radius | PR on ops repo; hard blocks |

## Which agents are affected

Vault-blocking applies to: predictor, planner, architect, deploy pipelines, releases, shipping.
It does NOT apply to dev-agent — dev-agent work is always committed to a feature branch and
revertable via git revert. Dev-agent never needs a vault gate.

## Default tier

Unknown formulas default to `high`. When adding a new formula, add it to
`vault/policy.toml` (in ops repo, seeded during disinto init from disinto repo template).

## Per-action override

A vault action TOML may include `blast_radius = "low"` to override the policy tier
for that specific invocation. Use sparingly — policy.toml is the authoritative source.
