#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1948.sh — the snapshot collectors no longer leak
# temp files created inside command substitutions
#
# Issue #1948: the collectors leaked every temp file made inside $(…). The fix
# (lib/snapshot-tmp.sh) gives each collector a private per-run directory
# (SNAPSHOT_RUN_DIR) created at source time by the parent shell. mktemp_safe
# with no argument, or a /tmp/ template, lands in that directory; cleanup()
# removes it whole (rm -rf) so subshell-created files are reaped too. Files
# that must live next to their destination (${SNAPSHOT_PATH}.<name>.XXXXXX)
# keep the old behaviour (created at that path, tracked in TMPFILES).
#
# Hermetic: no network. The collectors run against a curl stub. TMPDIR is a
# fresh empty dir; we assert it's untouched (no new files) after each collector.
#
# Run via: tools/run-acceptance.sh 1948
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq grep mktemp date

LIB="$REPO_ROOT/lib/snapshot-tmp.sh"
FORGE="$REPO_ROOT/bin/snapshot-forge.sh"
INBOX="$REPO_ROOT/bin/snapshot-inbox.sh"
ac_assert_file "$LIB" "lib/snapshot-tmp.sh must exist"
ac_assert_file "$FORGE" "bin/snapshot-forge.sh must exist"
ac_assert_file "$INBOX" "bin/snapshot-inbox.sh must exist"

# Outer work dir (NOT the TMPDIR under test).
WORK="$(mktemp -d)"
# TMPDIR_DIR: the /tmp dir we assert stays clean after the collectors run.
TMPDIR_DIR="$(mktemp -d)"
# NONTMP_BASE: a NON-/tmp base for dirs that must NOT be /tmp/ paths.
#   - AC3's state dir: the SNAPSHOT_PATH case (file lives next to destination).
#   - AC4's SNAPSHOT_PATH: the collectors' state file + same-fs scratch, which
#     in production is a persistent, non-/tmp location.
NONTMP_BASE="$(mktemp -d "${HOME:-/root}/snapshot-1948.XXXXXX" 2>/dev/null)"
if [ -z "$NONTMP_BASE" ]; then
  NONTMP_BASE="${HOME:-/root}/snapshot-1948.$$"
  mkdir -p "$NONTMP_BASE"
fi
REPORT="$WORK/report.txt"
: > "$REPORT"
trap 'rm -rf "$WORK" "$TMPDIR_DIR" "$NONTMP_BASE"' EXIT

mkdir -p "$WORK/bin"

# ── AC4 helper: curl stub for the forge+inbox collectors ──────────────────────
# Honours -o (writes the body) and prints the HTTP code to stdout (as
# `curl -w '%{http_code}'` would) so forge_get's http_code check passes.
# Keys on the URL:
#   *type=issues&state=open* -> labelled issue array (id 2 = backlog, 6 = in-progress)
#   *type=pulls&state=open*  -> an open PR array
#   *pulls/*/reviews          -> a review array
#   *pulls/*/status           -> a commit-status object
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
n=${#args[@]}
out="" url=""
i=0
while [ "$i" -lt "$n" ]; do
  a="${args[$i]}"
  case "$a" in
    -o)
      [ $((i+1)) -lt "$n" ] && out="${args[$((i+1))]}"
      i=$((i+1))
      ;;
    -D) i=$((i+1)) ;;
    http://*|https://*) url="$a" ;;
  esac
  i=$((i+1))
done
body=""
case "${url:-}" in
  *pulls/*/reviews)
    body='[{"state":"APPROVED","stale":false}]'
    ;;
  *pulls/*/status)
    body='{"state":"success"}'
    ;;
  *type=issues*)
    body='[
      {"number":1,"title":"backlog one","labels":[{"id":2}],"created_at":"2024-01-01T00:00:00Z"},
      {"number":2,"title":"in progress","labels":[{"id":6}],"created_at":"2024-01-02T00:00:00Z"},
      {"number":3,"title":"unlabeled","labels":[],"created_at":"2024-01-03T00:00:00Z"}
    ]'
    ;;
  *type=pulls*)
    body='[{"number":1,"title":"pr one","merged":false,"created_at":"2024-01-01T00:00:00Z"}]'
    ;;
  *)
    printf 'fake-curl: no fixture for %s\n' "${url:-<none>}" >&2
    exit 22
    ;;
