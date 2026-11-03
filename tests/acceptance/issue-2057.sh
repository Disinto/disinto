#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2057.sh
#
# Issue #2057: tools/pitch-approve.sh also merges a bot's claims/probes/packs PR.
#
# Step 1 of #2038 — "no sprints/<slug>.md, so not a pitch, skip without a
# marker" — now reads: no pitch file → _gate_config_ready P. It fails → skip
# with no marker. It succeeds → the same merge, tier and notice a pitch gets,
# with `config` in place of `pitch` and the PR's paths named in the notice.
# _gate_config_ready requires GET /pulls/P/files to be a non-empty array whose
# every entry is added or modified and whose every filename is
# claims/<id>.toml, probes/<name>.sh or packs/<name>.toml; then each file is
# fetched at the PR head with pitch_pr_fetch and validated with claim_valid,
# bash -n, or a tomllib parse. The first offender gets one warning line and no
# merge.
#
# Hermetic: a recorder curl stub serves open PRs 51 (supervisor-bot: a valid
# claim plus a valid probe), 52 (supervisor-bot: an invalid claim), 53
# (gardener-bot: a pack plus a catalog/ file), 54 (planner-bot: a removed
# claim), 55 (disinto-admin: not a bot), 56 (supervisor-bot: a probe that does
# not parse), 57 (supervisor-bot: a pack only). Every call is logged as
# METHOD|URL|BODY. CLASSIFY prints "high". TAPE_DIR, NOTICES_DIR and
# OPS_REPO_ROOT are temp dirs.
#
# Acceptance: `bash tests/acceptance/issue-2057.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq grep mktemp base64 bash python3
ac_assert_file "$REPO_ROOT/tools/pitch-approve.sh" "tools/pitch-approve.sh is missing"
ac_assert_file "$REPO_ROOT/lib/claims.sh" "lib/claims.sh is missing (dependency #1640)"
ac_assert_file "$REPO_ROOT/lib/pitch-pr.sh" "lib/pitch-pr.sh is missing (dependency #1906)"
ac_assert_file "$REPO_ROOT/tests/acceptance/issue-2038.sh" "tests/acceptance/issue-2038.sh is missing"

# ── Wiring and docs ───────────────────────────────────────────────────────────
TOOL="$REPO_ROOT/tools/pitch-approve.sh"
bash -n "$TOOL" || ac_fail "bash -n tools/pitch-approve.sh failed"
if grep -qE 'source[[:space:]].*lib/env\.sh' "$TOOL"; then
  ac_fail "tools/pitch-approve.sh must not source lib/env.sh"
fi
for lib in lib/pitch.sh lib/pitch-pr.sh lib/notice.sh lib/claims.sh; do
  grep -qF "$lib" "$TOOL" || ac_fail "tools/pitch-approve.sh must source $lib"
done
grep -qF '_gate_config_ready' "$TOOL" \
  || ac_fail "tools/pitch-approve.sh must define _gate_config_ready (#2057)"
grep -qF 'claim_valid' "$TOOL" || ac_fail "the config predicate must run claim_valid"
grep -qF 'bash -n' "$TOOL" || ac_fail "the config predicate must run bash -n"
grep -qF 'tomllib' "$TOOL" || ac_fail "the config predicate must parse packs with tomllib"
if grep -qE 'pitch_pr_fetch .*sprints' "$TOOL"; then
  ac_fail "pitch_pr_fetch must not be pinned to sprints/ paths"
fi

GIT_MODE="$(git -C "$REPO_ROOT" ls-files -s tools/pitch-approve.sh)"
case "$GIT_MODE" in
  100755*) ac_log "exec bit OK (git mode 100755)" ;;
  *) ac_fail "the gate tool must land executable (git mode 100755, got ${GIT_MODE:-empty})" ;;
esac

# The header names both kinds of PR, and the gardener doc says a config PR is
# merged the same way.
head -n 4 "$TOOL" | grep -qF '#2057' \
  || ac_fail "the header of tools/pitch-approve.sh must name #2057"
grep -qF "#2057, a bot's PR that only adds or changes" "$REPO_ROOT/gardener/AGENTS.md" \
  || ac_fail "gardener/AGENTS.md must describe the config PR of #2057 in the key-file bullet"

# ── Fixtures ──────────────────────────────────────────────────────────────────
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

OPS="${SCRATCH}/ops-clone"
mkdir -p "${OPS}/probes"
printf '#!/bin/sh\necho 1\n' > "${OPS}/probes/p.sh"

# 51: a valid claim and a valid probe.
cat > "$SCRATCH/claim-boom.toml" <<'EOF'
statement = "a supervisor can-fix claim reaches main within 48 hours"
class = "internal"
check = "probes/can-fix-boom.sh"
expect = "<= 1"
window = "7d"
EOF
printf '#!/bin/sh\nexit 0\n' > "$SCRATCH/probe-boom.sh"

