#!/usr/bin/env bats
# =============================================================================
# tests/disinto-init-nomad.bats — Regression guard for `disinto init`
# backend dispatch (S0.5, issue #825).
#
# Exercises the three CLI paths the Nomad+Vault migration cares about:
#   1. --backend=nomad  --dry-run         → cluster-up step list
#   2. --backend=nomad --empty --dry-run  → same, with "--empty" banner
#   3. --backend=docker --dry-run         → docker path unaffected
#
# A throw-away `placeholder/repo` slug satisfies the CLI's positional-arg
# requirement (the nomad dispatcher never touches it). --dry-run on both
# backends short-circuits before any network/filesystem mutation, so the
# suite is hermetic — no Forgejo, no sudo, no real cluster.
# =============================================================================

setup_file() {
  export DISINTO_ROOT
  DISINTO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export DISINTO_BIN="${DISINTO_ROOT}/bin/disinto"
  [ -x "$DISINTO_BIN" ] || {
    echo "disinto binary not executable: $DISINTO_BIN" >&2
    return 1
  }
}

# ── --backend=nomad --dry-run ────────────────────────────────────────────────

@test "disinto init --backend=nomad --dry-run exits 0 and prints the step list" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --dry-run
  [ "$status" -eq 0 ]

  # Dispatcher banner (cluster-up mode, no --empty).
  [[ "$output" == *"nomad backend: default (cluster-up; jobs deferred to Step 1)"* ]]

  # All nine cluster-up dry-run steps, in order.
  [[ "$output" == *"[dry-run] Step 1/9: install nomad + vault binaries + docker daemon"* ]]
  [[ "$output" == *"[dry-run] Step 2/9: write + enable nomad.service (NOT started)"* ]]
  [[ "$output" == *"[dry-run] Step 3/9: write + enable vault.service + vault.hcl (NOT started)"* ]]
  [[ "$output" == *"[dry-run] Step 4/9: create host-volume dirs under /srv/disinto/"* ]]
  [[ "$output" == *"[dry-run] Step 5/9: install /etc/nomad.d/server.hcl + client.hcl from repo"* ]]
  [[ "$output" == *"[dry-run] Step 6/9: first-run vault init + persist unseal.key + root.token"* ]]
  [[ "$output" == *"[dry-run] Step 7/9: systemctl start vault + poll until unsealed"* ]]
  [[ "$output" == *"[dry-run] Step 8/9: systemctl start nomad + poll until ≥1 node ready"* ]]
  [[ "$output" == *"[dry-run] Step 9/9: write /etc/profile.d/disinto-nomad.sh"* ]]

  [[ "$output" == *"Dry run complete — no changes made."* ]]
}

# ── --backend=nomad --empty --dry-run ────────────────────────────────────────

@test "disinto init --backend=nomad --empty --dry-run prints the --empty banner + step list" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --empty --dry-run
  [ "$status" -eq 0 ]

  # --empty changes the dispatcher banner but not the step list — Step 1
  # of the migration will branch on $empty to gate job deployment; today
  # both modes invoke the same cluster-up dry-run.
  [[ "$output" == *"nomad backend: --empty (cluster-up only, no jobs)"* ]]
  [[ "$output" == *"[dry-run] Step 1/9: install nomad + vault binaries + docker daemon"* ]]
  [[ "$output" == *"Dry run complete — no changes made."* ]]
}

# ── --backend=docker (regression guard) ──────────────────────────────────────

@test "disinto init --backend=docker does NOT dispatch to the nomad path" {
  run "$DISINTO_BIN" init placeholder/repo --backend=docker --dry-run
  [ "$status" -eq 0 ]

  # Negative assertion: the nomad dispatcher banners must be absent.
  [[ "$output" != *"nomad backend:"* ]]
  [[ "$output" != *"[dry-run] Step 1/9: install nomad + vault binaries + docker daemon"* ]]

  # Positive assertion: docker-path output still appears — the existing
  # docker dry-run printed "=== disinto init ===" before listing the
  # intended forge/compose actions.
  [[ "$output" == *"=== disinto init ==="* ]]
  [[ "$output" == *"── Dry-run: intended actions ────"* ]]
}

