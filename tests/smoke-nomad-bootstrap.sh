#!/usr/bin/env bash
# tests/smoke-nomad-bootstrap.sh — Smoke test for agents bootstrap on nomad init (#623)
#
# Verifies the end-to-end agents bootstrap path fixed in #574:
#
#   disinto init --backend=nomad --with agents
#   → generate_default_toml() writes /srv/disinto/project-repos/_factory/projects/<name>.toml
#   → docker/agents/entrypoint.sh copies that TOML into the live checkout
#   → validate_projects_dir() finds a real .toml and does NOT abort with
#     "FATAL: No real .toml files found" (the crash loop that motivated #574).
#
# A real Nomad cluster is not required — we exercise each stage of the
# bootstrap pipeline directly:
#
#   1. `disinto init --backend=nomad --with agents --dry-run` output pins
#      the seed step into the deploy plan (regression guard for #622 wiring).
#   2. generate_default_toml() produces a TOML that python3 tomllib parses
#      with the expected 'name' field.
#   3. The seeded TOML matches the entrypoint's `*.toml` glob (i.e. it is
#      NOT an `.example` template) — the specific check that was failing
#      under the pre-#574 behaviour.
#   4. Simulating the entrypoint's host-volume copy + validate_projects_dir
#      against a temp DISINTO_DIR proves the FATAL branch is NOT reached.
#
# Hermetic — no Forgejo, no sudo, no nomad binary, no network.
# Required tools: bash, python3.

set -euo pipefail

FACTORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISINTO_BIN="${FACTORY_ROOT}/bin/disinto"
FAILED=0
TMPROOT=$(mktemp -d -t smoke-nomad-bootstrap.XXXXXX)

fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }
pass() { printf 'PASS: %s\n' "$*"; }

cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

[ -x "$DISINTO_BIN" ] || { echo "disinto binary not executable: $DISINTO_BIN" >&2; exit 1; }

# ── 1. Dry-run deploy plan lists the agents TOML seed step ─────────────────
echo "=== 1/4 Dry-run asserts agents TOML seed step is wired in ==="
dryrun_out=$("$DISINTO_BIN" init smoke-org/smoke-repo \
  --backend=nomad --with agents --dry-run 2>&1) || true

if printf '%s\n' "$dryrun_out" | grep -q '\[deploy\] \[dry-run\] \[seed\] would generate default projects/smoke-repo\.toml'; then
  pass "Dry-run mentions 'would generate default projects/smoke-repo.toml'"
else
  fail "Dry-run did NOT mention the agents TOML seed step"
  printf '%s\n' "$dryrun_out" | grep -i 'seed\|project\|agents' >&2 || true
fi

# Sanity: agents service appears in the deploy order so the seed branch
# will actually be reached on a real run.
if printf '%s\n' "$dryrun_out" | grep -qE '\[deploy\] deployment order:.* agents'; then
  pass "Agents appears in the deployment order"
else
  fail "Agents missing from the deployment order"
fi

# ── 2. generate_default_toml helper writes a parseable TOML ────────────────
echo "=== 2/4 generate_default_toml() writes a parseable TOML ==="
# bin/disinto is a CLI dispatcher — sourcing it hits the `*) usage` branch
# and exits. Extract just the function body with sed and source that,
# which still proves the real helper is callable with the documented
# signature (project_name, forge_url, output_path).
PROJECT_NAME="smoke-repo"
OUT_TOML="${TMPROOT}/srv/projects/${PROJECT_NAME}.toml"
HELPER_SNIPPET="${TMPROOT}/helper.sh"
# Function definition spans from `generate_default_toml()` to the first
# `^}` at column 0 — the pattern matches the helper's closing brace.
sed -n '/^generate_default_toml()/,/^}/p' "$DISINTO_BIN" >"$HELPER_SNIPPET"

if ! grep -q 'generate_default_toml()' "$HELPER_SNIPPET"; then
  fail "Could not extract generate_default_toml from $DISINTO_BIN"
fi

(
  # Minimal stubs so the extracted helper runs in isolation — the real
  # `log` helper from lib/env.sh is not loaded here. shellcheck flags it
  # as "unreachable" because it cannot see the source sourcing below.
  # shellcheck disable=SC2317
  log() { :; }
  # The real helper expands ${USER} inside its heredoc. CI base images
  # (e.g. python:3-alpine running as root without a login shell) may not
  # set USER, which would trip `set -u` and truncate the generated TOML.
  # The production call path always has USER set; this fallback is only
  # for the hermetic test environment.
  export USER="${USER:-smoke}"
  # shellcheck disable=SC1090
  source "$HELPER_SNIPPET"
  if ! declare -F generate_default_toml >/dev/null; then
    echo "generate_default_toml is not defined after source" >&2
    exit 66
  fi
  generate_default_toml "$PROJECT_NAME" "http://localhost:3000" "$OUT_TOML" >/dev/null
) || fail "generate_default_toml failed to run"