# 52: a claim with no statement and a bad class.
printf 'class = "x"\n' > "$SCRATCH/claim-bad.toml"

# 53: a valid pack, but the PR also touches catalog/claims.md.
printf 'threshold = 3\n' > "$SCRATCH/pack-repair.toml"

# 57: a pack-only PR, merged through the tomllib arm.
printf 'soak = "48h"\n' > "$SCRATCH/pack-stuck.toml"

# 56: a probe that does not parse.
printf 'if then\n' > "$SCRATCH/probe-bad.sh"

STUB_BIN="$SCRATCH/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/curl" <<'CFG_STUB'
#!/usr/bin/env bash
# Fake ops forge for #2057: open PRs 51-57, their file lists, heads and
# contents, and merge POSTs. Records every call as METHOD|URL|BODY in
# $AC_CFG_LOG. AC_MERGE_FAIL=1 makes every */pulls/*/merge exit 22.
set -euo pipefail
method="GET"; body=""; url=""
previous=""
for flag in "$@"; do
  case "$previous" in
    -X) method="$flag" ;;
    -d) body="$flag" ;;
  esac
  case "$flag" in
    http*|https*) url="$flag" ;;
  esac
  previous="$flag"
done
printf '%s|%s|%s\n' "$method" "$url" "$body" >> "${AC_CFG_LOG:?}"
case "$url" in
  *'/pulls?state=open'*'page=1')
    printf '%s\n' '[{"number":51,"title":"claim boom","html_url":"https://forge.example/o/ops/pulls/51","user":{"login":"supervisor-bot"}},{"number":52,"title":"claim bad","html_url":"https://forge.example/o/ops/pulls/52","user":{"login":"supervisor-bot"}},{"number":53,"title":"pack and catalog","html_url":"https://forge.example/o/ops/pulls/53","user":{"login":"gardener-bot"}},{"number":54,"title":"removed claim","html_url":"https://forge.example/o/ops/pulls/54","user":{"login":"planner-bot"}},{"number":55,"title":"owner pack","html_url":"https://forge.example/o/ops/pulls/55","user":{"login":"disinto-admin"}},{"number":56,"title":"broken probe","html_url":"https://forge.example/o/ops/pulls/56","user":{"login":"supervisor-bot"}},{"number":57,"title":"pack only","html_url":"https://forge.example/o/ops/pulls/57","user":{"login":"supervisor-bot"}}]'
    ;;
  *'/pulls?state=open'*)
    printf '%s\n' '[]'
    ;;
  *'/pulls/51/files'*)
    printf '%s\n' '[{"filename":"claims/can-fix-boom.toml","status":"added"},{"filename":"probes/can-fix-boom.sh","status":"added"}]'
    ;;
  *'/pulls/52/files'*)
    printf '%s\n' '[{"filename":"claims/bad.toml","status":"added"}]'
    ;;
  *'/pulls/53/files'*)
    printf '%s\n' '[{"filename":"packs/repair.toml","status":"modified"},{"filename":"catalog/claims.md","status":"modified"}]'
    ;;
  *'/pulls/54/files'*)
    printf '%s\n' '[{"filename":"claims/old.toml","status":"removed"}]'
    ;;
  *'/pulls/55/files'*)
    printf '%s\n' '[{"filename":"packs/x.toml","status":"added"}]'
    ;;
  *'/pulls/56/files'*)
    printf '%s\n' '[{"filename":"probes/p.sh","status":"added"}]'
    ;;
  *'/pulls/57/files'*)
    printf '%s\n' '[{"filename":"packs/stuck.toml","status":"added"}]'
    ;;
  *'/pulls/51/merge'|*'/pulls/57/merge')
    if [ "${AC_MERGE_FAIL:-0}" = "1" ]; then exit 22; fi
    printf '{"Done":true}'
    ;;
  *'/pulls/51')
    printf '{"number":51,"head":{"ref":"cfg-51"}}'
    ;;
  *'/pulls/52')
    printf '{"number":52,"head":{"ref":"cfg-52"}}'
    ;;
  *'/pulls/53')
    printf '{"number":53,"head":{"ref":"cfg-53"}}'
    ;;
  *'/pulls/54')
    printf '{"number":54,"head":{"ref":"cfg-54"}}'
    ;;
  *'/pulls/56')
    printf '{"number":56,"head":{"ref":"cfg-56"}}'
    ;;
  *'/pulls/57')
    printf '{"number":57,"head":{"ref":"cfg-57"}}'
    ;;
  *'/contents/claims/can-fix-boom.toml'*)
    printf '{"sha":"sha-boom","content":"%s"}' "$(base64 < "${AC_CLAIM:?}" | tr -d '\n')"
    ;;
  *'/contents/probes/can-fix-boom.sh'*)
    printf '{"sha":"sha-probe","content":"%s"}' "$(base64 < "${AC_PROBE:?}" | tr -d '\n')"
    ;;
  *'/contents/claims/bad.toml'*)
    printf '{"sha":"sha-bad","content":"%s"}' "$(base64 < "${AC_BAD_CLAIM:?}" | tr -d '\n')"
    ;;
  *'/contents/packs/repair.toml'*)
    printf '{"sha":"sha-pack","content":"%s"}' "$(base64 < "${AC_PACK:?}" | tr -d '\n')"
    ;;
  *'/contents/packs/stuck.toml'*)
    printf '{"sha":"sha-stuck","content":"%s"}' "$(base64 < "${AC_PACK_STUCK:?}" | tr -d '\n')"
    ;;
  *'/contents/probes/p.sh'*)
    printf '{"sha":"sha-p","content":"%s"}' "$(base64 < "${AC_BAD_PROBE:?}" | tr -d '\n')"
    ;;
  *)
    exit 22
    ;;
