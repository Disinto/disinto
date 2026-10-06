#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1851.sh
#
# Issue #1851: disinto init's preflight_check asks for the claude CLI and a
# logged-in session only when AGENT_HARNESS=claude. dsh is the default
# (#1683), so a host with no claude binary must pass preflight.
#
# Hermetic: no network, no forge, no Claude. preflight_check is extracted
# with ac_extract_fn and run under env -i against a private bin of symlinks
# plus a tmux stub. Stubs are written inline (not copied from other tests).
#
# Run via: tools/run-acceptance.sh 1851
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash git jq python3 curl grep

DISINTO="$REPO_ROOT/bin/disinto"
ac_assert_file "$DISINTO" "bin/disinto must exist so preflight_check can be extracted"

FN="$(ac_extract_fn preflight_check "$DISINTO")"
[ -n "$FN" ] || ac_fail "ac_extract_fn returned an empty preflight_check body"

HOST="$(mktemp -d "${TMPDIR:-/tmp}/issue-1851-preflight.XXXXXX")"
trap 'rm -rf "$HOST"' EXIT
mkdir -p "$HOST/bin"

# Symlink the tools preflight_check actually executes or merely looks up.
# No claude link: the missing-CLI cases depend on its absence.
plant_host_tool() {
  local tool="$1"
  local resolved
  resolved="$(command -v "$tool")"
  ln -s "$resolved" "$HOST/bin/$tool"
}
plant_host_tool bash
plant_host_tool git
plant_host_tool jq
plant_host_tool python3
plant_host_tool curl
plant_host_tool grep

printf '%s\n' '#!/bin/sh' 'exit 0' > "$HOST/bin/tmux"
chmod +x "$HOST/bin/tmux"

REAL_BASH="$(command -v bash)"

# harness "omit" leaves AGENT_HARNESS unset. FN_SRC rides env because env -i
# would otherwise drop the extracted body, and the body must not be expanded
# by this shell before bash -c sees it.
invoke_preflight() {
  local mode="$1"
  local rc=0
  if [ "$mode" = "omit" ]; then
    env -i HOME="$HOST" PATH="$HOST/bin" FN_SRC="$FN" \
      "$REAL_BASH" -c 'eval "$FN_SRC"; preflight_check o/r http://127.0.0.1:9' \
      >"$HOST/pf.out" 2>"$HOST/pf.err" || rc=$?
  else
    env -i HOME="$HOST" PATH="$HOST/bin" AGENT_HARNESS="$mode" FN_SRC="$FN" \
      "$REAL_BASH" -c 'eval "$FN_SRC"; preflight_check o/r http://127.0.0.1:9' \
      >"$HOST/pf.out" 2>"$HOST/pf.err" || rc=$?
  fi
  printf '%s' "$rc"
}

ac_log "AC 1: omitted AGENT_HARNESS exits 0 and never mentions claude"
rc="$(invoke_preflight omit)"
ac_assert_eq "$rc" "0" \
  "omitted AGENT_HARNESS must exit 0 (got ${rc}); stderr=$(cat "$HOST/pf.err")"
if grep -qi 'claude' "$HOST/pf.err"; then
  ac_fail "omitted AGENT_HARNESS wrote claude on stderr: $(cat "$HOST/pf.err")"
fi
ac_log "AC 1 OK"

ac_log "AC 2: AGENT_HARNESS=dsh does not execute a claude stub"
cat > "$HOST/bin/claude" << 'EOF'
#!/bin/sh
touch "$HOME/claude-ran"
exit 0
EOF
chmod +x "$HOST/bin/claude"
rm -f "$HOST/claude-ran"
rc="$(invoke_preflight dsh)"
ac_assert_eq "$rc" "0" \
  "AGENT_HARNESS=dsh must exit 0 when a claude stub is present (got ${rc})"
if [ -e "$HOST/claude-ran" ]; then
  ac_fail "AGENT_HARNESS=dsh ran claude; marker exists at $HOST/claude-ran"
fi
ac_log "AC 2 OK"

ac_log "AC 3: AGENT_HARNESS=claude with no CLI is a preflight error"
rm -f "$HOST/bin/claude"
rc="$(invoke_preflight claude)"
ac_assert_eq "$rc" "1" \
  "AGENT_HARNESS=claude without claude must exit 1 (got ${rc})"
grep -qF 'Error: claude not found (AGENT_HARNESS=claude)' "$HOST/pf.err" \
  || ac_fail "missing-cli stderr lacked the required line: $(cat "$HOST/pf.err")"
ac_log "AC 3 OK"

ac_log "AC 4a: auth status loggedIn=false fails preflight"
cat > "$HOST/bin/claude" << 'EOF'
#!/bin/sh
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  printf '%s\n' '{"loggedIn":false}'
fi
exit 0
EOF
chmod +x "$HOST/bin/claude"
rc="$(invoke_preflight claude)"
ac_assert_eq "$rc" "1" \
  "loggedIn false must exit 1 (got ${rc}); stderr=$(cat "$HOST/pf.err")"
grep -qF 'Error: Claude Code is not authenticated' "$HOST/pf.err" \
  || ac_fail "loggedIn false did not report unauthenticated: $(cat "$HOST/pf.err")"
ac_log "AC 4a OK"

ac_log "AC 4b: auth status loggedIn=true passes preflight"
cat > "$HOST/bin/claude" << 'EOF'
#!/bin/sh
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  printf '%s\n' '{"loggedIn":true}'
fi
exit 0
EOF
chmod +x "$HOST/bin/claude"
rc="$(invoke_preflight claude)"
ac_assert_eq "$rc" "0" \
  "loggedIn true must exit 0 (got ${rc}); stderr=$(cat "$HOST/pf.err")"
ac_log "AC 4b OK"

mock_hits="$(grep -c 'Mock: claude' "$REPO_ROOT/tests/smoke-init.sh" || true)"
ac_assert_eq "$mock_hits" "0" \
  "tests/smoke-init.sh must drop its claude mock (count=${mock_hits})"

bash -n "$DISINTO" || ac_fail "bash -n bin/disinto failed"
bash -n "$REPO_ROOT/tests/smoke-init.sh" || ac_fail "bash -n tests/smoke-init.sh failed"

ac_pass
