#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1337.sh — file-subissues and experiment template use
# action/backlog only
#
# Issue #1337 (oak tick-learner sprint, supersedes experiment-as-lane from
# #1295): the repo has no `experiment` label; the oak lanes are `backlog`
# (inside) and `action` (outside). So:
#   - formulas/file-subissues.toml drops the PROJECT_KIND=research branch:
#     filed sub-issues are labelled `backlog` only, and the formula carries
#     no `experiment`-as-lane wording
#   - .forgejo/ISSUE_TEMPLATE/experiment.yaml auto-labels `action` (not
#     `experiment`, not `backlog`), teaches that this is outside work the
#     dev-bot must not claim, and no longer parks tickets on
#     `waiting-on-compute` as ritual — the image/argv/host-class/
#     artifact-glob/resource-class fields stay as the vault-run paper trail
#
# Verifies (all checks read-only — no forge, no nomad, no repo mutation):
#   1. formulas/file-subissues.toml exists, contains no `PROJECT_KIND`
#      string, contains no `experiment` string, and still pins filed
#      sub-issues to `LABEL_NAME="backlog"`.
#   2. formulas/file-subissues.toml still parses as valid TOML (when
#      python3 is available on the box).
#   3. .forgejo/ISSUE_TEMPLATE/experiment.yaml: the labels block contains
#      `action`, and neither `experiment` nor `backlog`.
#   4. experiment.yaml contains no `waiting-on-compute` string anywhere,
#      and its markdown hint tells the dev-bot it must not claim `action`.
#   5. The vault-run paper-trail fields (image, argv, host-class,
#      artifact-glob) are still present and required; resource-class is
#      still a required dropdown with cpu/gpu/meep/voxel options.
#
# Run via: tools/run-acceptance.sh 1337
#
# Last stdout line is PASS or FAIL: <reason>.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/acceptance-helpers.sh"

ac_require_cmd bash grep awk sed

FORMULA="$REPO_ROOT/formulas/file-subissues.toml"
TPL="$REPO_ROOT/.forgejo/ISSUE_TEMPLATE/experiment.yaml"

ac_assert_file "$FORMULA" "formulas/file-subissues.toml is missing"
ac_assert_file "$TPL" ".forgejo/ISSUE_TEMPLATE/experiment.yaml is missing"

# ── 1. file-subissues.toml: no experiment-as-lane, backlog only ────────────
ac_log "checking file-subissues.toml has no PROJECT_KIND or experiment string"
grep -q "PROJECT_KIND" "$FORMULA" \
  && ac_fail "formulas/file-subissues.toml still references PROJECT_KIND"
grep -qi "experiment" "$FORMULA" \
  && ac_fail "formulas/file-subissues.toml still references experiment-as-lane"
# shellcheck disable=SC2016
grep -qF 'LABEL_NAME="backlog"' "$FORMULA" \
  || ac_fail "formulas/file-subissues.toml no longer pins filed sub-issues to the backlog label"
ac_log "file-subissues.toml: backlog-only, no experiment-as-lane"

# ── 2. file-subissues.toml still parses as TOML (python3 when present) ─────
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import tomllib,sys; tomllib.load(open(sys.argv[1],'rb'))" "$FORMULA" 2>/dev/null \
    || ac_fail "formulas/file-subissues.toml is not valid TOML"
  ac_log "file-subissues.toml: valid TOML"
else
  ac_log "python3 unavailable — TOML parse check skipped"
fi

# ── 3. experiment.yaml: labels block is `action` only ───────────────────────
ac_log "checking experiment.yaml auto-labels action"
grep -qE '^labels:' "$TPL" \
  || ac_fail "experiment.yaml: missing top-level 'labels:'"
LABELS_BLOCK="$(awk '/^labels:/{f=1;next} f && /^[^[:space:]]/{f=0} f' "$TPL")"
printf '%s\n' "$LABELS_BLOCK" | grep -qE '^[[:space:]]*-[[:space:]]*action[[:space:]]*$' \
  || ac_fail "experiment.yaml does not auto-label 'action'"
printf '%s\n' "$LABELS_BLOCK" | grep -qE '^[[:space:]]*-[[:space:]]*experiment[[:space:]]*$' \
  && ac_fail "experiment.yaml still auto-labels 'experiment'"
printf '%s\n' "$LABELS_BLOCK" | grep -qE '^[[:space:]]*-[[:space:]]*backlog[[:space:]]*$' \
  && ac_fail "experiment.yaml auto-labels 'backlog' — it is outside work, not a coding ticket"

# ── 4. No waiting-on-compute ritual; the hint says dev-bot must not claim ──
ac_log "checking experiment.yaml has no waiting-on-compute ritual"
grep -q "waiting-on-compute" "$TPL" \
  && ac_fail "experiment.yaml still mentions waiting-on-compute"
grep -q "dev-bot" "$TPL" \
  || ac_fail "experiment.yaml markdown hint no longer names the dev-bot"
grep -q "must not claim" "$TPL" \
  || ac_fail "experiment.yaml markdown hint no longer says dev-bot must not claim"

# ── 5. Vault-run paper-trail fields unchanged ───────────────────────────────
# field_block ID — print the body-item block starting at `id: ID` (the item
# ends at the next `- type:` line, or EOF for the last item).
field_block() {
  sed -n "/^[[:space:]]*id:[[:space:]]*$1[[:space:]]*$/,/^[[:space:]]*- type:/p" "$TPL"
}

for id in image argv host-class artifact-glob; do
  blk="$(field_block "$id")"
  [ -n "$blk" ] || ac_fail "experiment.yaml: field '${id}' not found"
  printf '%s\n' "$blk" | grep -qE '^[[:space:]]*validations:' \
    || ac_fail "experiment.yaml: field '${id}' has no validations block"
  printf '%s\n' "$blk" | grep -qE '^[[:space:]]*required:[[:space:]]*true' \
    || ac_fail "experiment.yaml: field '${id}' is not required"
done

RC_BLOCK="$(field_block resource-class)"
[ -n "$RC_BLOCK" ] || ac_fail "experiment.yaml: field 'resource-class' not found"
grep -B1 -E '^[[:space:]]*id:[[:space:]]*resource-class[[:space:]]*$' "$TPL" \
  | grep -qE '^[[:space:]]*-?[[:space:]]*type:[[:space:]]*(dropdown|select)[[:space:]]*$' \
  || ac_fail "experiment.yaml: 'resource-class' is no longer a dropdown"
printf '%s\n' "$RC_BLOCK" | grep -qE '^[[:space:]]*required:[[:space:]]*true' \
  || ac_fail "experiment.yaml: field 'resource-class' is not required"
for opt in cpu gpu meep voxel; do
  printf '%s\n' "$RC_BLOCK" | grep -qE "^[[:space:]]*-[[:space:]]*${opt}[[:space:]]*$" \
    || ac_fail "experiment.yaml: resource-class option '${opt}' missing"
done
ac_log "paper-trail fields intact (image/argv/host-class/artifact-glob/resource-class)"

ac_pass
