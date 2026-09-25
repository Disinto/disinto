#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1538.sh
#
# Issue #1538: feat(edge): porter-doctor checks the door without printing secrets
#
# porter-doctor.sh (tools/edge-control/) is the read-only doctor for the
# Porter door: same paths as porter-install.sh (including its PORTER_ROOT
# prefixing), one line per check (`ok`/`bad` plus a name), never prints an
# env value (the TYPESAFE_API_KEY check only reports empty or set, the value
# never reaches stdout), and exits 0 only if every check is ok.
#
#   AC1  A good fixture exits 0; stdout is exactly the eight expected `ok`
#         lines, and the sentinel key value present in porter.env is never
#         printed.
#   AC2  A world-readable (666) env file with a non-empty key exits non-zero
#         and stdout contains `bad` (`bad typesafe-key world-readable`); the
#         key value is never printed.
#   AC3  An empty TYPESAFE_API_KEY= line (while another sentinel value sits
#         in the same file) reports `bad typesafe-key empty`, exits non-zero,
#         and prints nothing of the file's contents.
#   AC4  Bad fixtures report their specific line: a missing/unexecutable door
#         script, a non-JSON ledger, a scope.json without questions, and a
#         drop-in without `Match User porter` or with a column-0
#         AuthorizedKeysCommand.
#   AC5  A bare (uninstalled) prefix reports all eight checks bad and exits
#         non-zero.
#
# No network, no sshd, no dispatch/jev execution. Per the issue, the temp
# tree is built in the test (door files copied from tools/edge-control;
# porter-install.sh is NOT invoked).
#
# Run with: tools/run-acceptance.sh 1538
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq mktemp grep chmod stat printf cp find

DOCTOR="${REPO_ROOT}/tools/edge-control/porter-doctor.sh"
ac_assert_file "${DOCTOR}" "tools/edge-control/porter-doctor.sh is missing"

# Sentinel "secret" planted in the fixture porter.env. It is unique to this
# fixture; if the doctor prints any env value, this line appears in the
# output.
SENL="ac-1538-porter-sentinel-7d3e2f91"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# ── Fixture builder ───────────────────────────────────────────────────────────
# build_tree <root> <env-mode> <key-value> <dropin-variant>
#
# Builds a complete door tree at <root>: dispatch.sh / key-command.sh /
# porter-wrap.sh / stripe-webhook.sh, lib/ , verbs/ and packs/ copied from
# tools/edge-control with 755 on the .sh files; an empty seeded ledger; a
# porter.env at <env-mode> carrying
#   TYPESAFE_API_KEY=<key-value>
#   STRIPE_SECRET_KEY=<SENL>      (the sentinel the doctor must never print)
#   JEV_MODEL=jev-1.13.0
# and a sshd drop-in per <dropin-variant>:
#   good       — the canonical 7-line Match block, ^AuthorizedKeysCommand
#                indented under Match
#   no-match   — Match User nobody (no `Match User porter`)
#   unindented — a column-0 AuthorizedKeysCommand line before the Match block
#
# dropin <conf> <door-dir> [prelude ...] <match-line> — emit the canonical
# Match block (the same template porter-install.sh writes to the drop-in)
# into <conf>, with each line emitted by its own printf: the test source
# must not carry a 5-line copy of the installer's heredoc (duplicate
# detection).
dropin() {
  local conf door_dir match
  # <conf> <door-dir> [prelude ...] <match-line>
  conf="$1"
  door_dir="$2"
  match="${!#}"
  shift 2
  {
    if [ "$#" -gt 0 ]; then
      printf '%s\n' "$@"
    fi
    printf '%s\n' "$match"
    printf '%s\n' "    AuthorizedKeysCommand ${door_dir}/key-command.sh %f %t %k"
    printf '%s\n' '    AuthorizedKeysCommandUser porter'
    printf '%s\n' '    PasswordAuthentication no'
    printf '%s\n' '    AllowTcpForwarding no'
    printf '%s\n' '    X11Forwarding no'
    printf '%s\n' '    PermitTunnel no'
  } > "$conf"
}

