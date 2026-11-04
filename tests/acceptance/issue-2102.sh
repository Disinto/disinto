#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2102.sh
#
# Issue #2102: the server that used to host disinto.ai (159.89.14.107) is gone;
# the site has been served from self.disinto.ai since 2026-11-03 (#2071). Four
# places still named its checkout path, /home/debian/dark-factory:
#   formulas/run-publish-site.toml  — [vars.repo_root] default, which the
#     pull-latest step cds into, and Check 2's FACTORY_ROOT default
#   site/collect-metrics.sh         — the "# Cron:" header line
#   site/collect-engagement.sh      — the "# Cron:" header line
#
# The formula runs in the vault runner, whose factory checkout is FACTORY_ROOT,
# default /home/agent/disinto (docker/runner/entrypoint-runner.sh). The
# repo_root default must match it. No cron runs either collector today, on any
# host, so both header lines become a "# Schedule: none." block.
#
# Hermetic: pure file inspection plus one nested stub run. No forge, no live
# box. Run via: tools/run-acceptance.sh 2102
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep sed awk

FORMULA="$REPO_ROOT/formulas/run-publish-site.toml"
RUNNER="$REPO_ROOT/docker/runner/entrypoint-runner.sh"
METRICS="$REPO_ROOT/site/collect-metrics.sh"
ENGAGEMENT="$REPO_ROOT/site/collect-engagement.sh"
TEST_1776="$REPO_ROOT/tests/acceptance/issue-1776.sh"

for f in "$FORMULA" "$RUNNER" "$METRICS" "$ENGAGEMENT" "$TEST_1776"; do
  ac_assert_file "$f" "required file is missing: ${f#"$REPO_ROOT"/}"
done

OLD_PATH='/home/debian'

# ── AC1: the dead server's checkout path is gone ─────────────────────────────
ac_log 'AC1: no /home/debian left in the publish formula or site/'
_hits="$(grep -rn "$OLD_PATH" "$FORMULA" "$REPO_ROOT/site/" || true)"
ac_assert_eq "$_hits" "" "AC1: /home/debian must not appear in formulas/run-publish-site.toml or site/ (#2102); got: $_hits"

# ── AC2: repo_root default == runner FACTORY_ROOT default ─────────────────────
ac_log 'AC2: [vars.repo_root] default matches docker/runner/entrypoint-runner.sh FACTORY_ROOT default'
_repo_default="$(awk '
  /^\[vars\.repo_root\]$/ { inblk = 1; next }
  inblk && /^\[/ { exit }
  inblk && /^default[[:space:]]*=/ { gsub(/"/, "", $3); print $3 }
' "$FORMULA")"
[ -n "$_repo_default" ] \
  || ac_fail "AC2: formulas/run-publish-site.toml must still define a [vars.repo_root] default"

_runner_default="$(grep -oE 'FACTORY_ROOT:-[^}]*' "$RUNNER" | head -n 1 | sed 's/^FACTORY_ROOT:-//')"
[ -n "$_runner_default" ] \
  || ac_fail "AC2: docker/runner/entrypoint-runner.sh must define a FACTORY_ROOT default"

ac_assert_eq "$_repo_default" "$_runner_default" \
  "AC2: repo_root default must equal the runner's FACTORY_ROOT default (got repo_root=$_repo_default, FACTORY_ROOT=$_runner_default)"

# The description must say where that path comes from.
grep -qF "the vault runner's FACTORY_ROOT, docker/runner/entrypoint-runner.sh" "$FORMULA" \
  || ac_fail "AC2: [vars.repo_root] must describe the runner's FACTORY_ROOT as the source of the path"

# Check 2 inside verify-observable must use the same default.
_check2_default="$(grep -oE 'FACTORY_ROOT:-[^}]*' "$FORMULA" | head -n 1 | sed 's/^FACTORY_ROOT:-//')"
[ -n "$_check2_default" ] \
  || ac_fail "AC2: the formula's Check 2 must keep a FACTORY_ROOT default"
ac_assert_eq "$_check2_default" "$_runner_default" \
  "AC2: Check 2's FACTORY_ROOT default must match the runner's (got $_check2_default)"

# ── AC3: both collectors dropped the Cron line for a Schedule: none block ─────
ac_log 'AC3: neither collector has a "# Cron:" line; each documents "# Schedule: none."'
for _script in "$METRICS" "$ENGAGEMENT"; do
  _name="${_script##*/}"
  if grep -qE '^#.*Cron:' "$_script"; then
    ac_fail "AC3: site/${_name} must not carry a # Cron: line (#2102): $(grep -nE '^#.*Cron:' "$_script")"
  fi
  grep -qF '# Schedule: none.' "$_script" \
    || ac_fail "AC3: site/${_name} must document '# Schedule: none.' instead of a cron line"
  grep -qF "bash site/${_name}" "$_script" \
    || ac_fail "AC3: site/${_name} must show how to run it from a disinto checkout (bash site/${_name})"
done

# ── AC4: syntax survives the edits ────────────────────────────────────────────
ac_log 'AC4: bash -n on both collectors; tomllib parses the formula'
bash -n "$METRICS" || ac_fail "AC4: site/collect-metrics.sh must parse with bash -n"
bash -n "$ENGAGEMENT" || ac_fail "AC4: site/collect-engagement.sh must parse with bash -n"
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import tomllib,sys; tomllib.load(open(sys.argv[1],"rb"))' "$FORMULA" \
    || ac_fail "AC4: formulas/run-publish-site.toml must still parse as TOML"
else
  ac_log 'AC4: python3 is not on this host; TOML parse check skipped'
fi

# ── AC5: the #1776 runner test (formula run-publish-site with stubs) still passes ─
ac_log 'AC5: tests/acceptance/issue-1776.sh still passes'
rc=0
out="$(bash "$TEST_1776" 2>&1)" || rc=$?
ac_assert_eq "$rc" "0" "AC5: issue-1776.sh must still pass after the default move (output: $out)"
printf '%s\n' "$out" | grep -q '^PASS$' \
  || ac_fail "AC5: issue-1776.sh did not report PASS (output: $out)"

ac_pass