esac
CFG_STUB
chmod +x "$STUB_BIN/curl"

# Tier seam: prints "high" for every kind and records the kind it was asked
# for, so the test can assert the config PR is classified as config.
cat > "$SCRATCH/classify" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "${AC_CLASSIFY_LOG:?}"
printf 'high\n'
EOF
chmod +x "$SCRATCH/classify"

AC_CFG_LOG="$SCRATCH/calls.txt"
AC_CLASSIFY_LOG="$SCRATCH/tiers.txt"
export AC_CFG_LOG AC_CLASSIFY_LOG
export AC_CLAIM="$SCRATCH/claim-boom.toml" AC_PROBE="$SCRATCH/probe-boom.sh"
export AC_BAD_CLAIM="$SCRATCH/claim-bad.toml" AC_BAD_PROBE="$SCRATCH/probe-bad.sh"
export AC_PACK="$SCRATCH/pack-repair.toml" AC_PACK_STUCK="$SCRATCH/pack-stuck.toml"
export PATH="$STUB_BIN:$PATH"
export FORGE_API_BASE="https://forge.example/api/v1" FORGE_OPS_REPO="o/ops"
export FORGE_TOKEN="stub" OPS_REPO_ROOT="$OPS"
export FORGE_BOT_USERNAMES="planner-bot,gardener-bot,architect-bot,filer-bot,supervisor-bot"
export CLASSIFY="$SCRATCH/classify"

# approve_gate TAPE NOTICES [MERGE_FAIL] — one hermetic run of the gate.
approve_gate() {
  : > "$AC_CFG_LOG"
  : > "$AC_CLASSIFY_LOG"
  RC=0
  TAPE_DIR="$1" NOTICES_DIR="$2" AC_MERGE_FAIL="${3:-0}" \
    bash "$TOOL" 2>"$SCRATCH/gate-stderr" >"$SCRATCH/gate-stdout" || RC=$?
  OUT="$(cat "$SCRATCH/gate-stdout")"
  ERR="$(cat "$SCRATCH/gate-stderr")"
}