esac
[ -n "$out" ] && printf '%s' "$body" > "$out"
printf '200'
exit 0
EOF
chmod +x "$WORK/bin/curl"

# State files (outside /tmp) + state.json stub. SNAPSHOT_PATH must NOT be a
# /tmp/ path so its ${SNAPSHOT_PATH}.<name>.XXXXXX scratch files are created
# next to it (the real production behaviour), not redirected into the run dir.
DATA_DIR="$NONTMP_BASE/data"
mkdir -p "$DATA_DIR"
SNAPSHOT_PATH="$DATA_DIR/state.json"
printf '%s\n' '{"version":1,"ts":"2024-01-01T00:00:00Z","collectors":{}}' > "$SNAPSHOT_PATH"

# ── AC1/AC2: a collector-shaped script whose temp files are made in $(…) ────

cat > "$WORK/inner.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# LIB and REPORT are exported by the outer test; TMPDIR is set to the test dir.
source "$LIB"
trap cleanup EXIT

fetch() {
  local f1 f2
  mktemp_safe /tmp/x.XXXXXX
  f1="${SNAPSHOT_RUN_DIR}/$(basename "$_TMPFILE")"
  [ -f "$f1" ] || return 1
  mktemp_safe
  f2="${SNAPSHOT_RUN_DIR}/$(basename "$_TMPFILE")"
  [ -f "$f2" ] || return 1
  {
    echo "run_dir=$SNAPSHOT_RUN_DIR"
    echo "file1=$f1"
    echo "file2=$f2"
  } >> "$REPORT"
}

# The leak case: temp files created inside a command substitution.
out="$(fetch)"
EOF
chmod +x "$WORK/inner.sh"

ac_log "AC1: inner script (source lib, trap cleanup, mktemp_safe in \$()) leaves TMPDIR empty"

export LIB="$LIB"
export REPORT="$REPORT"
export TMPDIR="$TMPDIR_DIR"
INNER_RC=0
bash "$WORK/inner.sh" 2>>"$WORK/inner.stderr" || INNER_RC=$?

if [ "$INNER_RC" -ne 0 ]; then
  ac_fail "inner script exited $INNER_RC (see $WORK/inner.stderr)"
fi

# TMPDIR_DIR must be empty: run dir + its files all reaped by cleanup.
leftover="$(ls -A "$TMPDIR_DIR" | wc -l)"
ac_assert_eq "$leftover" "0" \
  "TMPDIR must be empty after the script exits (leftover count=$leftover)"

# AC2: during execution the files were inside $SNAPSHOT_RUN_DIR, not loose in /tmp.
if ! grep -q '^run_dir=' "$REPORT"; then
  ac_fail "AC2: report missing run_dir line"
fi
if ! grep -q '^file1=' "$REPORT"; then
  ac_fail "AC2: report missing file1 line"
fi
if ! grep -q '^file2=' "$REPORT"; then
  ac_fail "AC2: report missing file2 line"
