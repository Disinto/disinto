#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1483.sh
#
# Issue #1483: chore: point operator defaults at disinto-admin/disinto
#
# Operator-facing defaults still said the source was codeberg.org/johba/disinto,
# but the live repo is disinto-admin/disinto on the Forgejo instance. Three
# files needed updating so the defaults no longer point at the stale Codeberg
# source:
#
#   - site/install.sh
#       Must clone https://self.disinto.ai/forge/disinto-admin/disinto.git
#       (the public forge remote). Must NOT clone codeberg.org/johba/disinto.
#
#   - lib/disinto/backup.sh
#       The backup/restore helper told operators to pull-mirror from Codeberg into
#       Forgejo, which would overwrite the source with the stale mirror. The
#       restore source is the backup bundle / Forgejo, not Codeberg. The
#       "Configure Codeberg → Forgejo pull mirror" lines must be gone.
#
#   - projects/disinto.toml.example
#       The repo field must be "disinto-admin/disinto", not "johba/disinto".
#       A commented Codeberg URL may remain in [mirrors] only as an optional
#       read-only mirror (not the repo field).
#
# Acceptance (read-only — no live services, no curl; files are grepped from the
# repo):
#   1. site/install.sh does NOT contain the stale codeberg.org/johba/disinto URL
#      and DOES contain the new self.disinto.ai/forge/disinto-admin/disinto.git
#      clone URL.
#   2. lib/disinto/backup.sh does NOT instruct a pull mirror from
#      codeberg.org/johba/disinto (no "Codeberg" mirror instructions).
#   3. projects/disinto.toml.example has repo = "disinto-admin/disinto".
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep

INSTALL_SH="$REPO_ROOT/site/install.sh"
BACKUP_SH="$REPO_ROOT/lib/disinto/backup.sh"
TOML_EXAMPLE="$REPO_ROOT/projects/disinto.toml.example"

# ── 1. site/install.sh ────────────────────────────────────────────────────────

ac_assert_file "$INSTALL_SH" "site/install.sh must exist"

# Must not clone the stale Codeberg URL
if grep -qF 'codeberg.org/johba/disinto' "$INSTALL_SH"; then
  ac_fail "site/install.sh must not clone codeberg.org/johba/disinto (#1483)"
fi

# Must clone the live Forgejo public remote
if ! grep -qF 'https://self.disinto.ai/forge/disinto-admin/disinto.git' "$INSTALL_SH"; then
  ac_fail "site/install.sh must clone https://self.disinto.ai/forge/disinto-admin/disinto.git (#1483)"
fi

ac_log "AC 1 OK: site/install.sh points at self.disinto.ai/forge/disinto-admin/disinto.git"

# ── 2. lib/disinto/backup.sh ─────────────────────────────────────────────────

ac_assert_file "$BACKUP_SH" "lib/disinto/backup.sh must exist"

# Must not instruct a pull mirror from Codeberg. The old block had lines like:
#   backup_log "  Source: ssh://git@codeberg.org/johba/disinto.git"
#   backup_log "  Or use: git clone --mirror ssh://git@codeberg.org/johba/disinto.git"
# Both contain codeberg.org/johba/disinto. Also the instruction "Codeberg → Forgejo pull mirror"
# referenced Codeberg explicitly.
if grep -qF 'codeberg.org/johba/disinto' "$BACKUP_SH"; then
  ac_fail "lib/disinto/backup.sh must not reference codeberg.org/johba/disinto as a restore source (#1483)"
fi

# The old block also used the phrase "Codeberg" in the instruction to configure a
# Codeberg → Forgejo pull mirror. After the fix, no instruction should direct
# the operator to set up a Codeberg mirror.
if grep -qiE 'codeberg.*pull mirror|configure codeberg|pull mirror.*codeberg' "$BACKUP_SH"; then
  ac_fail "lib/disinto/backup.sh must not instruct a Codeberg pull mirror (#1483)"
fi

ac_log "AC 2 OK: lib/disinto/backup.sh has no Codeberg pull-mirror instructions"

# ── 3. projects/disinto.toml.example ─────────────────────────────────────────

ac_assert_file "$TOML_EXAMPLE" "projects/disinto.toml.example must exist"

# The repo field must be disinto-admin/disinto (not johba/disinto)
if ! grep -qE '^repo\s*=\s*"disinto-admin/disinto"' "$TOML_EXAMPLE"; then
  ac_fail "projects/disinto.toml.example must have repo = \"disinto-admin/disinto\" (#1483)"
fi

# The repo field must NOT still be johba/disinto
if grep -qE '^repo\s*=\s*"johba/disinto"' "$TOML_EXAMPLE"; then
  ac_fail "projects/disinto.toml.example repo must not be johba/disinto (#1483)"
fi

ac_log "AC 3 OK: projects/disinto.toml.example repo = disinto-admin/disinto"

ac_pass
