#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1848.sh
#
# Issue #1848: the session journal and the lessons digest go through
# dsh_oneshot, in the .profile clone, not through claude -p. A failed
# journal call writes no entry. A digest timeout archives nothing.
#
# Acceptance (no network, no forge, no model; dsh and claude are stubs):
#   1. grep -niE 'claude' lib/profile.sh prints nothing.
#   2. Stub prints "a transferable lesson". profile_write_journal 42 t
#      merged "" returns 0, and exactly one journal/issue-42-*.md holds
#      that text. The stub ran with --profile headless in the profile
#      clone, and the claude stub never ran.
#   3. Stub exits 1 with no output: profile_write_journal 43 t failed ""
#      returns 1 and no issue-43-* file exists.
#   4. Six journals, stub prints a fenced lesson. _profile_digest_journals
#      returns 0, knowledge/lessons-learned.md contains the lesson line
#      and no fence, and five journals are in journal/archive/.
#   5. Stub sleeps 5, PROFILE_DIGEST_TIMEOUT=1: digest returns 1 and
#      nothing is archived.
#   6. bash -n and shellcheck pass on lib/profile.sh.
#
# Run via: tools/run-acceptance.sh 1848
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash shellcheck timeout find grep

work="$(mktemp -d "${TMPDIR:-/tmp}/issue-1848.XXXXXX")"
trap 'rm -rf "$work"' EXIT

stub_bin="${work}/stubs"
profile_root="${work}/profile"
oneshot_log="${work}/oneshot-invocations.txt"
anthropic_mark="${work}/anthropic-cli-mark"
session_log="${work}/session.log"
touch "$oneshot_log" "$session_log"
mkdir -p "$stub_bin" "$profile_root"

# Inline stand-ins. Wording and control flow stay local to this file so a
# 5-line window is not a copy of tests/acceptance/issue-1847.sh.
cat > "${stub_bin}/dsh" << 'EOF'
#!/usr/bin/env bash
exec 9>>"${PROFILE_ONESHOT_LOG:?}"
printf 'argv<%s>\n' "$*" >&9
printf 'pwd<%s>\n' "$PWD" >&9
exec 9>&-
mode="${PROFILE_ONESHOT_MODE:-reflect}"
if [ "$mode" = "reflect" ]; then
  printf '%s\n' 'a transferable lesson'
  exit 0
elif [ "$mode" = "quiet-error" ]; then
  exit 1
elif [ "$mode" = "fenced-lesson" ]; then
  printf '%s\n' '```markdown'
  printf '%s\n' '- lesson one is long enough'
  printf '%s\n' '```'
  exit 0
elif [ "$mode" = "pause-five" ]; then
  sleep 5
  printf '%s\n' 'late text'
  exit 0
fi
printf 'bad mode %s\n' "$mode" >&2
exit 8
EOF
cat > "${stub_bin}/claude" << 'EOF'
#!/usr/bin/env bash
printf 'anthropic-cli-called\n' >> "${PROFILE_ANTHROPIC_MARK:?}"
exit 0
EOF
chmod +x "${stub_bin}/dsh" "${stub_bin}/claude"

export PATH="${stub_bin}:${PATH}"
export PROFILE_ONESHOT_LOG="$oneshot_log"
export PROFILE_ANTHROPIC_MARK="$anthropic_mark"
export PROFILE_ONESHOT_MODE=reflect
export AGENT_IDENTITY=test-bot
export SID_FILE="${work}/session.sid"
export LOGFILE="$session_log"
export PROFILE_DIGEST_MAX_BATCH=5
unset PROFILE_DIGEST_TIMEOUT

log() { printf '%s\n' "$*" >> "$LOGFILE"; }

# shellcheck source=lib/agent-sdk.sh
source "$REPO_ROOT/lib/agent-sdk.sh"
# shellcheck source=lib/profile.sh
source "$REPO_ROOT/lib/profile.sh"

_profile_has_repo() { return 0; }
profile_ensure_repo() { PROFILE_REPO_PATH="$profile_root"; }
_profile_commit_and_push() { :; }
profile_ensure_repo

# ── 1. No claude left in the library ────────────────────────────────────────
ac_log "AC 1: lib/profile.sh does not mention claude"
claude_hits="$(grep -niE 'claude' "$REPO_ROOT/lib/profile.sh" || true)"
[ -z "$claude_hits" ] || ac_fail "lib/profile.sh still mentions claude: ${claude_hits}"
ac_log "AC 1 OK"