fi
run_dir="$(grep '^run_dir=' "$REPORT" | sed 's/^run_dir=//')"
f1="$(grep '^file1=' "$REPORT" | sed 's/^file1=//')"
f2="$(grep '^file2=' "$REPORT" | sed 's/^file2=//')"
case "$f1" in "$run_dir"/*) ;; *) ac_fail "AC2: file1 ($f1) not under run_dir ($run_dir)" ;; esac
case "$f2" in "$run_dir"/*) ;; *) ac_fail "AC2: file2 ($f2) not under run_dir ($run_dir)" ;; esac
case "$run_dir" in "$TMPDIR_DIR"/*) ;; *) ac_fail "AC2: run_dir ($run_dir) not under TMPDIR ($TMPDIR_DIR)" ;; esac

# ── AC3: a non-/tmp template is created in its dir and reaped ────────────────

cat > "$WORK/inner3.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# REPORT exported by the outer test.
source "$LIB"
trap cleanup EXIT

state_dir="$INNER3_DIR"
mktemp_safe "$state_dir/state.json.XXXXXX"
file="$_TMPFILE"
[ -f "$file" ] || exit 1
printf 'state_file=%s\n' "$file" >> "$REPORT"
EOF
chmod +x "$WORK/inner3.sh"

ac_log "AC3: mktemp_safe \"\$dir/state.json.XXXXXX\" (dir outside /tmp) creates in \$dir; cleanup removes it"

INNER3_DIR="$NONTMP_BASE/state-dir"
mkdir -p "$INNER3_DIR"
export INNER3_DIR="$INNER3_DIR"
INNER_RC3=0
bash "$WORK/inner3.sh" || INNER_RC3=$?
if [ "$INNER_RC3" -ne 0 ]; then
  ac_fail "AC3: inner3 script exited $INNER_RC3"
fi
state_file="$(grep '^state_file=' "$REPORT" | sed 's/^state_file=//')"
case "$state_file" in "$INNER3_DIR"/*) ;; *) ac_fail "AC3: state file ($state_file) not under $INNER3_DIR" ;; esac
if [ -e "$state_file" ]; then
  ac_fail "AC3: state file ($state_file) not removed by cleanup"
fi

# ── AC4: the real collectors against the curl stub leave TMPDIR untouched ────

ac_log "AC4: snapshot-forge.sh leaves TMPDIR untouched"

export PATH="$WORK/bin:$PATH"
export SNAPSHOT_PATH="$SNAPSHOT_PATH"
export FACTORY_FORGE_PAT="stub-pat"
export FORGE_URL="http://localhost:3000"
export FORGE_REPO="disinto-admin/disinto"
export FORGE_TIMEOUT=3
export FORGE_ETAG_PATH="$WORK/forge.etag"   # keep the real /tmp pristine

FORGE_BEFORE="$(ls -A "$TMPDIR_DIR" | wc -l)"
bash "$FORGE" 2>>"$WORK/forge.stderr" || ac_fail "snapshot-forge.sh failed"
FORGE_AFTER="$(ls -A "$TMPDIR_DIR" | wc -l)"
ac_assert_eq "$FORGE_AFTER" "$FORGE_BEFORE" \
  "snapshot-forge.sh left new files in TMPDIR ($FORGE_BEFORE -> $FORGE_AFTER)"

jq -e '.collectors.forge.backlog_count == 1' "$SNAPSHOT_PATH" \
  || ac_fail "snapshot-forge.sh did not merge forge data (backlog_count=1 expected)"

# inbox collector.
ac_log "AC4: snapshot-inbox.sh leaves TMPDIR untouched"

INBOX_ROOT="$WORK/inbox"
mkdir -p "$INBOX_ROOT"
VAULT_DIR="$WORK/action-vault"
mkdir -p "$VAULT_DIR"
printf 'formula=sprint\n' > "$VAULT_DIR/sprint-draft.toml"

export INBOX_ROOT="$INBOX_ROOT"
export VAULT_DIR="$VAULT_DIR"

INBOX_BEFORE="$(ls -A "$TMPDIR_DIR" | wc -l)"
bash "$INBOX" 2>>"$WORK/inbox.stderr" || ac_fail "snapshot-inbox.sh failed"
INBOX_AFTER="$(ls -A "$TMPDIR_DIR" | wc -l)"
ac_assert_eq "$INBOX_AFTER" "$INBOX_BEFORE" \
  "snapshot-inbox.sh left new files in TMPDIR ($INBOX_BEFORE -> $INBOX_AFTER)"

jq -e '.collectors.inbox.total_count == null or .collectors.inbox.total_count >= 0' "$SNAPSHOT_PATH" \
  || ac_fail "snapshot-inbox.sh did not merge inbox data into state.json"

echo PASS
