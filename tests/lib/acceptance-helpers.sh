#!/usr/bin/env bash
# =============================================================================
# tests/lib/acceptance-helpers.sh — shared utilities for acceptance tests
#
# Sourced by tests/acceptance/issue-<N>.sh. Provides curl wrappers for forge +
# nomad HTTP APIs, jq assertion helpers, log-format helpers, and in-process
# stub helpers (ac_extract_fn / ac_has_call_matching) for tests that extract
# decision functions from top-level executables.
#
# Conventions:
#   - All helpers are read-only. They never POST, PUT, DELETE, or otherwise
#     mutate state. (Reviewer-agent rejects mutating acceptance tests.)
#   - Failures call `ac_fail "<reason>"` which prints `FAIL: <reason>` and
#     exits 1 — matching the contract that the last line of stdout is PASS or
#     FAIL: <reason>.
#   - All helpers respect the env loaded by tools/run-acceptance.sh (FORGE_URL,
#     NOMAD_ADDR, FACTORY_FORGE_PAT, NOMAD_TOKEN, etc.). When run outside the
#     runner, the operator must export these before sourcing.
# =============================================================================

# Idempotent guard — a test that sources the helpers twice (e.g. via nested
# sourcing) shouldn't redefine functions or re-run setup.
if [ -n "${ACCEPTANCE_HELPERS_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
ACCEPTANCE_HELPERS_LOADED=1

# ── Output helpers ───────────────────────────────────────────────────────────

# ac_log <msg> — human-readable progress to stdout.
ac_log() {
  echo ":: $*"
}

# ac_warn <msg> — warning to stderr (non-fatal).
ac_warn() {
  echo "WARN: $*" >&2
}

# ac_fail <reason> — print `FAIL: <reason>` and exit 1.
ac_fail() {
  echo "FAIL: $*"
  exit 1
}

# ac_pass — print PASS and exit 0. Optional in tests that want to be explicit.
ac_pass() {
  echo PASS
  exit 0
}

# ── Pre-flight ───────────────────────────────────────────────────────────────

# ac_require_cmd <cmd>... — fail if any command is missing.
ac_require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 \
      || ac_fail "required command not on PATH: $cmd"
  done
}

# ac_require_env <var>... — fail if any env var is unset or empty.
ac_require_env() {
  local var
  for var in "$@"; do
    if [ -z "${!var:-}" ]; then
      ac_fail "required env var not set: $var (run via tools/run-acceptance.sh or source /etc/disinto/acceptance.env)"
    fi
  done
}

# ── HTTP wrappers ────────────────────────────────────────────────────────────

# ac_forge_api <path> [curl-args...] — GET against $FORGE_URL/api/v1/<path>.
# Authenticates with $FACTORY_FORGE_PAT if set. Echoes the response body to
# stdout; returns curl's exit code (so callers can chain `|| ac_fail ...`).
ac_forge_api() {
  local path="$1"; shift
  ac_require_env FORGE_URL
  local url="${FORGE_URL%/}/api/v1/${path#/}"
  local auth=()
  if [ -n "${FACTORY_FORGE_PAT:-}" ]; then
    auth=(-H "Authorization: token $FACTORY_FORGE_PAT")
  fi
  curl -sf "${auth[@]}" "$@" "$url"
}

# ac_nomad_api <path> [curl-args...] — GET against $NOMAD_ADDR/v1/<path>.
# Authenticates with X-Nomad-Token if $NOMAD_TOKEN is set.
ac_nomad_api() {
  local path="$1"; shift
  ac_require_env NOMAD_ADDR
  local url="${NOMAD_ADDR%/}/v1/${path#/}"
  local auth=()
  if [ -n "${NOMAD_TOKEN:-}" ]; then
    auth=(-H "X-Nomad-Token: $NOMAD_TOKEN")
  fi
  curl -sf "${auth[@]}" "$@" "$url"
}

# ── jq assertion helpers ────────────────────────────────────────────────────

# ac_assert_jq <expr> <json-string> [reason] — fail if `jq -e <expr>` against
# the given JSON returns false/null/empty. Reason is appended to FAIL message.
ac_assert_jq() {
  local expr="$1"
  local json="$2"
  local reason="${3:-jq assertion failed: $expr}"
  echo "$json" | jq -e "$expr" >/dev/null 2>&1 \
    || ac_fail "$reason"
}

# ac_assert_eq <actual> <expected> [reason] — string equality assertion.
ac_assert_eq() {
  local actual="$1"
  local expected="$2"
  local reason="${3:-expected '$expected', got '$actual'}"
  [ "$actual" = "$expected" ] || ac_fail "$reason"
}