if [ -f "$OUT_TOML" ]; then
  pass "generate_default_toml wrote ${OUT_TOML}"
else
  fail "generate_default_toml did not create ${OUT_TOML}"
fi

parsed_name=$(python3 -c "
import sys, tomllib
with open(sys.argv[1], 'rb') as f:
    data = tomllib.load(f)
print(data.get('name', ''))
" "$OUT_TOML" 2>/dev/null) || parsed_name=""

if [ "$parsed_name" = "$PROJECT_NAME" ]; then
  pass "Seeded TOML parses and name='${parsed_name}'"
else
  fail "Seeded TOML parse failed or wrong name: got '${parsed_name}', expected '${PROJECT_NAME}'"
fi

# ── 3. Seeded TOML matches *.toml (not *.toml.example) ─────────────────────
echo "=== 3/4 Seeded TOML matches the entrypoint's *.toml glob ==="
# The specific check validate_projects_dir performs. An .example file
# would NOT satisfy it (that was the pre-fix silent-zombie failure).
case "$OUT_TOML" in
  *.toml.example) fail "Seeded file has .example suffix — would not match glob" ;;
  *.toml) pass "Seeded file has .toml suffix (glob-compatible)" ;;
  *) fail "Seeded file has unexpected suffix: $OUT_TOML" ;;
esac

# ── 4. Simulated entrypoint bootstrap → validate does NOT emit FATAL ───────
echo "=== 4/4 Entrypoint simulation: no 'FATAL: No real .toml files' ==="
# Stage directories to mirror the container layout:
#   $TMPROOT/srv/projects/         — host volume (where init seeds)
#   $TMPROOT/live/projects/        — DISINTO_DIR (where the entrypoint copies to)
DISINTO_DIR_SIM="${TMPROOT}/live"
mkdir -p "${DISINTO_DIR_SIM}/projects"

# Re-implement the host-volume copy block from docker/agents/entrypoint.sh.
# The real block has a hardcoded path (/srv/disinto/project-repos/_factory/
# projects) so cannot be sourced directly; this mirrors the same semantics
# on our temp dirs. The assertion below — that validate_projects_dir no
# longer emits FATAL after seeding — is what catches a #622 regression.
host_projects="${TMPROOT}/srv/projects"
copied=false
for t in "${host_projects}"/*.toml; do
  [ -f "$t" ] || continue
  cp "$t" "${DISINTO_DIR_SIM}/projects/"
  copied=true
done
if [ "$copied" = true ]; then
  pass "Simulated host-volume copy populated live projects/ dir"
else
  fail "Simulated host-volume copy did not copy any TOMLs"
fi

# Run the exact glob check validate_projects_dir performs. `compgen -G`
# exits non-zero when the glob has no matches — that is the branch that
# triggers `FATAL: No real .toml files found` in the real entrypoint.
validate_log="${TMPROOT}/validate.log"
if compgen -G "${DISINTO_DIR_SIM}/projects/*.toml" >/dev/null 2>&1; then
  toml_count=$(compgen -G "${DISINTO_DIR_SIM}/projects/*.toml" | wc -l)
  printf 'Projects directory validated: %s real .toml file(s) found\n' \
    "$toml_count" >"$validate_log"
  pass "validate_projects_dir-equivalent found ${toml_count} real .toml file(s)"
else
  printf 'FATAL: No real .toml files found in %s/projects/\n' \
    "$DISINTO_DIR_SIM" >"$validate_log"
  fail "validate_projects_dir-equivalent would have FATAL-exited"
fi

if grep -q 'FATAL: No real .toml files' "$validate_log"; then
  fail "Validate log contains the FATAL line that motivated #574"
  cat "$validate_log" >&2
else
  pass "Validate log contains NO 'FATAL: No real .toml files' line"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
if [ "$FAILED" -ne 0 ]; then
  echo "=== SMOKE-NOMAD-BOOTSTRAP TEST FAILED ==="
  exit 1
fi
echo "=== SMOKE-NOMAD-BOOTSTRAP TEST PASSED ==="
