#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1645.sh
#
# Issue #1645: catalog/claims.md shows each claim's status.
#
# tools/claims-report.sh prints a markdown table, one row per claim_ids id:
#   claim | class | status | checks | last value | resting sprints | statement
# status comes from the last outcome of the proposal in <id>.current
# (none -> provisional, held 1 -> held, contradicted 1 -> challenged;
# no .current -> not proposed). checks is the number of completed runs under
# that proposal. last value is ${TAPE_DIR}/claims/<id>.last, or -. resting
# sprints are milestone:<N> for each open milestone (forge_api GET
# "/milestones?state=open") whose rests_on names the id.
#
# gardener/gardener-run.sh refresh_ops_calibration writes that stdout to
# catalog/claims.md and passes both catalog files to the one ops_commit_and_push
# call. A failing report only logs a warning and still commits calibration.md.
#
# Hermetic: no network, stubbed forge_api, fixture tape and CLAIMS_DIR.
#
# Acceptance: `bash tests/acceptance/issue-1645.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq python3
ac_assert_file "$REPO_ROOT/tools/claims-report.sh" "tools/claims-report.sh is missing"
ac_assert_file "$REPO_ROOT/gardener/gardener-run.sh" "gardener/gardener-run.sh is missing"
ac_assert_file "$REPO_ROOT/gardener/AGENTS.md" "gardener/AGENTS.md is missing"

# The review (formula 3b) requires this sentence after the refresh_ops_calibration
# sentence. Wrapping is allowed; the words must appear in this order.
# shellcheck disable=SC2016  # backticks are markdown in the required sentence
DOC_SENTENCE='The same commit writes the output of `tools/claims-report.sh` (#1645) to `${OPS_REPO_ROOT}/catalog/claims.md`; a failing claims report only logs a warning.'
AGENTS_FLAT="$(tr '\n' ' ' < "$REPO_ROOT/gardener/AGENTS.md" | tr -s ' ')"
printf '%s\n' "$AGENTS_FLAT" | grep -qF "$DOC_SENTENCE" \
  || ac_fail "gardener/AGENTS.md must describe claims-report.sh (#1645) in the calibration commit"
CAL_DOC=$(grep -n 'refresh_ops_calibration`, #1454' "$REPO_ROOT/gardener/AGENTS.md" | head -n1 | cut -d: -f1)
CLAIM_DOC=$(grep -n 'tools/claims-report.sh` (#1645)' "$REPO_ROOT/gardener/AGENTS.md" | head -n1 | cut -d: -f1)
[ -n "$CAL_DOC" ] || ac_fail "gardener/AGENTS.md must still name refresh_ops_calibration (#1454)"
[ -n "$CLAIM_DOC" ] || ac_fail "gardener/AGENTS.md must name tools/claims-report.sh (#1645)"
[ "$CAL_DOC" -lt "$CLAIM_DOC" ] \
  || ac_fail "claims-report sentence (line $CLAIM_DOC) must follow the refresh_ops_calibration sentence (line $CAL_DOC)"
ac_log "docs OK: claims-report.sh rides the calibration commit; a failure only warns"

# Wiring: the report is invoked from refresh_ops_calibration, both catalog files
# can reach the one ops_commit_and_push, and a non-zero exit only warns.
GARDENER="$REPO_ROOT/gardener/gardener-run.sh"
FN_SRC="$(ac_extract_fn refresh_ops_calibration "$GARDENER")"
[ -n "$FN_SRC" ] || ac_fail "could not extract refresh_ops_calibration() from gardener-run.sh"
case "$FN_SRC" in
  *'"$FACTORY_ROOT/tools/claims-report.sh"'*) ;;
  *) ac_fail "refresh_ops_calibration must invoke tools/claims-report.sh" ;;
esac
case "$FN_SRC" in
  *catalog/claims.md*) ;;
  *) ac_fail "refresh_ops_calibration must write catalog/claims.md" ;;
esac
case "$FN_SRC" in
  *ops_commit_and_push*) ;;
  *) ac_fail "refresh_ops_calibration must still call ops_commit_and_push" ;;
esac
case "$FN_SRC" in
  *'claims-report.sh failed'*) ;;
  *) ac_fail "a failing claims-report.sh must log a warning" ;;