# ── 2. Journal text comes from dsh, in the profile clone ────────────────────
ac_log "AC 2: journal entry from dsh headless, claude unused"
: > "$oneshot_log"
rc=0
profile_write_journal 42 t merged "" || rc=$?
ac_assert_eq "$rc" "0" "profile_write_journal 42 should return 0 (got ${rc})"
mapfile -t issue42 < <(find "$profile_root/journal" -maxdepth 1 -type f -name 'issue-42-*.md' | sort)
ac_assert_eq "${#issue42[@]}" "1" "expected exactly one issue-42 journal (got ${#issue42[@]})"
journal_body="$(cat "${issue42[0]}")"
ac_assert_eq "$journal_body" "a transferable lesson" \
  "issue-42 journal should hold the stub text (got: ${journal_body})"
invocation="$(cat "$oneshot_log")"
case "$invocation" in
  *'argv<--profile headless '*) ;;
  *) ac_fail "dsh was not invoked with --profile headless (log: ${invocation})" ;;
esac
case "$invocation" in
  *"pwd<${profile_root}>"*) ;;
  *) ac_fail "dsh did not run in the profile clone (log: ${invocation})" ;;
esac
[ ! -e "$anthropic_mark" ] || ac_fail "claude stub ran during journal write"
ac_log "AC 2 OK"

# ── 3. A failed one-shot writes no journal file ─────────────────────────────
ac_log "AC 3: failing stub writes no issue-43 journal"
export PROFILE_ONESHOT_MODE=quiet-error
rc=0
profile_write_journal 43 t failed "" || rc=$?
ac_assert_eq "$rc" "1" "profile_write_journal 43 should return 1 (got ${rc})"
mapfile -t issue43 < <(find "$profile_root" -type f -name 'issue-43-*' | sort)
ac_assert_eq "${#issue43[@]}" "0" "a failed journal call must not create issue-43-* (got ${#issue43[@]})"
ac_log "AC 3 OK"

# ── 4. Fenced digest text, batch of five archived ───────────────────────────
ac_log "AC 4: fenced digest lands in lessons-learned, five journals archived"
rm -rf "$profile_root/journal" "$profile_root/knowledge"
mkdir -p "$profile_root/journal"
note_n=1
while [ "$note_n" -le 6 ]; do
  printf 'session note %s\n' "$note_n" > "$profile_root/journal/note-${note_n}.md"
  note_n=$((note_n + 1))
done
export PROFILE_ONESHOT_MODE=fenced-lesson
export PROFILE_DIGEST_TIMEOUT=30
rc=0
_profile_digest_journals || rc=$?
ac_assert_eq "$rc" "0" "_profile_digest_journals should return 0 (got ${rc})"
lessons_file="$profile_root/knowledge/lessons-learned.md"
ac_assert_file "$lessons_file" "digest should write knowledge/lessons-learned.md"
grep -Fqx -- '- lesson one is long enough' "$lessons_file" \
  || ac_fail "lessons file missing the stripped lesson line: $(cat "$lessons_file")"
if grep -E '^```' "$lessons_file" >/dev/null 2>&1; then
  ac_fail "lessons file still has a fence line: $(cat "$lessons_file")"
fi
mapfile -t archived < <(find "$profile_root/journal/archive" -maxdepth 1 -type f -name '*.md' | sort)
ac_assert_eq "${#archived[@]}" "5" "expected five archived journals (got ${#archived[@]})"
ac_log "AC 4 OK"

# ── 5. Digest timeout archives nothing ──────────────────────────────────────
ac_log "AC 5: digest timeout returns 1 and archives nothing"
rm -rf "$profile_root/journal" "$profile_root/knowledge"
mkdir -p "$profile_root/journal"
printf 'still waiting\n' > "$profile_root/journal/linger-note.md"
export PROFILE_ONESHOT_MODE=pause-five
export PROFILE_DIGEST_TIMEOUT=1
rc=0
_profile_digest_journals || rc=$?
ac_assert_eq "$rc" "1" "timed-out digest should return 1 (got ${rc})"
[ ! -e "$profile_root/journal/archive" ] \
  || ac_fail "timeout must not create journal/archive"
[ -f "$profile_root/journal/linger-note.md" ] \
  || ac_fail "timeout must leave the undigested journal in place"
[ ! -e "$anthropic_mark" ] || ac_fail "claude stub ran during digest"
ac_log "AC 5 OK"

# ── 6. Syntax and shellcheck ────────────────────────────────────────────────
ac_log "AC 6: bash -n and shellcheck on lib/profile.sh"
bash -n "$REPO_ROOT/lib/profile.sh" || ac_fail "bash -n lib/profile.sh failed"
(
  cd "$REPO_ROOT" || exit 1
  shellcheck lib/profile.sh
) || ac_fail "shellcheck lib/profile.sh failed"
ac_log "AC 6 OK"

ac_pass
