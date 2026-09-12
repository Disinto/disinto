#!/usr/bin/env bash
# tests/acceptance/issue-1295.sh — v0.6 experiment issue template + research labels
#
# Acceptance for #1295 (read-only against the repo + the live label list):
#   1. .forgejo/ISSUE_TEMPLATE/experiment.yaml exists and is a Forgejo
#      template that auto-labels `experiment` (never `backlog`), with the
#      required fields image, argv/tool, host class, artifact glob, and a
#      resource-class dropdown (cpu/gpu/meep/voxel).
#   2. The feature / bug / refactor templates are unchanged (same auto-labels).
#   3. The research-label seed table (tools/seed-research-labels.sh --list)
#      defines exactly experiment / run / artifact / judgment /
#      waiting-on-compute with distinct, valid colours that do not collide
#      with the backlog colours.
#   4. Live forge (only when FORGE_URL + a token + a repo are in env): all
#      five labels exist, a second seed run is a no-op (idempotent — with all
#      five present the tool only GETs, it never POSTs an existing label),
#      and the research colours stay distinct from backlog / bug-report /
#      vision on the live forge.
#
# bash + jq + coreutils only (CI runs on alpine:3 with no python3).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

source "${SCRIPT_DIR}/../lib/acceptance-helpers.sh"

ac_require_cmd bash awk sed grep jq curl

TPL="$REPO_ROOT/.forgejo/ISSUE_TEMPLATE/experiment.yaml"
TPL_DIR="$REPO_ROOT/.forgejo/ISSUE_TEMPLATE"

# ── 1. Experiment template: exists, Forgejo keys, auto-labels experiment ──
ac_assert_file "$TPL" "experiment issue template not found"
grep -qE '^name:[[:space:]]*\S' "$TPL" || ac_fail "experiment.yaml: missing top-level 'name:'"
grep -qE '^about:[[:space:]]*\S' "$TPL" || ac_fail "experiment.yaml: missing top-level 'about:'"
grep -qE '^labels:' "$TPL" || ac_fail "experiment.yaml: missing top-level 'labels:'"

# The labels: block (runs until the next top-level key).
LABELS_BLOCK="$(awk '/^labels:/{f=1;next} f && /^[^[:space:]]/{f=0} f' "$TPL")"
printf '%s\n' "$LABELS_BLOCK" | grep -qE '^[[:space:]]*-[[:space:]]*experiment[[:space:]]*$' \
  || ac_fail "experiment.yaml does not auto-label 'experiment'"
if printf '%s\n' "$LABELS_BLOCK" | grep -qE '^[[:space:]]*-[[:space:]]*backlog[[:space:]]*$'; then
  ac_fail "experiment.yaml auto-labels 'backlog' — experiments are research tickets, not coding work"
fi

# ── 2. Required fields ────────────────────────────────────────────────────────
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
  || ac_fail "experiment.yaml: 'resource-class' must be a dropdown"
printf '%s\n' "$RC_BLOCK" | grep -qE '^[[:space:]]*required:[[:space:]]*true' \
  || ac_fail "experiment.yaml: field 'resource-class' is not required"
for opt in cpu gpu meep voxel; do
  printf '%s\n' "$RC_BLOCK" | grep -qE "^[[:space:]]*-[[:space:]]*${opt}[[:space:]]*$" \
    || ac_fail "experiment.yaml: resource-class option '${opt}' missing"
done
ac_log "experiment template: keys, auto-label, and 5 required fields verified"

# Bonus structural check when PyYAML is available (CI alpine image skips it —
# the grep checks above cover the same invariants without python3).
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
  python3 - "$TPL" <<'PY' || ac_fail "experiment.yaml: PyYAML structure check failed"
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
assert isinstance(doc, dict) and doc.get("name") and doc.get("about"), "name/about"
labels = doc.get("labels") or []
assert "experiment" in labels and "backlog" not in labels, "auto-labels"
req = {i.get("id") for i in doc.get("body", [])
       if isinstance(i, dict) and (i.get("validations") or {}).get("required")}
need = {"image", "argv", "host-class", "artifact-glob", "resource-class"}
assert need <= req, f"missing required: {need - req}"
rc = [i for i in doc.get("body", [])
      if isinstance(i, dict) and i.get("id") == "resource-class"]
assert rc and {"cpu", "gpu", "meep", "voxel"} <= set(rc[0].get("attributes", {}).get("options", [])), "options"
PY
  ac_log "PyYAML structure check passed"
else
  ac_log "python3/PyYAML unavailable — structural grep checks only"
fi

# ── 3. feature / bug / refactor templates unchanged ──────────────────────────
# tpl_labels FILE — the label names in a template's top-level labels: block.
tpl_labels() {
  awk '/^labels:/{f=1;next} f && /^[^[:space:]]/{f=0} f' "$1" \
    | sed -n 's/^[[:space:]]*-[[:space:]]*//p'
}

BUG_TPL="$TPL_DIR/bug.yaml"
[ -f "$BUG_TPL" ] || ac_fail "bug.yaml missing — template set must not change"
printf '%s\n' "$(tpl_labels "$BUG_TPL")" | grep -qx 'bug-report' \
  || ac_fail "bug.yaml auto-label changed from 'bug-report'"