esac
# One call site, not a second commit for claims.md.
PUSH_N=$(printf '%s\n' "$FN_SRC" | grep -c 'ops_commit_and_push' || true)
ac_assert_eq "$PUSH_N" "1" \
  "refresh_ops_calibration must pass both files to the one ops_commit_and_push call (found $PUSH_N)"
ac_log "wiring OK: claims-report.sh is inside refresh_ops_calibration; one ops_commit_and_push"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CLAIMS_DIR="$TMP_DIR/claims"
TAPE_DIR="$TMP_DIR/tape"
mkdir -p "$CLAIMS_DIR" "$TAPE_DIR/claims"

# Held claim: 3 completed runs, a failed run that must not count, an earlier
# contradicted outcome with a later timestamp (last tape line is held), and
# .last = 0.12 2026-10-01T00:00:00Z. One open milestone rests on it.
# Written with python so the fixture text is not a copied heredoc block.
python3 - "$CLAIMS_DIR/dev-comes-back.toml" <<'PY'
import pathlib, sys
pathlib.Path(sys.argv[1]).write_text(
    "statement = \"a dev proposal comes back, merged or rejected, within 48 hours\"\n"
    "class = \"internal\"\n"
    "check = \"probes/dev-unreturned.sh\"\n"
    "expect = \"<= 0.2\"\n"
    "window = \"7d\"\n"
    "rests_on = []\n"
)
PY
printf '%s\n' 'pid-held' >"$TAPE_DIR/claims/dev-comes-back.current"
printf '%s\n' '0.12 2026-10-01T00:00:00Z' >"$TAPE_DIR/claims/dev-comes-back.last"

# No .current: not proposed. A closed milestone rests on it and must not show.
cat >"$CLAIMS_DIR/not-yet.toml" <<'EOF'
statement = "this claim has no proposal yet"
class     = "experiment"
check     = "probes/dev-unreturned.sh"
expect    = "<= 0.2"
window    = "7d"
rests_on  = []
EOF

# Last outcome contradicted 1 -> challenged, even after an earlier hold.
cat >"$CLAIMS_DIR/zz-challenged.toml" <<'EOF'
statement = "a later miss challenges the claim"
class     = "internal"
check     = "probes/dev-unreturned.sh"
expect    = "<= 0.2"
window    = "7d"
rests_on  = []
EOF
printf '%s\n' 'pid-chal' >"$TAPE_DIR/claims/zz-challenged.current"

# .current and no outcome -> provisional. A failed run is not a check.
cat >"$CLAIMS_DIR/mm-open.toml" <<'EOF'
statement = "still provisional"
class     = "deploy"
check     = "probes/dev-unreturned.sh"
expect    = "<= 0.2"
window    = "7d"
rests_on  = []
EOF
printf '%s\n' 'pid-open' >"$TAPE_DIR/claims/mm-open.current"