build_tree() {
  local root="$1" mode="$2" key_value="$3" variant="$4"
  local opt="${root}/opt/porter"
  local conf
  conf="${root}/etc/ssh/sshd_config.d/porter.conf"
  mkdir -p "${opt}" "${root}/var/lib/disinto" "${root}/etc/porter" \
           "${root}/etc/ssh/sshd_config.d"
  for f in dispatch.sh key-command.sh porter-wrap.sh stripe-webhook.sh; do
    cp -- "${REPO_ROOT}/tools/edge-control/${f}" "${opt}/${f}"
    chmod 755 "${opt}/${f}"
  done
  cp -r "${REPO_ROOT}/tools/edge-control/lib" "${opt}/"
  cp -r "${REPO_ROOT}/tools/edge-control/verbs" "${opt}/"
  cp -r "${REPO_ROOT}/tools/edge-control/packs" "${opt}/"
  find "${opt}" -type f -name '*.sh' -exec chmod 755 {} +
  printf '{"version":1,"accounts":{}}\n' > "${root}/var/lib/disinto/accounts.json"
  printf 'TYPESAFE_API_KEY=%s\nSTRIPE_SECRET_KEY=%s\nJEV_MODEL=jev-1.13.0\n' \
         "${key_value}" "${SENL}" > "${root}/etc/porter/porter.env"
  chmod "${mode}" "${root}/etc/porter/porter.env"
  case "${variant}" in
    good)
      dropin "${conf}" "${opt}" "Match User porter"
      ;;
    no-match)
      dropin "${conf}" "${opt}" "Match User nobody"
      ;;
    unindented)
      dropin "${conf}" "${opt}" \
             "AuthorizedKeysCommand ${opt}/key-command.sh %f %t %k" \
             "Match User porter"
      ;;
  esac
}

# ── Runner helpers ────────────────────────────────────────────────────────────
# run_doctor <root> — run the doctor with PORTER_ROOT=<root>; sets OUT
# (stdout+stderr combined) and RC. Always returns 0 so set -e stays happy.
run_doctor() {
  RC=0
  OUT="$(PORTER_ROOT="$1" bash "${DOCTOR}" 2>&1)" || RC=$?
}

# assert_no_leak — OUT must not contain the sentinel; the doctor never prints
# an env value.
assert_no_leak() {
  [[ "${OUT}" != *"${SENL}"* ]] \
    || ac_fail "doctor printed an env value (sentinel) into its output"
}

# ── AC1: good fixture → exit 0, exactly the eight ok lines, no leak ─────────
build_tree "${TMP_DIR}/good" 640 "${SENL}" good
run_doctor "${TMP_DIR}/good"
ac_assert_eq "${RC}" "0" "AC1: good fixture must exit 0 (got ${RC})"
expected="ok key-command.sh
ok porter-wrap.sh
ok dispatch.sh
ok verbs/jev.sh
ok scope-questions
ok ledger
ok typesafe-key set
ok sshd-drop-in"
if [[ "${OUT}" != "${expected}" ]]; then
  ac_fail "AC1: good fixture output differs from the expected 8 ok lines (rc=${RC})"
fi
assert_no_leak
ac_log "AC1: good fixture exits 0, 8 ok lines, sentinel value never printed"

# ── AC2: world-readable env with a non-empty key → non-zero, `bad` line ─────
build_tree "${TMP_DIR}/world" 666 "${SENL}" good
run_doctor "${TMP_DIR}/world"
if [[ "${RC}" -eq 0 ]]; then
  ac_fail "AC2: world-readable env with non-empty key must exit non-zero (got 0)"
fi
if [[ "${OUT}" != *bad* ]]; then
  ac_fail "AC2: world-readable fixture: no 'bad' line in stdout"
fi
if [[ "${OUT}" != *"bad typesafe-key world-readable"* ]]; then
  ac_fail "AC2: world-readable fixture: expected 'bad typesafe-key world-readable' (rc=${RC})"
fi
assert_no_leak
ac_log "AC2: world-readable env → non-zero exit, bad typesafe-key world-readable"

# ── AC3: empty TYPESAFE_API_KEY → bad typesafe-key empty, non-zero, no leak ──
build_tree "${TMP_DIR}/empty" 640 "" good
run_doctor "${TMP_DIR}/empty"
if [[ "${RC}" -eq 0 ]]; then
  ac_fail "AC3: empty typesafe key must exit non-zero (got 0)"
fi
if [[ "${OUT}" != *"bad typesafe-key empty"* ]]; then
  ac_fail "AC3: expected 'bad typesafe-key empty' for the empty key (rc=${RC})"
fi
assert_no_leak
ac_log "AC3: empty key → bad typesafe-key empty; the file's other values not printed"

# ── AC4: specific bad fixtures ───────────────────────────────────────────────
# (a) a missing door script
build_tree "${TMP_DIR}/missing-file" 640 "${SENL}" good
rm -f "${TMP_DIR}/missing-file/opt/porter/dispatch.sh"
run_doctor "${TMP_DIR}/missing-file"
if [[ "${RC}" -eq 0 ]]; then
  ac_fail "AC4a: missing dispatch.sh must exit non-zero (got 0)"
