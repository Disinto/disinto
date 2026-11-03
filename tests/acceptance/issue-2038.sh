#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2038.sh
#
# Issue #2038: tools/pitch-approve.sh merges a bot's ready pitch.
#
# A pitch is an ops-repo PR adding sprints/<slug>.md, opened by a bot. The
# gate now merges it itself and tells the owner (docs/design/proposal-loop.md
# §3). A pitch is ready when the architect has drafted its sub-issues onto
# the PR branch (a `<!-- filer:begin -->` block that tools/pitch-lint.sh
# passes) and its sprint block's `effect` is `none`, a file under
# OPS_REPO_ROOT, or a file the PR itself adds — a sprint whose probe is not
# in the ops repo is never scored. A merge writes ${TAPE_DIR}/gate/pr-<P>
# and one notice_owner line; an unready pitch logs one line and stays
# unmarked for the next run.
#
# gardener/gardener-run.sh calls the tool right after the run lock and
# before ensure_ops_repo, guarded (rc=0; tool || rc=$?; warn).
#
# Hermetic: a recorder curl stub serves open ops PRs 31 (planner-bot, adds
# sprints/x.md, filer block, effect probes/p.sh), 32 (disinto-admin), 33
# (planner-bot, no filer block) and 34 (planner-bot, effect probes/missing.sh),
# their head contents and file lists, and logs every call as METHOD|URL|BODY.
# PITCH_LINT is a stub exiting $LINT_RC; CLASSIFY prints "medium". OPS_REPO_ROOT,
# TAPE_DIR and NOTICES_DIR are temp dirs.
#
# Acceptance: `bash tests/acceptance/issue-2038.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq grep mktemp base64
ac_assert_file "$REPO_ROOT/tools/pitch-approve.sh" "tools/pitch-approve.sh is missing"
ac_assert_file "$REPO_ROOT/gardener/gardener-run.sh" "gardener/gardener-run.sh is missing"
ac_assert_file "$REPO_ROOT/lib/notice.sh" "lib/notice.sh is missing (dependency #2031)"

# ── Wiring: after the run lock, before ensure_ops_repo, guarded ──────────────
GARDENER="$REPO_ROOT/gardener/gardener-run.sh"
CALL_LINE=$(grep -n 'tools/pitch-approve.sh' "$GARDENER" | grep '||' | head -n1 | cut -d: -f1)
OPS_LINE=$(grep -n 'ensure_ops_repo' "$GARDENER" | head -n1 | cut -d: -f1)
[ -n "$CALL_LINE" ] || ac_fail "gardener-run.sh must call tools/pitch-approve.sh with ||"
[ -n "$OPS_LINE" ] || ac_fail "gardener-run.sh must still call ensure_ops_repo"
[ "$CALL_LINE" -lt "$OPS_LINE" ] \
  || ac_fail "pitch-approve.sh (line $CALL_LINE) must run before ensure_ops_repo (line $OPS_LINE)"
bash -n "$GARDENER" || ac_fail "bash -n gardener/gardener-run.sh failed"
ac_log "wiring OK: pitch-approve.sh is guarded between the run lock and ensure_ops_repo"

# The tool itself parses cleanly and does not source lib/env.sh.
bash -n "$REPO_ROOT/tools/pitch-approve.sh" || ac_fail "bash -n tools/pitch-approve.sh failed"
if grep -qE 'source[[:space:]].*lib/env\.sh' "$REPO_ROOT/tools/pitch-approve.sh"; then
  ac_fail "tools/pitch-approve.sh must not source lib/env.sh"
fi
for lib in lib/pitch.sh lib/pitch-pr.sh lib/notice.sh; do
  grep -qF "$lib" "$REPO_ROOT/tools/pitch-approve.sh" \
    || ac_fail "tools/pitch-approve.sh must source $lib"
done

# Mode is the git index, not the working-tree bit.
MODE_LINE="$(git -C "$REPO_ROOT" ls-files -s tools/pitch-approve.sh)"
case "$MODE_LINE" in
  100755*) ac_log "mode OK: tools/pitch-approve.sh is 100755" ;;
  *) ac_fail "git ls-files -s tools/pitch-approve.sh must start with 100755 (got: ${MODE_LINE:-empty})" ;;
