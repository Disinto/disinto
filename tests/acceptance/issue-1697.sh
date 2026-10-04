#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1697.sh
#
# Issue #1697: direct fixes find the factory root, and three dead recipes go.
#
#   1. supervisor/actions/_common.sh, with FACTORY_ROOT unset, walks two levels
#      up from actions/ (not one — that is supervisor/) and sources lib/env.sh.
#   2. repair_direct_dispatch logs the last stderr line when a direct script
#      exits non-zero, and the tick still returns 0.
#   3. recipes.yaml drops ci-exhausted-sweep, close-stuck-pr and
#      memory-crisis-high-swap; memory-crisis-low-ram is an incident with no
#      action_script.
#   4. The three scripts are gone, and supervisor/ no longer names them.
#
# Hermetic: no network. The dispatch is extracted with ac_extract_fn and run
# against stubbed log, tape_run and repair_tape_state_file.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd jq
ac_require_cmd grep

TARGET="$REPO_ROOT/supervisor/supervisor-run.sh"
COMMON="$REPO_ROOT/supervisor/actions/_common.sh"
RECIPES="$REPO_ROOT/supervisor/recipes.yaml"
ac_assert_file "$TARGET" "supervisor/supervisor-run.sh must exist"
ac_assert_file "$COMMON" "supervisor/actions/_common.sh must exist"
ac_assert_file "$RECIPES" "supervisor/recipes.yaml must exist"

# ── 1. FACTORY_ROOT unset: _common.sh finds the tree root and sources env.sh ─
ac_log "AC 1: _common.sh walks up to the factory root when FACTORY_ROOT is unset"

TREE="$(mktemp -d)"
trap 'rm -rf "$TREE"' EXIT
mkdir -p "$TREE/lib" "$TREE/supervisor/actions"
cp "$COMMON" "$TREE/supervisor/actions/_common.sh"
cat > "$TREE/lib/env.sh" <<'EOF'
#!/usr/bin/env bash
printf 'ENV_OK\n'
EOF
cat > "$TREE/supervisor/actions/probe.sh" <<'EOF'
#!/usr/bin/env bash
unset FACTORY_ROOT
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_common.sh"
printf '%s\n' "$FACTORY_ROOT"
EOF

TREE_ROOT="$(cd "$TREE" && pwd)"
probe_out="$(env -u FACTORY_ROOT bash "$TREE/supervisor/actions/probe.sh")"
printf '%s\n' "$probe_out" | grep -qx 'ENV_OK' \
  || ac_fail "sourcing _common.sh must print ENV_OK from lib/env.sh, got: $probe_out"
ac_assert_eq "$(printf '%s\n' "$probe_out" | tail -n 1)" "$TREE_ROOT" \
  "FACTORY_ROOT must be the temp tree root, got: $probe_out"

# ── 2. a failing direct script logs rc and the last stderr line ──────────────
ac_log "AC 2: repair_direct_dispatch logs failed, rc=3: boom"

DISPATCH_SRC="$(ac_extract_fn repair_direct_dispatch "$TARGET")"
[ -n "$DISPATCH_SRC" ] || ac_fail "could not extract repair_direct_dispatch() from supervisor-run.sh"

mkdir -p "$TREE/factory/supervisor/actions"
cat > "$TREE/factory/supervisor/actions/boom.sh" <<'EOF'
#!/usr/bin/env bash
echo boom >&2
exit 3
EOF
FACTORY_ROOT="$TREE/factory"
export FACTORY_ROOT
export PROJECT_TOML="$FACTORY_ROOT/projects/disinto.toml"

# Stubs the issue names, plus emit_repair_proposal: with no state file the
# extracted function still calls it before running the script.
log() { printf '%s\n' "$*"; }
tape_run() { return 0; }
repair_tape_state_file() { printf '%s\n' "$TREE/no-such-state.json"; }
emit_repair_proposal() { return 0; }

RECIPE="$(jq -cn \
  --arg n boom-recipe \
  --arg s supervisor/actions/boom.sh \
  --arg e 'stderr boom' \
  '{"fired":[{"name":$n,"action":"direct","action_script":$s,"evidence":$e}]}')"

rc=0
dispatch_out="$(
  set -euo pipefail
  eval "$DISPATCH_SRC"
  repair_direct_dispatch "$RECIPE"
)" || rc=$?
ac_assert_eq "$rc" "0" "a failing direct script must not interrupt the tick (got $rc): $dispatch_out"
case "$dispatch_out" in
  *"failed, rc=3: boom"*) ;;
  *) ac_fail "expected a log line containing 'failed, rc=3: boom', got: $dispatch_out" ;;
esac

# ── 3. dead recipes are gone; low-ram is an incident with no script ──────────
ac_log "AC 3: recipes.yaml drops the three dead recipes"

for dead in ci-exhausted-sweep close-stuck-pr memory-crisis-high-swap; do
  if grep -q "$dead" "$RECIPES"; then
    ac_fail "recipes.yaml must not name $dead"
  fi
done

low_ram="$(awk '
  $0 ~ /^  - name: memory-crisis-low-ram$/ { p = 1; print; next }
  p && /^  - name:/ { exit }
  p { print }
' "$RECIPES")"
[ -n "$low_ram" ] || ac_fail "memory-crisis-low-ram recipe is missing"
printf '%s\n' "$low_ram" | grep -q 'action: incident' \
  || ac_fail "memory-crisis-low-ram must have action: incident, got: $low_ram"
if printf '%s\n' "$low_ram" | grep -q 'action_script'; then
  ac_fail "memory-crisis-low-ram must not have an action_script, got: $low_ram"
fi

# ── 4. the three scripts are gone and supervisor/ does not name them ─────────
ac_log "AC 4: deleted scripts leave no reference under supervisor/"

for gone in sweep-ci-exhausted.sh close-stuck-pr.sh memory-crisis.sh; do
  if [ -e "$REPO_ROOT/supervisor/actions/$gone" ]; then
    ac_fail "supervisor/actions/$gone must be deleted"
  fi
done

hits="$(grep -rn 'sweep-ci-exhausted\|close-stuck-pr\|memory-crisis.sh' "$REPO_ROOT/supervisor" || true)"
[ -z "$hits" ] || ac_fail "supervisor/ still names a deleted script: $hits"

ac_pass