cat >"$TAPE_DIR/tape.jsonl" <<'TPE'
{"type":"proposal","t":"2026-09-01T00:00:00Z","id":"pid-held","loop":"claim","class":"internal","context":{},"decision":"approved","ref":"claims/dev-comes-back.toml"}
{"type":"run","t":"2026-09-02T00:00:00Z","proposal_id":"pid-held","organ":"gardener","agent":"bash","started":"2026-09-02T00:00:00Z","ended":"2026-09-02T00:00:01Z","attempts":1,"cost":{"duration_s":1},"status":"completed"}
{"type":"run","t":"2026-09-03T00:00:00Z","proposal_id":"pid-held","organ":"gardener","agent":"bash","started":"2026-09-03T00:00:00Z","ended":"2026-09-03T00:00:01Z","attempts":1,"cost":{"duration_s":1},"status":"failed"}
{"type":"run","t":"2026-09-04T00:00:00Z","proposal_id":"pid-held","organ":"gardener","agent":"bash","started":"2026-09-04T00:00:00Z","attempts":1,"cost":{"duration_s":1}}
{"type":"run","t":"2026-09-05T00:00:00Z","proposal_id":"pid-held","organ":"gardener","agent":"bash","started":"2026-09-05T00:00:00Z","ended":"2026-09-05T00:00:01Z","attempts":1,"cost":{"duration_s":1},"status":"completed"}
{"type":"run","t":"2026-09-06T00:00:00Z","proposal_id":"pid-held","organ":"gardener","agent":"bash","started":"2026-09-06T00:00:00Z","ended":"2026-09-06T00:00:01Z","attempts":1,"cost":{"duration_s":1},"status":"abandoned"}
{"type":"outcome","t":"2026-12-01T00:00:00Z","proposal_id":"pid-held","bits":{"contradicted":1,"held":0},"numbers":{"value":0.9},"children":{},"payloads":[]}
{"type":"run","t":"2026-09-07T00:00:00Z","proposal_id":"pid-held","organ":"gardener","agent":"bash","started":"2026-09-07T00:00:00Z","ended":"2026-09-07T00:00:01Z","attempts":1,"cost":{"duration_s":1},"status":"completed"}
{"type":"outcome","t":"2026-10-01T00:00:00Z","proposal_id":"pid-held","bits":{"held":1,"contradicted":0},"numbers":{"value":0.12},"children":{},"payloads":[]}
{"type":"run","t":"2026-09-08T00:00:00Z","proposal_id":"other","organ":"gardener","agent":"bash","started":"2026-09-08T00:00:00Z","ended":"2026-09-08T00:00:01Z","attempts":1,"cost":{"duration_s":1},"status":"completed"}
{"type":"outcome","t":"2026-09-01T00:00:00Z","proposal_id":"pid-chal","bits":{"held":1,"contradicted":0},"numbers":{"value":0.1},"children":{},"payloads":[]}
{"type":"run","t":"2026-09-09T00:00:00Z","proposal_id":"pid-chal","organ":"gardener","agent":"bash","started":"2026-09-09T00:00:00Z","ended":"2026-09-09T00:00:01Z","attempts":1,"cost":{"duration_s":1},"status":"completed"}
{"type":"outcome","t":"2026-09-10T00:00:00Z","proposal_id":"pid-chal","bits":{"contradicted":1,"held":0},"numbers":{"value":0.8},"children":{},"payloads":[]}
{"type":"run","t":"2026-09-11T00:00:00Z","proposal_id":"pid-open","organ":"gardener","agent":"bash","started":"2026-09-11T00:00:00Z","ended":"2026-09-11T00:00:01Z","attempts":1,"cost":{"duration_s":1},"status":"failed"}
TPE

# Open milestone 12 names the held claim as a rests_on token (not a substring).
# Milestone 40 is a substring trap. Milestone 3 is closed and rests on not-yet.
# Milestone 8 rests on nobody in the catalog.
MILESTONES_FILE="$TMP_DIR/milestones.json"
jq -n \
  --arg d12 $'class: experiment\nrests_on: other-claim, dev-comes-back\nsoak: 7d\n' \
  --arg d40 $'rests_on: dev-comes-back-extra\n' \
  --arg d3 $'rests_on: not-yet\n' \
  --arg d8 $'class: deploy\nsoak: 48h\n' \
  '[
    {id: 40, state: "open", description: $d40},
    {id: 12, state: "open", description: $d12},
    {id: 3, state: "closed", description: $d3},
    {id: 8, state: "open", description: $d8}
  ]' >"$MILESTONES_FILE"

STUB_BIN="$TMP_DIR/bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/forge_api" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${FORGE_STUB_RC:-0}" != "0" ]; then
  echo "forge_api stub: forced failure" >&2
  exit "${FORGE_STUB_RC}"
fi
if [ "${1:-}" != "GET" ] || [ "${2:-}" != "/milestones?state=open" ]; then
  echo "unexpected forge_api: $*" >&2
  exit 1
fi
cat "${MILESTONES_FILE:?}"
EOF
chmod +x "$STUB_BIN/forge_api"

# run_report — execute claims-report.sh. stdout -> $OUT, stderr -> $ERR, rc -> $RC.
# A leaked FORGE_API must not turn the fallback into a network call.
run_report() {
  RC=0
  ERR=""
  OUT="$(
    env -u FORGE_API -u FORGE_TOKEN \
      CLAIMS_DIR="$CLAIMS_DIR" TAPE_DIR="$TAPE_DIR" \
      MILESTONES_FILE="$MILESTONES_FILE" PATH="$STUB_BIN:${PATH}" \
      bash "$REPO_ROOT/tools/claims-report.sh" 2>"$TMP_DIR/report.err"
  )" || RC=$?
  if [ -s "$TMP_DIR/report.err" ]; then
    ERR="$(cat "$TMP_DIR/report.err")"
  fi
}