# ── Flag syntax: --flag=value vs --flag value ────────────────────────────────

# Both forms must work. The bin/disinto flag loop has separate cases for
# `--backend value` and `--backend=value`; a regression in either would
# silently route to the docker default, which is the worst failure mode
# for a mid-migration dispatcher ("loud-failing stub" lesson from S0.4).
@test "disinto init --backend nomad (space-separated) dispatches to nomad" {
  run "$DISINTO_BIN" init placeholder/repo --backend nomad --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"nomad backend: default"* ]]
  [[ "$output" == *"[dry-run] Step 1/9: install nomad + vault binaries + docker daemon"* ]]
}

# ── Flag validation ──────────────────────────────────────────────────────────

@test "--backend=bogus is rejected with a clear error" {
  run "$DISINTO_BIN" init placeholder/repo --backend=bogus --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid --backend value"* ]]
}

@test "--empty without --backend=nomad is rejected" {
  run "$DISINTO_BIN" init placeholder/repo --backend=docker --empty --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"--empty is only valid with --backend=nomad"* ]]
}

# ── Positional vs flag-first invocation (#835) ───────────────────────────────
#
# Before the #835 fix, disinto_init eagerly consumed $1 as repo_url *before*
# argparse ran. That swallowed `--backend=nomad` as a repo_url and then
# complained that `--empty` required a nomad backend — the nonsense error
# flagged during S0.1 end-to-end verification. The cases below pin the CLI
# to the post-fix contract: the nomad path accepts flag-first invocation,
# the docker path still errors helpfully on a missing repo_url.

@test "disinto init --backend=nomad --empty --dry-run (no positional) dispatches to nomad" {
  run "$DISINTO_BIN" init --backend=nomad --empty --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"nomad backend: --empty (cluster-up only, no jobs)"* ]]
  [[ "$output" == *"[dry-run] Step 1/9: install nomad + vault binaries + docker daemon"* ]]
  # The bug symptom must be absent — backend was misdetected as docker
  # when --backend=nomad got swallowed as repo_url.
  [[ "$output" != *"--empty is only valid with --backend=nomad"* ]]
}

@test "disinto init --backend nomad --dry-run (space-separated, no positional) dispatches to nomad" {
  run "$DISINTO_BIN" init --backend nomad --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"nomad backend: default"* ]]
  [[ "$output" == *"[dry-run] Step 1/9: install nomad + vault binaries + docker daemon"* ]]
}

@test "disinto init (no args) still errors with 'repo URL required'" {
  run "$DISINTO_BIN" init
  [ "$status" -ne 0 ]
  [[ "$output" == *"repo URL required"* ]]
}

@test "disinto init --backend=docker (no positional) errors with 'repo URL required', not 'Unknown option'" {
  run "$DISINTO_BIN" init --backend=docker
  [ "$status" -ne 0 ]
  [[ "$output" == *"repo URL required"* ]]
  [[ "$output" != *"Unknown option"* ]]
}

# ── --with flag tests ─────────────────────────────────────────────────────────

@test "disinto init --backend=nomad --with forgejo --dry-run prints deploy plan" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --with forgejo --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"services to deploy: forgejo"* ]]
  [[ "$output" == *"[deploy] [dry-run] nomad job validate"* ]]
  [[ "$output" == *"[deploy] [dry-run] nomad job run -detach"* ]]
  [[ "$output" == *"[deploy] dry-run complete"* ]]
}

# S2.6 / #928 — every --with <svc> that ships tools/vault-seed-<svc>.sh
# must auto-invoke the seeder before deploy.sh runs. forgejo is the
# only service with a seeder today, so the dry-run plan must include
# its seed line when --with forgejo is set. The seed block must also
# appear BEFORE the deploy block (seeded secrets must exist before
# nomad reads the template stanza) — pinned here by scanning output
# order. Services without a seeder (e.g. unknown hypothetical future
# ones) are silently skipped by the loop convention.
@test "disinto init --backend=nomad --with forgejo --dry-run prints seed plan before deploy plan" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --with forgejo --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Vault seed dry-run"* ]]
  [[ "$output" == *"tools/vault-seed-forgejo.sh --dry-run"* ]]
  # Order: seed header must appear before deploy header.
  local seed_line deploy_line
  seed_line=$(echo "$output" | grep -n "Vault seed dry-run" | head -1 | cut -d: -f1)
  deploy_line=$(echo "$output" | grep -n "Deploy services dry-run" | head -1 | cut -d: -f1)
  [ -n "$seed_line" ]
  [ -n "$deploy_line" ]
  [ "$seed_line" -lt "$deploy_line" ]
}