# ac_assert_file <path> [reason] — file exists and is readable.
ac_assert_file() {
  local path="$1"
  local reason="${2:-expected file not found or not readable: $path}"
  [ -r "$path" ] || ac_fail "$reason"
}

# ── In-process stub helpers ─────────────────────────────────────────────────
# For acceptance tests that extract decision functions from top-level
# executables (which cannot be sourced without running the whole script) and
# stub the mutating calls into a global CALLS array to assert which fired.

# ac_extract_fn <name> <file> — print the source of `name()` from the script
# in <file>: from the column-0 `name() {` header to the next column-0
# closing brace.
ac_extract_fn() {
  local fn="$1" file="$2"
  awk -v fn="$fn" '
    $0 ~ "^" fn "\\(\\) " { in_fn = 1; print; next }
    in_fn && /^\}/ { print; exit }
    in_fn { print }
  ' "$file"
}

# ac_pick_in_subshell <fn-source> <fn-name> — run the function given by
# <fn-source> (usually from ac_extract_fn) in a throwaway subshell with a
# fixed fake FACTORY_ROOT, then invoke <fn-name>. Prints the function's
# stdout (e.g. the selected formula path) or the subshell's error text.
# Shared by the formula-selection tests (issue-1334.sh, issue-1335.sh,
# issue-1336.sh).
ac_pick_in_subshell() {
  local fn_src="$1" fn_name="$2"
  PICK_FN="$fn_src" PICK_CALL="$fn_name" bash -c '
    set -u
    FACTORY_ROOT=/srv/disinto
    eval "$PICK_FN"
    "$PICK_CALL"
  ' 2>&1
}

# ac_has_call_matching <pattern> — return 0 if any element of the test's
# global CALLS array contains <pattern> as a substring.
# shellcheck disable=SC2154  # CALLS is defined by the sourcing test
ac_has_call_matching() {
  local c
  for c in "${CALLS[@]}"; do
    case "$c" in
      *"$1"*) return 0 ;;
    esac
  done
  return 1
}

# ── Hermetic forge stub (shared by the tape-emitter extraction tests) ───────
# tests/acceptance/issue-1398.sh (emit_tape_proposal) and issue-1399.sh
# (emit_tape_outcome) extract their function from the top-level executable and
# run it in a subshell against a fake forge — no network, no live services.
# These helpers build that environment. (issue-1409.sh was deleted by #1476,
# which removed emit_planner_proposal from planner-run.sh; the planner tick is
# now a no-op stub verified by issue-1476.sh.)