HELD_ROW='| dev-comes-back | internal | held | 3 | 0.12 2026-10-01T00:00:00Z | milestone:12 | a dev proposal comes back, merged or rejected, within 48 hours |'
NOT_ROW='| not-yet | experiment | not proposed | 0 | - | - | this claim has no proposal yet |'
HEADER='| claim | class | status | checks | last value | resting sprints | statement |'

ac_log "AC1: held claim with 3 completed runs, last value, and one resting sprint"
run_report
ac_assert_eq "$RC" "0" "claims-report.sh must exit 0 (rc=$RC) stderr=$ERR"
ac_assert_eq "$(printf '%s\n' "$OUT" | head -n 1)" "$HEADER" \
  "table must start with the claims header, got: $(printf '%s\n' "$OUT" | head -n 1)"
printf '%s\n' "$OUT" | grep -qF "$HELD_ROW" \
  || ac_fail "held row missing or wrong (got: $OUT)"
printf '%s\n' "$OUT" | grep -qF 'milestone:40' \
  && ac_fail "a rests_on substring must not count as naming the claim (got: $OUT)"
printf '%s\n' "$OUT" | grep -qF 'milestone:3' \
  && ac_fail "a closed milestone must not be a resting sprint (got: $OUT)"
printf '%s\n' "$OUT" | grep -qF 'milestone:8' \
  && ac_fail "a milestone that does not rest on the claim must not appear (got: $OUT)"
ac_log "AC1 OK: held, 3, last value, milestone:12"

ac_log "AC2: a claim without .current shows not proposed"
printf '%s\n' "$OUT" | grep -qF "$NOT_ROW" \
  || ac_fail "not-proposed row missing or wrong (got: $OUT)"
ac_log "AC2 OK: not-yet is not proposed"

CHAL_ROW='| zz-challenged | internal | challenged | 1 | - | - | a later miss challenges the claim |'
PROV_ROW='| mm-open | deploy | provisional | 0 | - | - | still provisional |'
printf '%s\n' "$OUT" | grep -qF "$CHAL_ROW" \
  || ac_fail "contradicted 1 must show challenged (got: $OUT)"
printf '%s\n' "$OUT" | grep -qF "$PROV_ROW" \
  || ac_fail "no outcome must show provisional (got: $OUT)"
ac_log "status map OK: challenged and provisional"

ac_log "AC3: forge_api failure prints nothing and exits non-zero"
export FORGE_STUB_RC=9
run_report
unset FORGE_STUB_RC
[ "$RC" -ne 0 ] || ac_fail "a failing forge_api must fail the report (rc=$RC)"
[ -z "$OUT" ] || ac_fail "a failing forge_api must print no table (got: $OUT)"
printf '%s\n' "$ERR" | grep -qF 'forge_api stub: forced failure' \
  || ac_fail "the stubbed forge_api must be the call that failed (got: $ERR)"
ac_log "AC3 OK: forge failure is a tool failure with no partial table"

# ── Gardener: both files in the one commit; a failing report only warns ──────

write_factory() {
  local factory="$1" claims_rc="$2"
  mkdir -p "${factory}/tools"
  cat >"${factory}/tools/calibration.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'calibration-body'
SH
  # refresh_ops_calibration pipes calibration.sh through these tools
  # (#1651, #1652). Pass-throughs keep the stubbed calibration body; a
  # missing script would fail the pipeline and skip the file.
  cat >"${factory}/tools/calibration-signatures.sh" <<'SH'
#!/usr/bin/env bash
cat
SH
  cat >"${factory}/tools/calibration-purpose.sh" <<'SH'
#!/usr/bin/env bash
cat
SH
  cat >"${factory}/tools/claims-report.sh" <<SH
#!/usr/bin/env bash
if [ "$claims_rc" -ne 0 ]; then
  echo "claims-report: forced failure" >&2
  exit $claims_rc
fi
printf '%s\n' 'claims-body'
SH
  chmod +x "${factory}/tools/calibration.sh" "${factory}/tools/calibration-signatures.sh" \
    "${factory}/tools/calibration-purpose.sh" "${factory}/tools/claims-report.sh"
}