# queued_notices DIR — how many notice files the run put in DIR.
queued_notices() {
  local dir="$1" total=0 file
  for file in "$dir"/*.txt; do
    if [ -f "$file" ]; then
      total=$((total + 1))
    fi
  done
  echo "$total"
}

# ── AC1: PR 51 (claims + probes) and PR 57 (pack only) are merged ──────────────
ac_log "AC1: PRs 51 and 57 — POST /pulls/<P>/merge with {\"Do\":\"merge\"}, one notice each, gate markers"
TAPE1="$SCRATCH/tape1"
NOTICES1="$SCRATCH/notices1"
approve_gate "$TAPE1" "$NOTICES1"
ac_assert_eq "$RC" "0" "a run that merges 51 and 57 and rejects the rest must return 0 (got $RC): $ERR"
ac_assert_eq "$(grep -cF 'POST|https://forge.example/api/v1/repos/o/ops/pulls/51/merge|{"Do":"merge"}' "$AC_CFG_LOG")" "1" \
  "the gate must POST /pulls/51/merge with {\"Do\":\"merge\"} (calls: $(cat "$AC_CFG_LOG"))"
ac_assert_eq "$(grep -cF 'POST|https://forge.example/api/v1/repos/o/ops/pulls/57/merge|{"Do":"merge"}' "$AC_CFG_LOG")" "1" \
  "the pack-only PR 57 must be merged the same way (calls: $(cat "$AC_CFG_LOG"))"
if grep -qE 'POST\|[^|]*pulls/(52|53|54|55|56)/merge' "$AC_CFG_LOG"; then
  ac_fail "PRs 52, 53, 54, 55 and 56 must never be merged (calls: $(cat "$AC_CFG_LOG"))"
fi
ac_assert_eq "$(queued_notices "$NOTICES1")" "2" "one notice per merged PR must be queued (got $(queued_notices "$NOTICES1"))"
notice="$(grep -h '#51' "$NOTICES1"/*.txt)"
for needle in '#51' 'config:' 'claims/can-fix-boom.toml' 'probes/can-fix-boom.sh' 'high' '/pulls/51'; do
  case "$notice" in
    *"$needle"*) ;;
    *) ac_fail "the config notice must contain ${needle} (got: $notice)" ;;
  esac
done
notice57="$(grep -h '#57' "$NOTICES1"/*.txt)"
case "$notice57" in
  *'(config: packs/stuck.toml)'*) ;;
  *) ac_fail "the pack notice must name its path (got: $notice57)" ;;
esac
[ -e "$TAPE1/gate/pr-51" ] || ac_fail "the marker gate/pr-51 must exist after the merge"
[ -e "$TAPE1/gate/pr-57" ] || ac_fail "the marker gate/pr-57 must exist after the merge"
for n in 52 53 54 55 56; do
  if [ -e "$TAPE1/gate/pr-${n}" ]; then
    ac_fail "gate/pr-${n} must not exist: an unmerged PR gets no marker"
  fi
done
printf '%s' "$ERR" | grep -qF 'claims/bad.toml' \
  || ac_fail "PR 52 must log the invalid claim (stderr: $ERR)"
printf '%s' "$ERR" | grep -qF 'probes/p.sh' \
  || ac_fail "PR 56 must log the probe that fails bash -n (stderr: $ERR)"
printf '%s' "$ERR" | grep -qF 'catalog/claims.md' \
  || ac_fail "PR 53 must log the catalog path it is not allowed to touch (stderr: $ERR)"
printf '%s' "$ERR" | grep -qF 'claims/old.toml' \
  || ac_fail "PR 54 must log the removed claim file (stderr: $ERR)"
grep -qF 'config' "$AC_CLASSIFY_LOG" \
  || ac_fail "the tier seam must be asked for the config tier (tiers: $(cat "$AC_CLASSIFY_LOG"))"
ac_assert_eq "$OUT" "" "stdout must stay empty (got: $OUT)"
ac_log "AC1 OK"

# ── AC2: a second run makes no merge call ─────────────────────────────────────
ac_log "AC2: the gate/pr-51 and gate/pr-57 markers mean the second run never POSTs merge"
approve_gate "$TAPE1" "$NOTICES1"
ac_assert_eq "$RC" "0" "the second run must return 0 (got $RC): $ERR"
if grep -qE 'POST\|[^|]*pulls/[0-9]+/merge' "$AC_CFG_LOG"; then
  ac_fail "the second run must make no merge call (calls: $(cat "$AC_CFG_LOG"))"
fi
ac_assert_eq "$(queued_notices "$NOTICES1")" "2" "the second run must queue no new notice"
ac_log "AC2 OK"

# ── AC3: the merge call fails — no marker, rc 1 ───────────────────────────────
ac_log "AC3: a failing merge POST for 51 — no marker, the tool exits 1"
TAPE3="$SCRATCH/tape3"
NOTICES3="$SCRATCH/notices3"
approve_gate "$TAPE3" "$NOTICES3" 1
ac_assert_eq "$RC" "1" "a failed merge must make the run exit 1 (got $RC): $ERR"
ac_assert_eq "$(grep -cF '/pulls/51/merge' "$AC_CFG_LOG")" "1" "the merge attempt must still have been POSTed"
[ ! -e "$TAPE3/gate/pr-51" ] || ac_fail "a failed merge must leave no marker"
[ ! -e "$TAPE3/gate/pr-57" ] || ac_fail "a failed merge must leave no marker for 57 either"
ac_assert_eq "$(queued_notices "$NOTICES3")" "0" "a failed merge must queue no notice"
printf '%s' "$ERR" | grep -qF 'merge failed' \
  || ac_fail "the merge failure must be warned about (stderr: $ERR)"
ac_log "AC3 OK"

# ── AC4: the pitch tests still pass unchanged ─────────────────────────────────
ac_log "AC4: tests/acceptance/issue-2038.sh (pitch walk) still passes"
PITCH_RC=0
bash "$REPO_ROOT/tests/acceptance/issue-2038.sh" >"$SCRATCH/pitch-out" 2>"$SCRATCH/pitch-err" || PITCH_RC=$?
ac_assert_eq "$PITCH_RC" "0" "issue-2038.sh must still pass unchanged (got $PITCH_RC): $(cat "$SCRATCH/pitch-out")"
ac_log "AC4 OK"

ac_pass