# ac_write_curl_stub <STUB_BIN> — write a hermetic curl stub (a fake forge
# API) to <STUB_BIN>/curl and chmod +x it. The stub keys on its last
# argument (the URL):
#   */issues/*          → {"labels":[{"name":"backlog"},{"name":"priority"}]}
#   */pulls?state=open* → [{"number":1},{"number":2},{"number":3}]
#   */pulls/*/reviews   → 4 reviews, 2 of them REQUEST_CHANGES
#   anything else       → exit 22 (like an unreachable API)
# AC_STUB_FAIL=1 makes every call fail with exit 22 (degradation tests).
ac_write_curl_stub() {
  local stub_bin="$1"
  cat > "${stub_bin}/curl" <<'AC_CURL_STUB'
#!/usr/bin/env bash
# Fake forge API — last arg is the URL. AC_STUB_FAIL=1 forces failure.
url="$*"
if [ -n "${AC_STUB_FAIL:-}" ]; then
  exit 22
fi
case "$url" in
  */issues/*)
    echo '{"labels":[{"name":"backlog"},{"name":"priority"}]}'
    ;;
  *'/pulls?state=open'*)
    echo '[{"number":1},{"number":2},{"number":3}]'
    ;;
  *'/pulls/'*'/reviews')
    echo '[{"state":"APPROVED","stale":false},{"state":"REQUEST_CHANGES","stale":true},{"state":"REQUEST_CHANGES","stale":false},{"state":"COMMENT"}]'
    ;;
  *)
    exit 22
    ;;
esac
AC_CURL_STUB
  chmod +x "${stub_bin}/curl"
}

# ac_stub_env <STUB_BIN> <TAPE_DIR> — configure the calling subshell to run
# an extracted tape emitter against the ac_write_curl_stub fake: stub curl
# first on PATH, sentinel API/FORGE_TOKEN, the caller's TAPE_DIR, and the
# inherited PROJECT_NAME (the test's sentinel). The subshell also inherits
# the test's top-level log() stand-in, so the emitter's log lines land in
# the runner's captured output.
ac_stub_env() {
  export PATH="$1:$PATH"
  export API="https://forge.example/api/v1"
  export FORGE_TOKEN="stub-token"
  export TAPE_DIR="$2"
  export PROJECT_NAME
}

# ac_stub_bin_and_log <STUB_BIN> — write the hermetic curl stub to <STUB_BIN>
# (ac_write_curl_stub), create it, and define a top-level log() stand-in so
# the extracted emitter's poll lines reach the runner's captured output. The
# run subshells inherit both; STUB_BIN is set as a global for the test's
# ac_stub_env() call.
ac_stub_bin_and_log() {
  local stub_bin="$1"
  STUB_BIN="$stub_bin"
  mkdir -p "$STUB_BIN"
  ac_write_curl_stub "$STUB_BIN"
  # shellcheck disable=SC2317
  log() { echo "poll: $*"; }
}

# ac_run_tape_emit <STUB_BIN> <TAPE_DIR> <FN_SRC> <fail> <fn-name> [args...]
# — run the extracted tape emitter given by <FN_SRC> (usually from
# ac_extract_fn) in a throwaway subshell: the ac_write_curl_stub fake curl
# first on PATH, the ac_stub_env sentinels plus a sentinel FORGE_API, the
# real lib/tape.sh, and the test's top-level log() stand-in (inherited).
# <fail>=1 makes the stub curl fail like an unreachable API (AC_STUB_FAIL=1).
# Prints the subshell's combined output; the exit status is the emitter's.
# Shared by the tape-emitter extraction tests (issue-1398.sh, issue-1399.sh).
ac_run_tape_emit() {
  local stub_bin="$1" tape_dir="$2" fn_src="$3" fail="$4" fn_name="$5"
  shift 5
  (
    ac_stub_env "$stub_bin" "$tape_dir"
    export FORGE_API="https://forge.example/api/v1"
    # shellcheck disable=SC1090,SC1091
    source "$REPO_ROOT/lib/tape.sh"
    eval "$fn_src"
    if [ "$fail" = "1" ]; then
      export AC_STUB_FAIL=1
    fi
    "$fn_name" "$@"
  ) 2>&1
}

# ac_tape_emitter_wiring <target-file> <fn-name> <call-text> — assert a tape
# emitter is wired into a top-level executable: <target-file> exists, sources
# lib/tape.sh, and contains the literal call <call-text> (e.g.
# 'emit_tape_proposal "$READY_ISSUE"'), then extract and print <fn-name>()'s
# source to stdout for use as the extracted function. It also pre-flights
# awk/jq (awk is used by the extraction, jq by the caller's assertions) so a
# missing dependency fails fast before any tape work. Shared by the per-issue
# tape-emitter acceptance tests that exercise the same dev-poll emitter, so the
# wiring checks are not copy-pasted file-into-file (duplicate-detection).
ac_tape_emitter_wiring() {
  local target="$1" fn="$2" call="$3"
  ac_require_cmd awk jq
  local base="${target##*/}"
  ac_assert_file "$target" "${base} must exist"
  grep -q '^source .*lib/tape\.sh' "$target" \
    || ac_fail "${base} must source lib/tape.sh"
  grep -qF -- "$call" "$target" \
    || ac_fail "${base} must call ${fn} for the picked issue"
  local src
  src="$(ac_extract_fn "$fn" "$target")" || true
  [ -n "$src" ] || ac_fail "could not extract ${fn}() from ${base}"
  printf '%s\n' "$src"
}

# ac_assert_repick <rc> <out> — the re-pick guard (#1441) returns 0 and logs
# that the existing id is reused. Used by the re-pick checks in issue-1441 and
# issue-1451 so the identical case block is not duplicated file-into-file
# (duplicate-detection).
ac_assert_repick() {
  local rc="$1" out="$2"
  ac_assert_eq "$rc" "0" "re-pick must return 0 (got $rc): $out"
  case "$out" in
    *"reusing existing proposal id"*) ;;
    *) ac_fail "re-pick must log that the existing id is reused, got: $out" ;;
  esac
}

# ac_run_empty_tape <dir> <tool> — prepare <dir> with an empty tape.jsonl
# (mkdir -p, truncate), run <tool> with TAPE_DIR set, and store the exit
# status in the global rc and stdout in the global out. Shared by the
# empty-tape acceptance ACs (issue-1453.sh, issue-1473.sh) so the identical
# fixture + run lines are not duplicated file-to-file (duplicate-detection).
ac_run_empty_tape() {
  local d="$1" t="$2"
  mkdir -p "$d"
  : > "$d/tape.jsonl"
  rc=0
  out="$(TAPE_DIR="$d" bash "$t")" || rc=$?
}

