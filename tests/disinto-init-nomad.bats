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
  [[ "$output" == *"[dry-run] Step 1/9: install nomad + vault binaries"* ]]
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
  [[ "$output" == *"[dry-run] Step 1/9: install nomad + vault binaries"* ]]
  [[ "$output" == *"Dry run complete — no changes made."* ]]
}

# ── --backend=docker (regression guard) ──────────────────────────────────────

@test "disinto init --backend=docker does NOT dispatch to the nomad path" {
  run "$DISINTO_BIN" init placeholder/repo --backend=docker --dry-run
  [ "$status" -eq 0 ]

  # Negative assertion: the nomad dispatcher banners must be absent.
  [[ "$output" != *"nomad backend:"* ]]
  [[ "$output" != *"[dry-run] Step 1/9: install nomad + vault binaries"* ]]

  # Positive assertion: docker-path output still appears — the existing
  # docker dry-run printed "=== disinto init ===" before listing the
  # intended forge/compose actions.
  [[ "$output" == *"=== disinto init ==="* ]]
  [[ "$output" == *"── Dry-run: intended actions ────"* ]]
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
