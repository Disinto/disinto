#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1923.sh
#
# Issue #1923: an incident when a public endpoint fails on two ticks in a row.
#
# public_endpoints_section (extracted with ac_extract_fn) probes PUBLIC_URLS
# with a curl stub and keeps consecutive failing ticks in a temp
# SUPERVISOR_STATE_DIR. No network.
#
#   1. Stub answers 502: first run prints Public Endpoints: OK (1 failing
#      tick); second run prints Public Endpoints: DOWN.
#   2. Stub answers 200: third run prints OK, with failing ticks 0.
#   3. PUBLIC_URLS empty: prints only Public Endpoints: unconfigured.
#   4. evaluate-recipes.sh fires public-endpoint-down on the DOWN output and
#      not on the OK output.
#
# Run via: tools/run-acceptance.sh 1923
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq awk grep mktemp

PREFLIGHT="$REPO_ROOT/supervisor/preflight.sh"
RECIPES="$REPO_ROOT/supervisor/recipes.yaml"
EVALUATOR="$REPO_ROOT/supervisor/evaluate-recipes.sh"
AGENTS_MD="$REPO_ROOT/supervisor/AGENTS.md"

ac_assert_file "$PREFLIGHT" "supervisor/preflight.sh must exist"
ac_assert_file "$RECIPES" "supervisor/recipes.yaml must exist"
ac_assert_file "$EVALUATOR" "supervisor/evaluate-recipes.sh must exist"
ac_assert_file "$AGENTS_MD" "supervisor/AGENTS.md must exist"

FN="$(ac_extract_fn public_endpoints_section "$PREFLIGHT")"
[ -n "$FN" ] || ac_fail "could not extract public_endpoints_section() from preflight.sh"
grep -q '^public_endpoints_section$' "$PREFLIGHT" \
  || ac_fail "preflight.sh main block never calls public_endpoints_section"

# The phrase is literal markdown; backticks are not command substitutions.
# shellcheck disable=SC2016
grep -qF 'public endpoints (`PUBLIC_URLS`; DOWN after 2 failing ticks in a row)' "$AGENTS_MD" \
  || ac_fail "supervisor/AGENTS.md must mention public endpoints after blocked issues"
grep -qF 'P1 (disk, public endpoint down)' "$AGENTS_MD" \
  || ac_fail "supervisor/AGENTS.md alert priorities must list public endpoint down under P1"

FORMULA="$REPO_ROOT/formulas/run-supervisor.toml"
ac_assert_file "$FORMULA" "formulas/run-supervisor.toml must exist"
grep -qF '**Public Endpoints**' "$FORMULA" \
  || ac_fail "run-supervisor.toml preflight checklist must name Public Endpoints"
grep -qF '### P1 — Disk pressure / public endpoint down' "$FORMULA" \
  || ac_fail "run-supervisor.toml P1 heading must not be disk-only"
grep -qF 'Public Endpoints: DOWN' "$FORMULA" \
  || ac_fail "run-supervisor.toml must classify Public Endpoints: DOWN as P1"

URL="https://self.disinto.ai/"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"
STUB="$TMP/stub"
mkdir -p "$STATE" "$STUB"

write_stub() {
  local code="$1"
  cat > "$STUB/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' '${code}'
EOF
  chmod +x "$STUB/curl"
}

# Run the extracted function. PUBLIC_URLS is passed through; an empty second
# arg leaves it unset when mode=unset.
run_section() {
  local mode="$1" urls="$2"
  FN_SRC="$FN" SUPERVISOR_STATE_DIR="$STATE" PATH="$STUB:$PATH" \
    PE_MODE="$mode" PE_URLS="$urls" bash -c '
    set -euo pipefail
    eval "$FN_SRC"
    if [ "$PE_MODE" = "empty" ]; then
      PUBLIC_URLS=""
      export PUBLIC_URLS
    elif [ "$PE_MODE" = "unset" ]; then
      unset PUBLIC_URLS
    else
      PUBLIC_URLS="$PE_URLS"
      export PUBLIC_URLS
    fi
    public_endpoints_section
  '
}

# ── 1. 502: first tick OK, second tick DOWN ─────────────────────────────────
ac_log "AC 1: 502 then 502 — OK (1 failing tick), then DOWN"

write_stub 502
out1="$(run_section set "$URL")"
printf '%s\n' "$out1" | grep -qx "${URL}: 502 (failing ticks: 1)" \
  || ac_fail "first 502 run must record 1 failing tick, got: $out1"
printf '%s\n' "$out1" | grep -qx 'Public Endpoints: OK' \
  || ac_fail "first 502 run must print Public Endpoints: OK, got: $out1"
printf '%s\n' "$out1" | grep -qx '## Public Endpoints' \
  || ac_fail "configured run must print the Public Endpoints section, got: $out1"
ac_assert_eq "$(cat "$STATE/public-endpoints.state")" "1 ${URL}" \
  "state file must be '<count> <url>' after the first failure"