# ac_run_tape_tool <dir-name> <write-fn> <tool> — prepare a tape dir
# $TMP_DIR/<dir-name> (mkdir -p), write it via the function named in
# <write-fn>, run <tool> with TAPE_DIR set, and store the exit status in the
# global rc and the combined stdout in the global out. The global TC_DIR is
# also set to the tape dir for callers that need it. Shared by the calibration
# acceptance ACs (issue-1473.sh, issue-1526.sh) so the `TC_DIR/mkdir/write` +
# run + rc lines are not duplicated file-to-file (duplicate-detection).
ac_run_tape_tool() {
  local dir_name="$1" write_fn="$2" tool="$3"
  TC_DIR="$TMP_DIR/$dir_name"
  mkdir -p "$TC_DIR"
  "$write_fn" "$TC_DIR"
  rc=0
  out="$(TAPE_DIR="$TC_DIR" bash "$tool")" || rc=$?
}

# ac_run_bats_suite <suite-path> — run a bats suite, storing the exit status in
# the global bats_rc and the combined stdout/stderr in the global bats_out.
# Returns 0 so set -e callers are not aborted before the asserting
# `ac_assert_eq "$bats_rc" "0" ...` line can print the FAIL message. Shared by
# the calibration acceptance ACs (issue-1453.sh, issue-1454.sh, issue-1473.sh,
# issue-1526.sh) so the identical `bats` invocation + rc capture is not
# duplicated file-to-file (duplicate-detection).
ac_run_bats_suite() {
  local suite="$1"
  bats_rc=0
  # shellcheck disable=SC2034  # bats_out/bats_rc are consumed by the calling acceptance script
  bats_out="$(bats "$suite" 2>&1)" || bats_rc=$?
}

# ── Edge-control ledger fixtures (edge-verb acceptance tests) ────────────────
# The edge verbs read a throwaway $ACCOUNTS_FILE that each test sets up in an
# mktemp dir (never /var/lib/disinto). These are the single definition of the
# fixture building blocks shared by issue-1467.sh and issue-1468.sh
# (duplicate-detection: each test file would otherwise carry its own copy).
# seed_row() rewrites only the calling test's own $ACCOUNTS_FILE — it never
# POSTs and never touches a live service.

# Canonical 43-char fixture fingerprints: "SHA256:" + exactly 43 base64url
# chars.
FP_A="SHA256:$(printf 'A%.0s' {1..43})"
FP_B="SHA256:$(printf 'B%.0s' {1..43})"
FP_ADMIN="SHA256:$(printf 'C%.0s' {1..43})"
# Validate every constant up front (catches construction typos at source time
# before any acceptance test relies on them).
[[ "$FP_A" =~ ^SHA256:[A-Za-z0-9_-]{43}$ ]] \
  || ac_fail "test fixture fingerprint is malformed: $FP_A"
[[ "$FP_B" =~ ^SHA256:[A-Za-z0-9_-]{43}$ ]] \
  || ac_fail "test fixture fingerprint is malformed: $FP_B"
[[ "$FP_ADMIN" =~ ^SHA256:[A-Za-z0-9_-]{43}$ ]] \
  || ac_fail "test fixture fingerprint is malformed: $FP_ADMIN"

# seed_row <fp> [name] [admin] [credits=0]
# Write a row for <fp> into $ACCOUNTS_FILE in the same shape dispatch.sh +
# account_ensure emit: status=pending, name "" means no bound name, admin
# "true"/"false", credits default 0. <fp> should be one of FP_A/FP_B/FP_ADMIN
# (validated upstream by FINGERPRINT_RE).
seed_row() {
  local fp="$1" name="$2" admin="$3" credits="${4:-0}"
  local tmpfile
  tmpfile="$ACCOUNTS_FILE.tmp"
  jq --arg fp "$fp" --arg now "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
     --arg name "$name" --arg admin "$admin" --argjson credits "$credits" \
     '.accounts[$fp] = {fingerprint: $fp, status: "pending", credits: $credits,
      name: (if $name == "" then null else $name end),
      admin: (if $admin == "true" then true else false end),
      created_at: $now}' \
     "$ACCOUNTS_FILE" > "$tmpfile" \
    || ac_fail "seed_row: cannot seed row for $fp"
  mv "$tmpfile" "$ACCOUNTS_FILE"
}
