#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1927.sh
#
# Issue #1927: an incident when the snapshot reports an unregistered Nomad
# service.
#
# nomad_services_section (extracted with ac_extract_fn) reads fixture state
# files. No Nomad, no network.
#
#   1. A fresh state file with "service forgejo of job forgejo not registered"
#      prints Nomad Services: MISSING and names the service.
#      evaluate-recipes.sh fires nomad-service-unregistered.
#   2. A fresh state file with only "job x dead" prints OK, and the recipe
#      does not fire.
#   3. A missing file, or a ts older than 15 minutes, prints unknown, and
#      the recipe does not fire.
#
# Run via: tools/run-acceptance.sh 1927
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq awk grep mktemp date

PREFLIGHT="$REPO_ROOT/supervisor/preflight.sh"
RECIPES="$REPO_ROOT/supervisor/recipes.yaml"
EVALUATOR="$REPO_ROOT/supervisor/evaluate-recipes.sh"
AGENTS_MD="$REPO_ROOT/supervisor/AGENTS.md"
# One loop rather than the four ac_assert_file lines issue-1923.sh uses.
# duplicate-detection hashes 5-line windows, and those lines matched.
for _pair in \
  "$PREFLIGHT|supervisor/preflight.sh must exist" \
  "$RECIPES|supervisor/recipes.yaml must exist" \
  "$EVALUATOR|supervisor/evaluate-recipes.sh must exist" \
  "$AGENTS_MD|supervisor/AGENTS.md must exist"
do
  ac_assert_file "${_pair%%|*}" "${_pair#*|}"
done

FN="$(ac_extract_fn nomad_services_section "$PREFLIGHT")"
[ -n "$FN" ] || ac_fail "could not extract nomad_services_section() from preflight.sh"
grep -q '^nomad_services_section$' "$PREFLIGHT" \
  || ac_fail "preflight.sh main block never calls nomad_services_section"
awk '
  $0 == "public_endpoints_section" { pe = NR }
  $0 == "nomad_services_section" { ns = NR }
  END { if (!pe || !ns || ns < pe) exit 1 }
' "$PREFLIGHT" \
  || ac_fail "nomad_services_section must be called after public_endpoints_section"
grep -qF '/var/lib/disinto/snapshot/state.json' "$PREFLIGHT" \
  || ac_fail "preflight.sh must default SNAPSHOT_PATH to /var/lib/disinto/snapshot/state.json"

# The phrase is the #1927 documentation addition, after the #1923 public-endpoints text.
# shellcheck disable=SC2016
grep -qF 'public endpoints (`PUBLIC_URLS`; DOWN after 2 failing ticks in a row), unregistered Nomad services (from the snapshot state)' "$AGENTS_MD" \
  || ac_fail "supervisor/AGENTS.md preflight entry must mention unregistered Nomad services after public endpoints"
grep -qF 'P1 (disk, public endpoint down), P1 (unregistered Nomad service)' "$AGENTS_MD" \
  || ac_fail "supervisor/AGENTS.md alert priorities must list unregistered Nomad service under P1"
grep -qF 'P1 unregistered Nomad service' "$AGENTS_MD" \
  || ac_fail "supervisor/AGENTS.md formula entry must classify unregistered Nomad service as P1"

FORMULA="$REPO_ROOT/formulas/run-supervisor.toml"
ac_assert_file "$FORMULA" "formulas/run-supervisor.toml must exist"
grep -qF '**Public Endpoints**, **Nomad Services**' "$FORMULA" \
  || ac_fail "run-supervisor.toml preflight checklist must name Nomad Services"
grep -qF 'Nomad Services: MISSING' "$FORMULA" \
  || ac_fail "run-supervisor.toml must classify Nomad Services: MISSING as P1"
grep -qF 'nomad-service-unregistered' "$FORMULA" \
  || ac_fail "run-supervisor.toml decide-actions must name nomad-service-unregistered as monitor-only"
