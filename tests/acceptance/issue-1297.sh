#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1297.sh
#
# Issue #1297: ops ledger runs/, artifacts/, campaigns/.
# migrate_ops_repo (lib/ops-setup.sh) must seed the three directories
# idempotently on an existing ops tree without clobbering vault/, and
# artifacts/ must gitignore payloads while keeping .gitkeep. The new writer
# lib/run-ledger.sh (run_ledger_append) must write a valid row to
# runs/<id>.json and refuse a duplicate id (append-only).
#
# Verifies (hermetic — a throwaway ops repo in a mktemp dir only, no forge,
# no nomad, no live repo mutation):
#   1. lib/ops-setup.sh and lib/run-ledger.sh exist in the code repo.
#   2. migrate_ops_repo on an existing tree creates runs/, artifacts/,
#      campaigns/ with .gitkeep files.
#   3. Pre-existing vault/ content is untouched by the migration.
#   4. artifacts/ has a gitignore for payloads and keeps .gitkeep.
#   5. runs/README.md states the records-in-git vs payloads-gitignored split.
#   6. run_ledger_append writes a valid row; a second append with the same
#      id fails (append-only).
#
# Run via: tools/run-acceptance.sh 1297
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq git mktemp

export USER="${USER:-$(id -un)}"
export HOME="${HOME:-/root}"

# ── 1. The code artifacts exist ──────────────────────────────────────────────
ac_assert_file "$REPO_ROOT/lib/ops-setup.sh" "lib/ops-setup.sh is missing"
ac_assert_file "$REPO_ROOT/lib/run-ledger.sh" "lib/run-ledger.sh is missing"
grep -q "run_ledger_append" "$REPO_ROOT/lib/run-ledger.sh" \
  || ac_fail "lib/run-ledger.sh does not define run_ledger_append"
grep -q "migrate_ops_repo" "$REPO_ROOT/lib/ops-setup.sh" \
  || ac_fail "lib/ops-setup.sh does not define migrate_ops_repo"

# ── Build a throwaway ops repo (mktemp only, never touches live state) ──────
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

OPS="$TMP_DIR/ops"
mkdir -p "$OPS/vault/pending"
git -C "$OPS" init -q
git -C "$OPS" symbolic-ref HEAD refs/heads/main
git -C "$OPS" config user.email test@example.com
git -C "$OPS" config user.name test
printf 'id: pre-existing-item\nformula: release\n' > "$OPS/vault/pending/item-1.toml"
git -C "$OPS" add -A
git -C "$OPS" commit -q -m "pre-existing ops tree"

# shellcheck disable=SC1091
source "$REPO_ROOT/lib/ops-setup.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/run-ledger.sh"

ac_log "running migrate_ops_repo on the throwaway ops tree"
migrate_ops_repo "$OPS" >/dev/null

# ── 2. The three dirs exist with .gitkeep ────────────────────────────────────
for d in runs artifacts campaigns; do
  [ -d "$OPS/$d" ] || ac_fail "migrate did not create ${d}/"
  [ -f "$OPS/${d}/.gitkeep" ] || ac_fail "${d}/.gitkeep missing"
done

# ── 3. Pre-existing vault/ content is untouched ──────────────────────────────
[ "$(cat "$OPS/vault/pending/item-1.toml")" = "$(printf 'id: pre-existing-item\nformula: release')" ] \
  || ac_fail "migrate clobbered pre-existing vault/pending content"
# The migration commit may ADD .gitkeep files to empty vault/ subdirs, but it
# must not modify or delete anything under vault/
touched="$(git -C "$OPS" show --name-status --format= HEAD -- vault/ | awk -F'\t' '$1 != "A"')"
[ -z "$touched" ] || ac_fail "migration commit modifies or deletes vault/ paths"

# ── 4. artifacts/ gitignores payloads but keeps .gitkeep ─────────────────────
[ -f "$OPS/artifacts/.gitignore" ] || ac_fail "artifacts/.gitignore is missing"
grep -q '^\*' "$OPS/artifacts/.gitignore" \
  || ac_fail "artifacts/.gitignore does not ignore payloads"
grep -q '^!\.gitkeep' "$OPS/artifacts/.gitignore" \
  || ac_fail "artifacts/.gitignore does not keep .gitkeep"
mkdir -p "$OPS/artifacts/act-1"
head -c 512 /dev/zero > "$OPS/artifacts/act-1/payload.bin"
git -C "$OPS" check-ignore -q artifacts/act-1/payload.bin \
  || ac_fail "payload under artifacts/ is not gitignored"
[ "$(git -C "$OPS" ls-files artifacts/ | sort)" = "$(printf 'artifacts/.gitignore\nartifacts/.gitkeep')" ] \
  || ac_fail "payload files were committed to artifacts/ (only .gitkeep + .gitignore expected)"

# ── 5. runs/README.md states records vs payloads ─────────────────────────────
[ -f "$OPS/runs/README.md" ] || ac_fail "runs/README.md was not seeded"
grep -q "Records belong in git" "$OPS/runs/README.md" \
  || ac_fail "runs/README.md does not state records belong in git"
grep -q "gitignored" "$OPS/runs/README.md" \
  || ac_fail "runs/README.md does not state payloads are gitignored"

# ── 6. run_ledger_append: valid row, then refuse the duplicate ───────────────
cat > "$TMP_DIR/record.json" <<'EOF'
{
  "id": "acc-run-1297",
  "action_id": "run-experiment-1",
  "git_tree": "abc123",
  "image": "disinto/agents:latest",
  "host": "nomad-box-1",
  "argv": ["run-experiment.sh"],
  "started": "2026-02-11T00:00:00Z",
  "ended": "2026-02-11T00:10:00Z",
  "exit": 0,
  "artifacts": ["run-experiment-1/results.csv"]
}
EOF
run_ledger_append "$OPS" "$TMP_DIR/record.json" >/dev/null \
  || ac_fail "run_ledger_append failed on the first append"
[ -f "$OPS/runs/acc-run-1297.json" ] \
  || ac_fail "runs/acc-run-1297.json was not written"
jq -e '.id == "acc-run-1297" and (.artifacts == ["run-experiment-1/results.csv"])' \
  "$OPS/runs/acc-run-1297.json" >/dev/null \
  || ac_fail "written record is not a valid row"

if run_ledger_append "$OPS" "$TMP_DIR/record.json" >/dev/null 2>&1; then
  ac_fail "second append with the same id was accepted (ledger must be append-only)"
fi

ac_pass