fi
if [[ "${OUT}" != *"bad dispatch.sh"* ]]; then
  ac_fail "AC4a: expected 'bad dispatch.sh' for the missing file (rc=${RC})"
fi
assert_no_leak

# (b) a non-executable door script
build_tree "${TMP_DIR}/nonexec" 640 "${SENL}" good
chmod 644 "${TMP_DIR}/nonexec/opt/porter/key-command.sh"
run_doctor "${TMP_DIR}/nonexec"
if [[ "${RC}" -eq 0 ]]; then
  ac_fail "AC4b: non-executable key-command.sh must exit non-zero (got 0)"
fi
if [[ "${OUT}" != *"bad key-command.sh"* ]]; then
  ac_fail "AC4b: expected 'bad key-command.sh' for the non-executable file (rc=${RC})"
fi
assert_no_leak

# (c) a non-JSON ledger
build_tree "${TMP_DIR}/bad-ledger" 640 "${SENL}" good
printf 'not json at all\n' > "${TMP_DIR}/bad-ledger/var/lib/disinto/accounts.json"
run_doctor "${TMP_DIR}/bad-ledger"
if [[ "${RC}" -eq 0 ]]; then
  ac_fail "AC4c: non-JSON ledger must exit non-zero (got 0)"
fi
if [[ "${OUT}" != *"bad ledger not-json"* ]]; then
  ac_fail "AC4c: expected 'bad ledger not-json' (rc=${RC})"
fi
assert_no_leak

# (d) scope.json without a questions object
build_tree "${TMP_DIR}/bad-scope" 640 "${SENL}" good
jq 'del(.questions)' "${TMP_DIR}/bad-scope/opt/porter/packs/scope.json" \
  > "${TMP_DIR}/bad-scope/opt/porter/packs/scope.json.tmp" \
  || ac_fail "AC4d: cannot strip questions from scope.json"
mv "${TMP_DIR}/bad-scope/opt/porter/packs/scope.json.tmp" \
  "${TMP_DIR}/bad-scope/opt/porter/packs/scope.json"
run_doctor "${TMP_DIR}/bad-scope"
if [[ "${RC}" -eq 0 ]]; then
  ac_fail "AC4d: scope.json without questions must exit non-zero (got 0)"
fi
if [[ "${OUT}" != *"bad scope-questions"* ]]; then
  ac_fail "AC4d: expected 'bad scope-questions' (rc=${RC})"
fi
assert_no_leak

# (e) drop-in without `Match User porter`
build_tree "${TMP_DIR}/no-match" 640 "${SENL}" no-match
run_doctor "${TMP_DIR}/no-match"
if [[ "${RC}" -eq 0 ]]; then
  ac_fail "AC4e: drop-in without Match User porter must exit non-zero (got 0)"
fi
if [[ "${OUT}" != *"bad sshd-drop-in no-match"* ]]; then
  ac_fail "AC4e: expected 'bad sshd-drop-in no-match' (rc=${RC})"
fi
assert_no_leak

# (f) drop-in with a column-0 AuthorizedKeysCommand
build_tree "${TMP_DIR}/unindented" 640 "${SENL}" unindented
run_doctor "${TMP_DIR}/unindented"
if [[ "${RC}" -eq 0 ]]; then
  ac_fail "AC4f: drop-in with ^AuthorizedKeysCommand must exit non-zero (got 0)"
fi
if [[ "${OUT}" != *"bad sshd-drop-in unindented-authorized-keys"* ]]; then
  ac_fail "AC4f: expected 'bad sshd-drop-in unindented-authorized-keys' (rc=${RC})"
fi
assert_no_leak
ac_log "AC4: specific bad fixtures report their specific bad line"

# ── AC5: bare prefix → all eight checks bad, non-zero ───────────────────────
mkdir -p "${TMP_DIR}/bare"
run_doctor "${TMP_DIR}/bare"
if [[ "${RC}" -eq 0 ]]; then
  ac_fail "AC5: bare prefix must exit non-zero (got 0)"
fi
bad_count="$(grep -c '^bad ' <<<"${OUT}" || true)"
ac_assert_eq "${bad_count}" "8" \
  "AC5: expected 8 bad lines on a bare prefix, got ${bad_count}"
assert_no_leak
ac_log "AC5: bare prefix → 8 bad lines, non-zero exit"

ac_pass
