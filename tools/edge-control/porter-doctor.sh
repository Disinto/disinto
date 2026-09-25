#!/usr/bin/env bash
# =============================================================================
# porter-doctor.sh — read-only health check of the Porter door
#
# Answers the operator's "is the door OK?" without catting the secret: one
# line per check — `<status> <name>` with status `ok` or `bad` — and exits 0
# only if every check is ok.
#
# Read-only in every sense: no writes, no chmod, no dispatch/verb exec (no
# `jev`), no network. The env check inspects porter.env but never prints it:
# the TYPESAFE_API_KEY is reported only as empty or set, the value itself
# never touches stdout.
#
# Paths are identical to porter-install.sh, including its PORTER_ROOT
# prefixing (every path gets the prefix when PORTER_ROOT is set and
# non-empty, otherwise "/"):
#   ${PREFIX}opt/porter/key-command.sh
#   ${PREFIX}opt/porter/porter-wrap.sh
#   ${PREFIX}opt/porter/dispatch.sh
#   ${PREFIX}opt/porter/verbs/jev.sh
#   ${PREFIX}opt/porter/packs/scope.json
#   ${PREFIX}var/lib/disinto/accounts.json  — runtime ledger (ACCOUNTS_FILE)
#   ${PREFIX}etc/porter/porter.env
#   ${PREFIX}etc/ssh/sshd_config.d/porter.conf
#
# Checks (one line each, in this order):
#   key-command.sh porter-wrap.sh dispatch.sh verbs/jev.sh
#       are executable regular files.
#   scope-questions  packs/scope.json has a non-empty "questions" object.
#   ledger           the ledger exists and is a JSON object; its contents are
#       never printed.
#   typesafe-key     porter.env exists, is not world-readable (mode bits 007
#       are 0), and carries a TYPESAFE_API_KEY= line: empty ->
#       `bad typesafe-key empty`, non-empty -> `ok typesafe-key set`.
#   sshd-drop-in     porter.conf contains "Match User porter" and no line
#       matches ^AuthorizedKeysCommand.
#
# Usage: bash tools/edge-control/porter-doctor.sh
# =============================================================================
set -euo pipefail

fail=0

report_ok()  { printf 'ok %s\n' "$1"; }
report_bad() {
  printf 'bad %s\n' "$1"
  fail=1
}

# ── Paths: identical to porter-install.sh (PORTER_ROOT prefix, "/" otherwise)
PREFIX="/"
if [[ -n "${PORTER_ROOT:-}" ]]; then
  PREFIX="${PORTER_ROOT%/}/"
fi
DOOR_DIR="${PREFIX}opt/porter"
LIB_DIR="${PREFIX}var/lib/disinto"
ENV_FILE="${PREFIX}etc/porter/porter.env"
LEDGER="${LIB_DIR}/accounts.json"
DROPIN="${PREFIX}etc/ssh/sshd_config.d/porter.conf"

# ── Checks 1-4: the four door entry points are executable regular files ─────
for f in key-command.sh porter-wrap.sh dispatch.sh verbs/jev.sh; do
  if [[ -f "${DOOR_DIR}/${f}" && -x "${DOOR_DIR}/${f}" ]]; then
    report_ok "${f}"
  else
    report_bad "${f}"
  fi
done

# ── Check 5: packs/scope.json has a non-empty "questions" object ────────────
if [[ ! -f "${DOOR_DIR}/packs/scope.json" ]]; then
  report_bad "scope-questions missing"
elif jq -e '.questions | (type == "object" and (keys | length > 0))' \
     "${DOOR_DIR}/packs/scope.json" >/dev/null 2>&1; then
  report_ok "scope-questions"
else
  report_bad "scope-questions empty"
fi

# ── Check 6: the runtime ledger is a JSON object (contents never printed) ────
if [[ ! -f "${LEDGER}" ]]; then
  report_bad "ledger missing"
elif jq -e 'type == "object"' "${LEDGER}" >/dev/null 2>&1; then
  report_ok "ledger"
else
  report_bad "ledger not-json"
fi

# ── Check 7: porter.env — not world-readable and carries TYPESAFE_API_KEY=
# The value is never printed: only empty vs non-empty is reported. ────────────
if [[ ! -f "${ENV_FILE}" ]]; then
  report_bad "typesafe-key missing-env"
else
  mode="$(stat -c '%a' "${ENV_FILE}")"
  # Last octal digit of the stat -c '%a' mode string = the other bits (007).
  other=$(( (10#"$mode") % 100 % 10 ))
  if (( other != 0 )); then
    report_bad "typesafe-key world-readable"
  else
    key_line="$(grep -m1 -E '^TYPESAFE_API_KEY=' "${ENV_FILE}")" || true
    if [[ -n "${key_line:-}" ]]; then
      value="${key_line#TYPESAFE_API_KEY=}"
      value="${value%$'\r'}"
      if [[ -n "$value" ]]; then
        report_ok "typesafe-key set"
      else
        report_bad "typesafe-key empty"
      fi
    else
      report_bad "typesafe-key missing-line"
    fi
  fi
fi

# ── Check 8: sshd drop-in: `Match User porter`, no `^AuthorizedKeysCommand` ──
if [[ ! -f "${DROPIN}" ]]; then
  report_bad "sshd-drop-in missing"
elif ! grep -qF 'Match User porter' "${DROPIN}"; then
  report_bad "sshd-drop-in no-match"
elif grep -qE '^AuthorizedKeysCommand' "${DROPIN}"; then
  report_bad "sshd-drop-in unindented-authorized-keys"
else
  report_ok "sshd-drop-in"
fi

exit "$fail"