# Regression guard (PR #929 review): `sudo -n VAR=val -- cmd` is subject
# to sudoers env_reset policy and silently drops VAULT_ADDR unless it's
# in env_keep (it isn't in default configs). vault-seed-forgejo.sh
# requires VAULT_ADDR and dies at its own precondition check if unset,
# so the non-root branch MUST invoke `sudo -n -- env VAR=val cmd` so
# that `env` sets the variable in the child process regardless of
# sudoers policy. This grep-level guard catches a revert to the unsafe
# form that silently broke non-root seed runs on a fresh LXC.
@test "seed loop invokes sudo via 'env VAR=val' (bypasses sudoers env_reset)" {
  run grep -F 'sudo -n -- env "VAULT_ADDR=' "$DISINTO_BIN"
  [ "$status" -eq 0 ]
  # Negative: no bare `sudo -n "VAR=val" --` form anywhere in the file.
  run grep -F 'sudo -n "VAULT_ADDR=' "$DISINTO_BIN"
  [ "$status" -ne 0 ]
}

@test "disinto init --backend=nomad --with forgejo,forgejo --dry-run handles comma-separated services" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --with forgejo,forgejo --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"services to deploy: forgejo,forgejo"* ]]
}

@test "disinto init --backend=docker --with forgejo errors with '--with requires --backend=nomad'" {
  run "$DISINTO_BIN" init placeholder/repo --backend=docker --with forgejo
  [ "$status" -ne 0 ]
  [[ "$output" == *"--with requires --backend=nomad"* ]]
}

@test "disinto init --backend=nomad --empty --with forgejo errors with mutually exclusive" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --empty --with forgejo
  [ "$status" -ne 0 ]
  [[ "$output" == *"--empty and --with are mutually exclusive"* ]]
}

@test "disinto init --backend=nomad --with unknown-service errors with unknown service" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --with unknown-service --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown service"* ]]
  [[ "$output" == *"known: forgejo, woodpecker-server, woodpecker-agent, agents, staging, chat, edge"* ]]
}

# S3.4: woodpecker auto-expansion and forgejo auto-inclusion
@test "disinto init --backend=nomad --with woodpecker auto-expands to server+agent" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --with woodpecker --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"services to deploy: forgejo,woodpecker-server,woodpecker-agent"* ]]
  [[ "$output" == *"deployment order: forgejo woodpecker-server woodpecker-agent"* ]]
}

@test "disinto init --backend=nomad --with woodpecker auto-includes forgejo with note" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --with woodpecker --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Note: --with woodpecker implies --with forgejo"* ]]
}

@test "disinto init --backend=nomad --with forgejo,woodpecker expands woodpecker" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --with forgejo,woodpecker --dry-run
  [ "$status" -eq 0 ]
  # Order follows input: forgejo first, then woodpecker expanded
  [[ "$output" == *"services to deploy: forgejo,woodpecker-server,woodpecker-agent"* ]]
  [[ "$output" == *"deployment order: forgejo woodpecker-server woodpecker-agent"* ]]
}

@test "disinto init --backend=nomad --with woodpecker seeds both forgejo and woodpecker" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --with woodpecker --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"tools/vault-seed-forgejo.sh --dry-run"* ]]
  [[ "$output" == *"tools/vault-seed-woodpecker.sh --dry-run"* ]]
}

@test "disinto init --backend=nomad --with forgejo,woodpecker deploys all three services" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --with forgejo,woodpecker --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"[deploy] [dry-run] nomad job validate"*"forgejo.hcl"* ]]
  [[ "$output" == *"[deploy] [dry-run] nomad job validate"*"woodpecker-server.hcl"* ]]
  [[ "$output" == *"[deploy] [dry-run] nomad job validate"*"woodpecker-agent.hcl"* ]]
}