grep -qF 'Do not restart the allocation; that stays with the operator.' "$FORMULA" \
  || ac_fail "run-supervisor.toml must keep alloc restart with the operator"
grep -qF 'P1 disk / public endpoint / unregistered Nomad service' \
  "$REPO_ROOT/supervisor/supervisor-run.sh" \
  || ac_fail "supervisor-run.sh priority order must name the unregistered Nomad service"

recipe="$(awk '
  $0 ~ /^  - name: nomad-service-unregistered$/ { p = 1; print; next }
  p && /^  - name:/ { exit }
  p { print }
' "$RECIPES")"
[ -n "$recipe" ] || ac_fail "nomad-service-unregistered recipe is missing"
printf '%s\n' "$recipe" | grep -q 'severity: P1' \
  || ac_fail "nomad-service-unregistered must be P1, got: $recipe"
printf '%s\n' "$recipe" | grep -q 'section: "Nomad Services"' \
  || ac_fail "nomad-service-unregistered must watch the Nomad Services section, got: $recipe"
printf '%s\n' "$recipe" | grep -q 'rule: field_eq' \
  || ac_fail "nomad-service-unregistered must use field_eq, got: $recipe"
printf '%s\n' "$recipe" | grep -q 'field: "Nomad Services"' \
  || ac_fail "nomad-service-unregistered field must be Nomad Services, got: $recipe"
printf '%s\n' "$recipe" | grep -q 'value: "MISSING"' \
  || ac_fail "nomad-service-unregistered value must be MISSING, got: $recipe"
printf '%s\n' "$recipe" | grep -q 'action: incident' \
  || ac_fail "nomad-service-unregistered must be action: incident, got: $recipe"
if printf '%s\n' "$recipe" | grep -q 'action_script:'; then
  ac_fail "nomad-service-unregistered must not set action_script, got: $recipe"
fi

# The new recipe sits next to public-endpoint-down.
awk '
  $0 ~ /^  - name: public-endpoint-down$/ { pe = NR; next }
  $0 ~ /^  - name: nomad-service-unregistered$/ { ns = NR; next }
  pe && !ns && /^  - name:/ { other = 1 }
  END { if (!pe || !ns || ns < pe || other) exit 1 }
' "$RECIPES" \
  || ac_fail "nomad-service-unregistered must be the recipe immediately after public-endpoint-down"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fresh_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
stale_ts() { date -u -d '16 minutes ago' '+%Y-%m-%dT%H:%M:%SZ'; }

write_state() {
  local dest="$1" ts="$2" alerts_json="$3"
  jq -n --arg ts "$ts" --argjson alerts "$alerts_json" \
    '{collectors: {nomad: {ts: $ts, jobs: [], alerts: $alerts}}}' > "$dest"
}

run_section() {
  local snap="$1"
  FN_SRC="$FN" SNAPSHOT_PATH="$snap" bash -c '
    set -euo pipefail
    eval "$FN_SRC"
    nomad_services_section
  '
}

# Feed preflight text to the evaluator. Fails the test on a non-zero exit or
# any stderr (unknown rules, parse errors).
eval_recipes() {
  local preflight_text="$1" err out
  err="$TMP/eval-err.txt"
  printf '%s\n' "$preflight_text" > "$TMP/preflight.txt"
  : > "$err"
  out="$(bash "$EVALUATOR" "$RECIPES" "$TMP/preflight.txt" 2>"$err")" \
    || ac_fail "evaluate-recipes.sh failed: $(head -n 1 "$err")"
  if [ -s "$err" ]; then
    ac_fail "evaluate-recipes.sh warned: $(head -n 1 "$err")"
  fi
  printf '%s\n' "$out"
}

recipe_fired() {
  jq -e '.fired | map(.name) | index("nomad-service-unregistered") != null' >/dev/null
}

# ── 1. fresh unregistered service ───────────────────────────────────────────
ac_log "AC 1: fresh unregistered-service alert prints MISSING and fires"

write_state "$TMP/missing.json" "$(fresh_ts)" \
  '["service forgejo of job forgejo not registered"]'