esac

# Docs the issue requires.
grep -qF "runs \`tools/pitch-approve.sh\` (#2038) first" "$REPO_ROOT/gardener/AGENTS.md" \
  || ac_fail "gardener/AGENTS.md must describe pitch-approve.sh (#2038) in the key-file bullet"

# ── Fixtures ──────────────────────────────────────────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

OPS="$WORK/ops"
mkdir -p "$OPS/probes"
printf '#!/bin/sh\necho 1\n' > "$OPS/probes/p.sh"

# Pitch 31: ready. Pitch 33: no filer block. Pitch 34: probe not in ops.
cat > "$WORK/p31.md" <<'EOF'
# Sprint: gate-ready pitch

## What this enables
A pitch the gate can merge today.

<!-- sprint:begin -->
class: internal
effect: probes/p.sh
soak: 7d
<!-- sprint:end -->

<!-- filer:begin -->
- id: a
  title: "the sub-issue"
  labels: [backlog]
  depends_on: []
  body: |
    ## Problem
    The gate must merge this pitch.
<!-- filer:end -->
EOF
cat > "$WORK/p33.md" <<'EOF'
# Sprint: no sub-issues

## What this enables
Nothing is drafted yet.

<!-- sprint:begin -->
class: internal
effect: none
soak: 7d
<!-- sprint:end -->
EOF
cat > "$WORK/p34.md" <<'EOF'
# Sprint: missing probe

## What this enables
Its effect probe is not in the ops repo.

<!-- sprint:begin -->
class: deploy
effect: probes/missing.sh
soak: 7d
<!-- sprint:end -->

<!-- filer:begin -->
- id: b
  title: "the drafted sub-issue"
  labels: [backlog]
  depends_on: []
  body: |
    ## Problem
    The probe is missing.
<!-- filer:end -->
EOF

STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/curl" <<'PITCH_APPROVE_STUB'
#!/usr/bin/env bash
# Fake ops forge: open pulls 31-34, heads, file lists, and merge POSTs.
# Records every call as METHOD|URL|BODY in $AC_APPROVE_LOG.
# AC_MERGE_FAIL=1 makes */pulls/*/merge exit 22 (the failed-merge seam).
set -euo pipefail
method="GET" body="" url="" last=""
for a in "$@"; do
  if [ "$last" = "-X" ]; then
    method="$a"
  elif [ "$last" = "-d" ] || [ "$last" = "--data" ]; then
    body="$a"
  fi
  case "$a" in
    http*|https*) url="$a" ;;
  esac
  last="$a"
done
printf '%s|%s|%s\n' "$method" "$url" "$body" >> "${AC_APPROVE_LOG:?}"
case "$url" in
  *'/pulls?state=open'*'page=1')
    printf '%s\n' '[{"number":31,"title":"gate-ready pitch","html_url":"https://forge.example/o/ops/pulls/31","user":{"login":"planner-bot"}},{"number":32,"title":"owner pitch","html_url":"https://forge.example/o/ops/pulls/32","user":{"login":"disinto-admin"}},{"number":33,"title":"no sub-issues","html_url":"https://forge.example/o/ops/pulls/33","user":{"login":"planner-bot"}},{"number":34,"title":"no probe","html_url":"https://forge.example/o/ops/pulls/34","user":{"login":"planner-bot"}}]'
    ;;
  *'/pulls?state=open'*)
    printf '%s\n' '[]'
    ;;
  *'/pulls/31/files'*)
    printf '%s\n' '[{"filename":"sprints/x.md","status":"added"}]'
    ;;
  *'/pulls/32/files'*)
    printf '%s\n' '[{"filename":"sprints/y.md","status":"added"}]'
    ;;
  *'/pulls/33/files'*)
    printf '%s\n' '[{"filename":"sprints/z.md","status":"added"}]'
    ;;
  *'/pulls/34/files'*)
    printf '%s\n' '[{"filename":"sprints/w.md","status":"added"}]'
    ;;
  *'/pulls/31/merge')
    if [ "${AC_MERGE_FAIL:-}" = "1" ]; then
      exit 22
    fi
    printf '{"Done":true}'
    ;;
  *'/pulls/31')
    printf '{"number":31,"head":{"ref":"pitch-x"}}'
    ;;
  *'/pulls/33')
    printf '{"number":33,"head":{"ref":"pitch-z"}}'
    ;;
  *'/pulls/34')
    printf '{"number":34,"head":{"ref":"pitch-w"}}'
    ;;
  *'/contents/sprints/x.md'*)
    printf '{"sha":"sha-x","content":"%s"}' "$(base64 < "${AC_PITCH_31:?}" | tr -d '\n')"
    ;;
  *'/contents/sprints/z.md'*)
    printf '{"sha":"sha-z","content":"%s"}' "$(base64 < "${AC_PITCH_33:?}" | tr -d '\n')"
    ;;
  *'/contents/sprints/w.md'*)
    printf '{"sha":"sha-w","content":"%s"}' "$(base64 < "${AC_PITCH_34:?}" | tr -d '\n')"
    ;;
  *)
    exit 22
    ;;