# push_has OUT NEEDLE — rc 0 when the stubbed commit log contains NEEDLE.
push_has() {
  case "$1" in
    *"$2"*) return 0 ;;
  esac
  return 1
}

# run_refresh FACTORY OPS — eval the extracted function. log and
# ops_commit_and_push are stubbed. stdout is the gardener log + push lines.
run_refresh() {
  local factory="$1" ops_root="$2"
  FACTORY_ROOT="$factory" OPS_REPO_ROOT="$ops_root" PRIMARY_BRANCH="main" \
    PICK_FN="$FN_SRC" bash -c '
    set -u
    log() { printf "gardener-log: %s\n" "$*"; }
    ops_commit_and_push() {
      local message="$1" staged
      shift
      printf "PUSHED count=%s message=%s\n" "$#" "$message"
      for staged in "$@"; do
        printf "STAGED %s\n" "$staged"
      done
    }
    eval "$PICK_FN"
    refresh_ops_calibration || return 0
  '
}

ac_log "AC4: a successful report is written and committed with calibration.md"
OPS_OK="$TMP_DIR/ops-ok"
FACTORY_OK="$TMP_DIR/factory-ok"
mkdir -p "$OPS_OK"
write_factory "$FACTORY_OK" 0
rc=0
out="$(run_refresh "$FACTORY_OK" "$OPS_OK")" || rc=$?
ac_assert_eq "$rc" "0" "refresh with a good claims report must return 0 (rc=$rc): $out"
ac_assert_eq "$(cat "$OPS_OK/catalog/claims.md")" "claims-body" \
  "catalog/claims.md must be the tool's stdout"
ac_assert_file "$OPS_OK/catalog/calibration.md" "calibration.md must still be written"
push_has "$out" "PUSHED count=2" \
  || ac_fail "the one ops_commit_and_push must receive both files, got: $out"
push_has "$out" "STAGED catalog/calibration.md" \
  || ac_fail "ops_commit_and_push must stage catalog/calibration.md, got: $out"
push_has "$out" "STAGED catalog/claims.md" \
  || ac_fail "ops_commit_and_push must stage catalog/claims.md, got: $out"
ac_log "AC4 OK: both catalog files in the one commit"

ac_log "AC5: a failing claims report only warns; calibration.md is still committed"
OPS_BAD="$TMP_DIR/ops-bad"
FACTORY_BAD="$TMP_DIR/factory-bad"
mkdir -p "$OPS_BAD"
# A pre-existing claims.md must be left untouched when the report fails.
mkdir -p "$OPS_BAD/catalog"
printf '%s\n' 'stale-claims' >"$OPS_BAD/catalog/claims.md"
write_factory "$FACTORY_BAD" 4
rc=0
out="$(run_refresh "$FACTORY_BAD" "$OPS_BAD")" || rc=$?
ac_assert_eq "$rc" "0" "a failing claims report must not abort the gardener (rc=$rc): $out"
case "$out" in
  *"WARNING"*"claims-report.sh failed"*) ;;
  *) ac_fail "a failing claims report must log a WARNING naming claims-report.sh, got: $out" ;;
esac
ac_assert_eq "$(cat "$OPS_BAD/catalog/claims.md")" "stale-claims" \
  "a failed report must not overwrite claims.md"
ac_assert_file "$OPS_BAD/catalog/calibration.md" \
  "calibration.md must still be written when the claims report fails"
push_has "$out" "PUSHED count=1" \
  || ac_fail "a failed report must leave the calibration commit as calibration.md only, got: $out"
push_has "$out" "STAGED catalog/calibration.md" \
  || ac_fail "calibration.md must still be committed, got: $out"
if push_has "$out" "STAGED catalog/claims.md"; then
  ac_fail "claims.md must not be staged when the report fails, got: $out"
fi
ac_log "AC5 OK: failing claims report warns and leaves the calibration refresh as it is"

ac_pass