out_missing="$(run_section "$TMP/missing.json")"
printf '%s\n' "$out_missing" | grep -qx '## Nomad Services' \
  || ac_fail "fresh alert run must print the Nomad Services section, got: $out_missing"
printf '%s\n' "$out_missing" | grep -qx 'service forgejo of job forgejo not registered' \
  || ac_fail "fresh alert run must name the service, got: $out_missing"
printf '%s\n' "$out_missing" | grep -qx 'Nomad Services: MISSING' \
  || ac_fail "fresh alert run must print Nomad Services: MISSING, got: $out_missing"

fired_missing="$(eval_recipes "$out_missing")"
recipe_fired <<<"$fired_missing" \
  || ac_fail "MISSING output must fire nomad-service-unregistered, got: $fired_missing"
jq -e '[.fired[] | select(.name == "nomad-service-unregistered") | .action] == ["incident"]' \
  <<<"$fired_missing" >/dev/null \
  || ac_fail "nomad-service-unregistered must fire as an incident, got: $fired_missing"

# ── 2. fresh, unrelated alerts only ─────────────────────────────────────────
ac_log "AC 2: fresh job-dead alert prints OK and does not fire"

write_state "$TMP/dead.json" "$(fresh_ts)" '["job x dead"]'
out_ok="$(run_section "$TMP/dead.json")"
printf '%s\n' "$out_ok" | grep -qx 'Nomad Services: OK' \
  || ac_fail "job-dead run must print Nomad Services: OK, got: $out_ok"
if printf '%s\n' "$out_ok" | grep -qx 'Nomad Services: MISSING'; then
  ac_fail "job-dead run must not print MISSING, got: $out_ok"
fi
if printf '%s\n' "$out_ok" | grep -q 'job x dead'; then
  ac_fail "job-dead run must not print unrelated alerts, got: $out_ok"
fi

fired_ok="$(eval_recipes "$out_ok")"
if recipe_fired <<<"$fired_ok"; then
  ac_fail "OK output must not fire nomad-service-unregistered, got: $fired_ok"
fi

# ── 3. missing file, or ts older than 15 minutes ────────────────────────────
ac_log "AC 3: missing file and stale ts print unknown and do not fire"

out_absent="$(run_section "$TMP/no-such-state.json")"
ac_assert_eq "$out_absent" "$(printf '%s\n' '## Nomad Services' 'Nomad Services: unknown')" \
  "missing file must print Nomad Services: unknown, got: $out_absent"
fired_absent="$(eval_recipes "$out_absent")"
if recipe_fired <<<"$fired_absent"; then
  ac_fail "unknown (missing file) must not fire nomad-service-unregistered, got: $fired_absent"
fi

write_state "$TMP/stale.json" "$(stale_ts)" \
  '["service forgejo of job forgejo not registered"]'
out_stale="$(run_section "$TMP/stale.json")"
ac_assert_eq "$out_stale" "$(printf '%s\n' '## Nomad Services' 'Nomad Services: unknown')" \
  "ts older than 15 minutes must print Nomad Services: unknown, got: $out_stale"
fired_stale="$(eval_recipes "$out_stale")"
if recipe_fired <<<"$fired_stale"; then
  ac_fail "unknown (stale ts) must not fire nomad-service-unregistered, got: $fired_stale"
fi

# Missing .collectors.nomad.ts is the same unknown, even with a matching alert
# sitting next to a top-level ts the collector says not to trust.
jq -n --arg ts "$(fresh_ts)" \
  '{ts: $ts, collectors: {nomad: {alerts: ["service forgejo of job forgejo not registered"]}}}' \
  > "$TMP/no-collector-ts.json"
out_nots="$(run_section "$TMP/no-collector-ts.json")"
ac_assert_eq "$out_nots" "$(printf '%s\n' '## Nomad Services' 'Nomad Services: unknown')" \
  "missing .collectors.nomad.ts must print Nomad Services: unknown, got: $out_nots"

ac_pass