esac
PITCH_APPROVE_STUB
chmod +x "$STUB_BIN/curl"

# Lint and classify seams.
cat > "$WORK/pitch-lint" <<'EOF'
#!/usr/bin/env bash
exit "${LINT_RC:-0}"
EOF
chmod +x "$WORK/pitch-lint"
cat > "$WORK/classify" <<'EOF'
#!/usr/bin/env bash
printf 'medium\n'
EOF
chmod +x "$WORK/classify"

AC_LOG="$WORK/calls.txt"
export AC_APPROVE_LOG="$AC_LOG"
export AC_PITCH_31="$WORK/p31.md"
export AC_PITCH_33="$WORK/p33.md"
export AC_PITCH_34="$WORK/p34.md"
export PATH="$STUB_BIN:$PATH"
export FORGE_API_BASE="https://forge.example/api/v1"
export FORGE_OPS_REPO="o/ops"
export FORGE_TOKEN="stub"
export OPS_REPO_ROOT="$OPS"
export FORGE_BOT_USERNAMES="planner-bot,gardener-bot,architect-bot,filer-bot"
export PITCH_LINT="$WORK/pitch-lint"
export CLASSIFY="$WORK/classify"

TOOL="$REPO_ROOT/tools/pitch-approve.sh"

# run_approve TAPE NOTICES LINT_RC [MERGE_FAIL] — one hermetic run.
run_approve() {
  : > "$AC_LOG"
  RC=0
  TAPE_DIR="$1" NOTICES_DIR="$2" LINT_RC="$3" AC_MERGE_FAIL="${4:-0}" \
    bash "$TOOL" >"$WORK/stdout" 2>"$WORK/stderr" || RC=$?
  OUT="$(cat "$WORK/stdout")"
  ERR="$(cat "$WORK/stderr")"
}