@test "disinto init --backend=nomad --with forgejo (flag=value syntax) works" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --with=forgejo --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"services to deploy: forgejo"* ]]
}

@test "disinto init --backend=nomad --with forgejo --empty --dry-run rejects in any order" {
  run "$DISINTO_BIN" init placeholder/repo --with forgejo --backend=nomad --empty --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"--empty and --with are mutually exclusive"* ]]
}

# ── --import-env / --import-sops / --age-key (S2.5, #883) ────────────────────
#
# Step 2.5 wires Vault policies + JWT auth + optional KV import into
# `disinto init --backend=nomad`. The tests below exercise the flag
# grammar (who-requires-whom + who-requires-backend=nomad) and the
# dry-run plan shape (each --import-* flag prints its own path line,
# independently). A prior attempt at this issue regressed the "print
# every set flag" invariant by using if/elif — covered by the
# "--import-env --import-sops --age-key" case.

@test "disinto init --backend=nomad --import-env only is accepted" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --import-env /tmp/.env --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"--import-env"* ]]
  [[ "$output" == *"env file:  /tmp/.env"* ]]
}

@test "disinto init --backend=nomad --import-sops without --age-key errors" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --import-sops /tmp/.env.vault.enc --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"--import-sops requires --age-key"* ]]
}

@test "disinto init --backend=nomad --age-key without --import-sops errors" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --age-key /tmp/keys.txt --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"--age-key requires --import-sops"* ]]
}

@test "disinto init --backend=docker --import-env errors with backend requirement" {
  run "$DISINTO_BIN" init placeholder/repo --backend=docker --import-env /tmp/.env
  [ "$status" -ne 0 ]
  [[ "$output" == *"--import-env, --import-sops, and --age-key require --backend=nomad"* ]]
}

@test "disinto init --backend=nomad --import-sops --age-key --dry-run shows import plan" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --import-sops /tmp/.env.vault.enc --age-key /tmp/keys.txt --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Vault import dry-run"* ]]
  [[ "$output" == *"--import-sops"* ]]
  [[ "$output" == *"--age-key"* ]]
  [[ "$output" == *"sops file: /tmp/.env.vault.enc"* ]]
  [[ "$output" == *"age key:   /tmp/keys.txt"* ]]
}

# When all three flags are set, each one must print its own path line —
# if/elif regressed this to "only one printed" in a prior attempt (#883).
@test "disinto init --backend=nomad --import-env --import-sops --age-key --dry-run shows full import plan" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --import-env /tmp/.env --import-sops /tmp/.env.vault.enc --age-key /tmp/keys.txt --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Vault import dry-run"* ]]
  [[ "$output" == *"env file:  /tmp/.env"* ]]
  [[ "$output" == *"sops file: /tmp/.env.vault.enc"* ]]
  [[ "$output" == *"age key:   /tmp/keys.txt"* ]]
}

@test "disinto init --backend=nomad without import flags shows skip message" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"no --import-env/--import-sops"* ]]
  [[ "$output" == *"skipping"* ]]
}

@test "disinto init --backend=nomad --import-env --import-sops --age-key --with forgejo --dry-run shows all plans" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --import-env /tmp/.env --import-sops /tmp/.env.vault.enc --age-key /tmp/keys.txt --with forgejo --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Vault import dry-run"* ]]
  [[ "$output" == *"Vault policies dry-run"* ]]
  [[ "$output" == *"Vault auth dry-run"* ]]
  [[ "$output" == *"Deploy services dry-run"* ]]
}

@test "disinto init --backend=nomad --dry-run prints policies + auth plan even without --import-*" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --dry-run
  [ "$status" -eq 0 ]
  # Policies + auth run on every nomad path (idempotent), so the dry-run
  # plan always lists them — regardless of whether --import-* is set.
  [[ "$output" == *"Vault policies dry-run"* ]]
  [[ "$output" == *"Vault auth dry-run"* ]]
  [[ "$output" != *"Vault import dry-run"* ]]
}

# --import-env=PATH (=-form) must work alongside --import-env PATH.
@test "disinto init --backend=nomad --import-env=PATH (equals form) works" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --import-env=/tmp/.env --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"env file:  /tmp/.env"* ]]
}

