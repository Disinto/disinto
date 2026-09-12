#!/usr/bin/env bats
# tests/lib-ops-setup.bats — migrate_ops_repo ledger layout (#1297)
#
# Covers the run-ledger layout migration on an EXISTING ops tree: runs/,
# artifacts/ (gitignored payloads, .gitkeep kept) and campaigns/ must be
# created idempotently without clobbering pre-existing vault/ content.

load '../lib/ops-setup.sh'

setup() {
  OPS="${BATS_TEST_TMPDIR}/ops"
  mkdir -p "$OPS"
  cd "$OPS" || return 1
  git init -q -b main .
  git config user.email "test@example.com"
  git config user.name "Test"
  git config commit.gpgsign false
  # Pre-existing ops tree with vault content that must survive migration
  mkdir -p vault/pending
  printf 'id: pre-existing-item\nformula: release\n' > vault/pending/item-1.toml
  git add -A
  git commit -q -m "pre-existing ops tree"
}

teardown() {
  cd /
  rm -rf "$OPS"
}

@test "migrate creates runs/, artifacts/, campaigns/ on an existing tree" {
  migrate_ops_repo "$OPS"
  [ -d "$OPS/runs" ]
  [ -d "$OPS/artifacts" ]
  [ -d "$OPS/campaigns" ]
  [ -f "$OPS/runs/.gitkeep" ]
  [ -f "$OPS/artifacts/.gitkeep" ]
  [ -f "$OPS/campaigns/.gitkeep" ]
  [ -f "$OPS/artifacts/.gitignore" ]
  [ -f "$OPS/runs/README.md" ]
}

@test "migrate does not clobber pre-existing vault/ content" {
  local before
  before="$(cat vault/pending/item-1.toml)"
  migrate_ops_repo "$OPS"
  [ "$(cat vault/pending/item-1.toml)" = "$before" ]
  # The migration commit may ADD .gitkeep files to empty vault/ subdirs but
  # must not modify or delete anything under vault/
  local touched
  touched="$(git show --name-status --format= HEAD -- vault/ | awk -F'\t' '$1 != "A"')"
  [ -z "$touched" ]
}

@test "migrate is idempotent — second run makes no commit" {
  migrate_ops_repo "$OPS"
  local sha1
  sha1="$(git rev-parse HEAD)"
  migrate_ops_repo "$OPS"
  [ "$(git rev-parse HEAD)" = "$sha1" ]
}

@test "artifacts/ gitignores payloads but keeps .gitkeep" {
  migrate_ops_repo "$OPS"
  mkdir -p artifacts/run-1
  head -c 1024 /dev/zero > artifacts/run-1/big.bin
  # Payload must be ignored by git
  git check-ignore -q artifacts/run-1/big.bin
  # Only .gitkeep and .gitignore under artifacts/ end up tracked
  local tracked
  tracked="$(git ls-files artifacts/ | sort)"
  [ "$tracked" = "$(printf 'artifacts/.gitignore\nartifacts/.gitkeep')" ]
}

@test "runs/README.md states records vs payloads split" {
  migrate_ops_repo "$OPS"
  grep -q "Records belong in git" "$OPS/runs/README.md"
  grep -q "artifacts/" "$OPS/runs/README.md"
  grep -q "gitignored" "$OPS/runs/README.md"
}