notice_count() {
  local n=0 f
  for f in "$1"/*.txt; do
    [ -f "$f" ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# ── AC1: PR 31 is merged, marked, and the owner is told ──────────────────────
ac_log "AC1: ready pitch 31 — POST /pulls/31/merge with {\"Do\":\"merge\"}, one notice, gate marker"
TAPE1="$WORK/tape1"
NOTICES1="$WORK/notices1"
run_approve "$TAPE1" "$NOTICES1" 0
ac_assert_eq "$RC" "0" "a run that merges 31 and skips the rest must return 0 (got $RC): $ERR"
ac_assert_eq "$(grep -cF 'POST|https://forge.example/api/v1/repos/o/ops/pulls/31/merge|{"Do":"merge"}' "$AC_LOG")" "1" \
  "the gate must POST /pulls/31/merge with {\"Do\":\"merge\"} (calls: $(cat "$AC_LOG"))"
if grep -qE 'POST\|[^|]*pulls/(32|33|34)/merge' "$AC_LOG"; then
  ac_fail "PRs 32, 33 and 34 must never be merged (calls: $(cat "$AC_LOG"))"
fi
ac_assert_eq "$(notice_count "$NOTICES1")" "1" "exactly one notice must be queued (got $(notice_count "$NOTICES1"))"
notice="$(cat "$NOTICES1"/*.txt)"
case "$notice" in
  *'#31'*) ;;
  *) ac_fail "the notice must name #31 (got: $notice)" ;;
esac
case "$notice" in
  *medium*) ;;
  *) ac_fail "the notice must name the tier medium (got: $notice)" ;;
esac
case "$notice" in
  *'/pulls/31'*) ;;
  *) ac_fail "the notice must carry the html_url (got: $notice)" ;;
esac
[ -e "$TAPE1/gate/pr-31" ] || ac_fail "the marker gate/pr-31 must exist after the merge"
for n in 32 33 34; do
  if [ -e "$TAPE1/gate/pr-${n}" ]; then
    ac_fail "gate/pr-${n} must not exist: unmerged PRs get no marker"
  fi
done
printf '%s' "$ERR" | grep -qF 'no filer block' \
  || ac_fail "PR 33 must log its missing filer block (stderr: $ERR)"
printf '%s' "$ERR" | grep -qF 'probe' \
  || ac_fail "PR 34 must log its missing probe (stderr: $ERR)"
ac_assert_eq "$OUT" "" "stdout must stay empty (got: $OUT)"
ac_log "AC1 OK"

# ── AC2: a second run makes no merge call ────────────────────────────────────
ac_log "AC2: the gate/pr-31 marker means the second run never POSTs merge"
run_approve "$TAPE1" "$NOTICES1" 0
ac_assert_eq "$RC" "0" "the second run must return 0 (got $RC): $ERR"
if grep -qE 'POST\|[^|]*pulls/31/merge' "$AC_LOG"; then
  ac_fail "the second run must make no merge call (calls: $(cat "$AC_LOG"))"
fi
ac_assert_eq "$(notice_count "$NOTICES1")" "1" "the second run must not queue another notice"
ac_log "AC2 OK"

# ── AC3: lint failing (LINT_RC=1) — no merge, no marker ──────────────────────
ac_log "AC3: LINT_RC=1 — pitch 31 is not merged and gets no marker"
TAPE2="$WORK/tape2"
run_approve "$TAPE2" "$WORK/notices2" 1
ac_assert_eq "$RC" "0" "an unready pitch is not a failure (got $RC): $ERR"
if grep -qE 'POST\|[^|]*pulls/[0-9]+/merge' "$AC_LOG"; then
  ac_fail "a failing lint must stop every merge (calls: $(cat "$AC_LOG"))"
fi
[ ! -e "$TAPE2/gate/pr-31" ] || ac_fail "gate/pr-31 must not exist when the lint fails"
printf '%s' "$ERR" | grep -qF 'pitch-lint' \
  || ac_fail "the lint log line must name pitch-lint (stderr: $ERR)"
ac_log "AC3 OK"

# ── AC4: the merge call fails — no marker, rc 1 ──────────────────────────────
ac_log "AC4: a failing merge POST — no marker, the tool exits 1"
TAPE3="$WORK/tape3"
NOTICES3="$WORK/notices3"
run_approve "$TAPE3" "$NOTICES3" 0 1
ac_assert_eq "$RC" "1" "a failed merge must make the run exit 1 (got $RC): $ERR"
ac_assert_eq "$(grep -cF '/pulls/31/merge' "$AC_LOG")" "1" "the merge attempt must still have been POSTed"
[ ! -e "$TAPE3/gate/pr-31" ] || ac_fail "a failed merge must leave no marker"
ac_assert_eq "$(notice_count "$NOTICES3")" "0" "a failed merge must queue no notice"
printf '%s' "$ERR" | grep -qF 'merge failed' \
  || ac_fail "the merge failure must be warned about (stderr: $ERR)"
ac_log "AC4 OK"

ac_pass