out2="$(run_section set "$URL")"
printf '%s\n' "$out2" | grep -qx "${URL}: 502 (failing ticks: 2)" \
  || ac_fail "second 502 run must record 2 failing ticks, got: $out2"
printf '%s\n' "$out2" | grep -qx 'Public Endpoints: DOWN' \
  || ac_fail "second 502 run must print Public Endpoints: DOWN, got: $out2"

# ── 2. 200 resets the streak ────────────────────────────────────────────────
ac_log "AC 2: 200 resets failing ticks to 0 and prints OK"

write_stub 200
out3="$(run_section set "$URL")"
printf '%s\n' "$out3" | grep -qx "${URL}: 200 (failing ticks: 0)" \
  || ac_fail "200 run must reset failing ticks to 0, got: $out3"
printf '%s\n' "$out3" | grep -qx 'Public Endpoints: OK' \
  || ac_fail "200 run must print Public Endpoints: OK, got: $out3"
if printf '%s\n' "$out3" | grep -qx 'Public Endpoints: DOWN'; then
  ac_fail "200 run must not print DOWN, got: $out3"
fi
ac_assert_eq "$(cat "$STATE/public-endpoints.state")" "0 ${URL}" \
  "state file must reset the count to 0 after an up tick"

# ── 3. empty PUBLIC_URLS ───────────────────────────────────────────────────
ac_log "AC 3: empty PUBLIC_URLS prints only Public Endpoints: unconfigured"

out_empty="$(run_section empty "")"
ac_assert_eq "$out_empty" "Public Endpoints: unconfigured" \
  "empty PUBLIC_URLS must print only Public Endpoints: unconfigured, got: $out_empty"

out_unset="$(run_section unset "")"
ac_assert_eq "$out_unset" "Public Endpoints: unconfigured" \
  "unset PUBLIC_URLS must print only Public Endpoints: unconfigured, got: $out_unset"

# ── 4. recipe fires on DOWN, not on OK ──────────────────────────────────────
ac_log "AC 4: evaluate-recipes fires public-endpoint-down only on DOWN"

recipe="$(awk '
  $0 ~ /^  - name: public-endpoint-down$/ { p = 1; print; next }
  p && /^  - name:/ { exit }
  p { print }
' "$RECIPES")"
[ -n "$recipe" ] || ac_fail "public-endpoint-down recipe is missing"
printf '%s\n' "$recipe" | grep -q 'severity: P1' \
  || ac_fail "public-endpoint-down must be P1, got: $recipe"
printf '%s\n' "$recipe" | grep -q 'section: "Public Endpoints"' \
  || ac_fail "public-endpoint-down must watch the Public Endpoints section, got: $recipe"
printf '%s\n' "$recipe" | grep -q 'rule: field_eq' \
  || ac_fail "public-endpoint-down must use field_eq, got: $recipe"
printf '%s\n' "$recipe" | grep -q 'field: "Public Endpoints"' \
  || ac_fail "public-endpoint-down field must be Public Endpoints, got: $recipe"
printf '%s\n' "$recipe" | grep -q 'value: "DOWN"' \
  || ac_fail "public-endpoint-down value must be DOWN, got: $recipe"
printf '%s\n' "$recipe" | grep -q 'action: incident' \
  || ac_fail "public-endpoint-down must be action: incident, got: $recipe"
if printf '%s\n' "$recipe" | grep -q 'action_script:'; then
  ac_fail "public-endpoint-down must not set action_script, got: $recipe"
fi

printf '%s\n' "$out2" > "$TMP/down.txt"
printf '%s\n' "$out1" > "$TMP/ok.txt"
err="$TMP/eval-err.txt"

fired_down="$(bash "$EVALUATOR" "$RECIPES" "$TMP/down.txt" 2>"$err")" \
  || ac_fail "evaluate-recipes.sh failed on DOWN output"
if [ -s "$err" ]; then
  ac_fail "evaluate-recipes.sh warned on DOWN output: $(head -n 1 "$err")"
fi
jq -e '.fired | map(.name) | index("public-endpoint-down") != null' <<<"$fired_down" >/dev/null \
  || ac_fail "DOWN output must fire public-endpoint-down, got: $fired_down"
jq -e '[.fired[] | select(.name == "public-endpoint-down") | .action] == ["incident"]' \
  <<<"$fired_down" >/dev/null \
  || ac_fail "public-endpoint-down must fire as an incident, got: $fired_down"

: > "$err"
fired_ok="$(bash "$EVALUATOR" "$RECIPES" "$TMP/ok.txt" 2>"$err")" \
  || ac_fail "evaluate-recipes.sh failed on OK output"
if [ -s "$err" ]; then
  ac_fail "evaluate-recipes.sh warned on OK output: $(head -n 1 "$err")"
fi
if jq -e '.fired | map(.name) | index("public-endpoint-down") != null' <<<"$fired_ok" >/dev/null; then
  ac_fail "OK output must not fire public-endpoint-down, got: $fired_ok"
fi

ac_pass