for t in feature.yaml refactor.yaml; do
  f="$TPL_DIR/$t"
  [ -f "$f" ] || ac_fail "$t missing — template set must not change"
  printf '%s\n' "$(tpl_labels "$f")" | grep -qx 'backlog' \
    || ac_fail "$t auto-label changed from 'backlog'"
done
ac_log "bug/feature/refactor templates unchanged"

# ── 4. Research-label seed table ─────────────────────────────────────────────
SEED_TOOL="$REPO_ROOT/tools/seed-research-labels.sh"
ac_assert_file "$SEED_TOOL" "tools/seed-research-labels.sh not found"
[ -x "$SEED_TOOL" ] || ac_fail "tools/seed-research-labels.sh is not executable"
TABLE="$(bash "$SEED_TOOL" --list)"
ac_assert_eq "$(printf '%s\n' "$TABLE" | wc -l | tr -d '[:space:]')" "5" \
  "seed table must define exactly 5 research labels"
for lbl in experiment run artifact judgment waiting-on-compute; do
  printf '%s\n' "$TABLE" | grep -qE "^${lbl} #[0-9a-fA-F]{6}$" \
    || ac_fail "seed table: label '${lbl}' missing or malformed (want '<name> #rrggbb')"
done
ac_assert_eq "$(printf '%s\n' "$TABLE" | awk '{print $2}' | sort -u | wc -l | tr -d '[:space:]')" "5" \
  "research label colours must be distinct"
for c in "#0075ca" "#fef2c0"; do
  if printf '%s\n' "$TABLE" | awk '{print $2}' | grep -qix "$c"; then
    ac_fail "seed colour ${c} collides with the backlog label colour"
  fi
done
ac_log "seed table: 5 labels, distinct colours, no backlog collision"

# ── 5. Live forge (conditional — read-only: GET only) ────────────────────────
LIVE_TOKEN="${FACTORY_FORGE_PAT:-${FORGE_TOKEN:-}}"
LIVE_API="${FORGE_API:-}"
if [ -n "${FORGE_URL:-}" ] && [ -n "$LIVE_TOKEN" ] && { [ -n "$LIVE_API" ] || [ -n "${FORGE_REPO:-}" ]; }; then
  [ -n "$LIVE_API" ] || LIVE_API="${FORGE_URL%/}/api/v1/repos/${FORGE_REPO}"
  LIVE_LABELS="$(curl -sf --max-time 15 -H "Authorization: token ${LIVE_TOKEN}" "${LIVE_API}/labels")" \
    || ac_fail "cannot fetch live label list from ${LIVE_API}/labels (check FORGE_REPO/FORGE_TOKEN)"

  for lbl in experiment run artifact judgment waiting-on-compute; do
    printf '%s' "$LIVE_LABELS" | jq -r --arg n "$lbl" '.[] | select(.name == $n) | .name' 2>/dev/null \
      | grep -qx "$lbl" \
      || ac_fail "label '${lbl}' missing on live forge — run tools/seed-research-labels.sh"
  done
  ac_log "live: all five research labels present"

  # Idempotency: with all five labels present, a second seed run only GETs —
  # the tool only POSTs labels it cannot find — so it must succeed as a no-op.
  # (USER/HOME fallbacks: env.sh requires them; CI containers may not set them.)
  SEED_OUT="$(USER="${USER:-root}" HOME="${HOME:-/tmp}" bash "$SEED_TOOL" 2>&1)" \
    || ac_fail "second run of tools/seed-research-labels.sh failed (must be idempotent)"
  for lbl in experiment run artifact judgment waiting-on-compute; do
    printf '%s\n' "$SEED_OUT" | grep -q "label '${lbl}': already exists" \
      || ac_fail "seed run did not report '${lbl}' as pre-existing (output: ${SEED_OUT})"
  done
  ac_log "live: second seed run is a no-op (idempotent)"

  # Research colours must stay distinct from backlog / bug-report / vision.
  RESEARCH_COLORS="$(printf '%s' "$LIVE_LABELS" | jq -r '
    .[] | select(.name == "experiment" or .name == "run" or .name == "artifact"
                 or .name == "judgment" or .name == "waiting-on-compute") | .color' | sort -u)"
  for other in backlog bug-report vision; do
    OTHER_COLOR="$(printf '%s' "$LIVE_LABELS" | jq -r --arg n "$other" '
      [ .[] | select(.name == $n) | .color ]
      | map(select(. != null)) | .[0] // empty')"
    [ -n "$OTHER_COLOR" ] || continue
    if printf '%s\n' "$RESEARCH_COLORS" | grep -qx "$OTHER_COLOR"; then
      ac_fail "research label colour ${OTHER_COLOR} collides with live '${other}' label"
    fi
  done
  ac_log "live: research colours distinct from backlog / bug-report / vision"
else
  ac_log "no live forge env (FORGE_URL + FACTORY_FORGE_PAT/FORGE_TOKEN + FORGE_REPO) — live checks skipped"
fi

ac_pass "experiment template auto-labels 'experiment' (5 required fields incl. resource-class dropdown); feature/bug/refactor templates unchanged; 5 distinct research labels seeded (idempotent)"