# --empty short-circuits after cluster-up: no policies, no auth, no
# import, no deploy. The dry-run plan must match that — cluster-up plan
# appears, but none of the S2.x section banners do.
@test "disinto init --backend=nomad --empty --dry-run skips policies/auth/import sections" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --empty --dry-run
  [ "$status" -eq 0 ]
  # Cluster-up still runs (it's what --empty brings up).
  [[ "$output" == *"Cluster-up dry-run"* ]]
  # Policies + auth + import must NOT appear under --empty.
  [[ "$output" != *"Vault policies dry-run"* ]]
  [[ "$output" != *"Vault auth dry-run"* ]]
  [[ "$output" != *"Vault import dry-run"* ]]
  [[ "$output" != *"no --import-env/--import-sops"* ]]
}

# --empty + any --import-* flag silently does nothing (import is skipped),
# so the CLI rejects the combination up front rather than letting it
# look like the import "succeeded".
@test "disinto init --backend=nomad --empty --import-env errors" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --empty --import-env /tmp/.env --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"--empty and --import-env/--import-sops/--age-key are mutually exclusive"* ]]
}

@test "disinto init --backend=nomad --empty --import-sops --age-key errors" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --empty --import-sops /tmp/.env.vault.enc --age-key /tmp/keys.txt --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"--empty and --import-env/--import-sops/--age-key are mutually exclusive"* ]]
}

# S4.2: agents service auto-expansion and dependencies
@test "disinto init --backend=nomad --with agents auto-includes forgejo and woodpecker" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --with agents --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"services to deploy: forgejo,agents,woodpecker-server,woodpecker-agent"* ]]
  [[ "$output" == *"Note: --with agents implies --with forgejo"* ]]
  [[ "$output" == *"Note: --with agents implies --with woodpecker"* ]]
}

@test "disinto init --backend=nomad --with agents deploys in correct order" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --with agents --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"deployment order: forgejo woodpecker-server woodpecker-agent agents"* ]]
}

@test "disinto init --backend=nomad --with agents seeds agents service" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --with agents --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"tools/vault-seed-forgejo.sh --dry-run"* ]]
  [[ "$output" == *"tools/vault-seed-woodpecker.sh --dry-run"* ]]
  [[ "$output" == *"tools/vault-seed-agents.sh --dry-run"* ]]
}

@test "disinto init --backend=nomad --with agents deploys all four services" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --with agents --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"[deploy] [dry-run] nomad job validate"*"forgejo.hcl"* ]]
  [[ "$output" == *"[deploy] [dry-run] nomad job validate"*"woodpecker-server.hcl"* ]]
  [[ "$output" == *"[deploy] [dry-run] nomad job validate"*"woodpecker-agent.hcl"* ]]
  [[ "$output" == *"[deploy] [dry-run] nomad job validate"*"agents.hcl"* ]]
}

@test "disinto init --backend=nomad --with woodpecker,agents expands correctly" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --with woodpecker,agents --dry-run
  [ "$status" -eq 0 ]
  # woodpecker expands to server+agent, agents is already explicit
  # forgejo is auto-included by agents
  [[ "$output" == *"services to deploy: forgejo,woodpecker-server,woodpecker-agent,agents"* ]]
  [[ "$output" == *"deployment order: forgejo woodpecker-server woodpecker-agent agents"* ]]
}

# S5.1 / #1035 — edge service seeds ops-repo (dispatcher FORGE_TOKEN)
@test "disinto init --backend=nomad --with edge deploys edge" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --with edge --dry-run
  [ "$status" -eq 0 ]
  # edge depends on all backend services, so all are included
  [[ "$output" == *"services to deploy: edge,forgejo"* ]]
  [[ "$output" == *"deployment order: forgejo woodpecker-server woodpecker-agent agents staging chat edge"* ]]
  [[ "$output" == *"[deploy] [dry-run] nomad job validate"*"edge.hcl"* ]]
}

@test "disinto init --backend=nomad --with edge seeds ops-repo" {
  run "$DISINTO_BIN" init placeholder/repo --backend=nomad --with edge --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"tools/vault-seed-ops-repo.sh --dry-run"* ]]
}
