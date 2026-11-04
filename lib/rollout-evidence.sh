#!/usr/bin/env bash
# =============================================================================
# rollout-evidence.sh — the agents' rollout evidence lines (#2106)
#
# The rollout tool (tools/rollout.sh, docs/design/notes/self-update.md, "The
# flow") promotes a commit only on evidence that the canary agent ran it and
# held: the commit it runs, the smoke on it, each poll's exit, and whether its
# reviews worked. This lib is the writer of that evidence; nothing calls it
# yet (the agents start recording it in #2108, the review poll in #2109, and
# tools/rollout.sh reads it in #2111).
#
# One JSON object per line, in
#   ${ROLLOUT_EVIDENCE_DIR:-${TAPE_DIR:-/srv/disinto/tape}/rollout/evidence}/${NOMAD_JOB_NAME:-local}.jsonl
# Nomad sets NOMAD_JOB_NAME in every task, so each agent job has its own file.
#
# The three line shapes:
#   take:  {"t":<epoch>,"kind":"take","job":<job>,"ref":REF,"commit":COMMIT,"smoke":SMOKE_RC}
#          plus "smoke_tail":<first 500 chars of SMOKE_TAIL> only when SMOKE_RC != 0
#   poll:  {"t":<epoch>,"kind":"poll","job":<job>,"ref":REF,"commit":COMMIT,"role":ROLE,"rc":RC}
#   work:  {"t":<epoch>,"kind":"work","job":<job>,"commit":<c>,"role":ROLE,"due":DUE,"done":DONE,"failed":FAILED}
#          where <c> is `git -C "${FACTORY_ROOT:-.}" rev-parse HEAD`, or "unknown" when that fails
#
# Public (sourced; pure bash + jq, does not source lib/env.sh):
#   rollout_evidence_file
#     -> print the evidence file path.
#   rollout_evidence_init
#     -> mkdir -p the evidence directory. When running as root (the entrypoint
#        runs as root under umask 077), also touch the file and chown
#        agent:agent the file, the evidence directory and its parent rollout/,
#        so the agent user can read and append. Ignores every failure; always
#        returns 0.
#   rollout_evidence_take REF COMMIT SMOKE_RC [SMOKE_TAIL]
#     -> append one take line. Return 1, writing nothing, if REF/COMMIT are
#        empty or SMOKE_RC is not ^[0-9]+$.
#   rollout_evidence_poll REF COMMIT ROLE RC
#     -> append one poll line. Return 1 on the same kind of bad argument.
#   rollout_evidence_work ROLE DUE DONE FAILED
#     -> append one work line, with commit taken from FACTORY_ROOT. Return 1
#        on a bad argument.
#
# t is `date -u +%s` as a number; job is ${NOMAD_JOB_NAME:-local}. A failed
# append returns 1. Nothing prints on stdout.
#
# Size cap: after every append, a file larger than ${ROLLOUT_EVIDENCE_MAX_B:-1048576}
# bytes is rewritten in place (tail to a temp file, then cat tmp > file, so the
# file keeps its inode and owner) to its last ${ROLLOUT_EVIDENCE_KEEP:-2000}
# lines.
#
# Env seams:
#   ROLLOUT_EVIDENCE_DIR   evidence directory; overrides the TAPE_DIR-derived default.
#   TAPE_DIR               the tape volume (default /srv/disinto/tape).
#   NOMAD_JOB_NAME         the job's name (default local).
#   FACTORY_ROOT           the factory checkout git -C uses for the work line.
#   ROLLOUT_EVIDENCE_MAX_B size cap in bytes.
#   ROLLOUT_EVIDENCE_KEEP  lines kept when the cap triggers.
#
# Tests: tests/acceptance/issue-2106.sh.
# =============================================================================
set -euo pipefail

rollout_evidence_file() {
  printf '%s\n' "${ROLLOUT_EVIDENCE_DIR:-${TAPE_DIR:-/srv/disinto/tape}/rollout/evidence}/${NOMAD_JOB_NAME:-local}.jsonl"
}

# Ensure the evidence directory exists, and when the caller is root (the
# entrypoint, under umask 077) make the file and its two directories readable
# by the agent user. Total: never fails, prints nothing.
rollout_evidence_init() {
  local dir
  local file
  local parent
  dir="${ROLLOUT_EVIDENCE_DIR:-${TAPE_DIR:-/srv/disinto/tape}/rollout/evidence}"
  file="$(rollout_evidence_file)"
  mkdir -p "$dir" 2>/dev/null || true
  if [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; then
    touch "$file" 2>/dev/null || true
    parent="${dir%/*}"
    chown agent:agent "$file" "$dir" "$parent" 2>/dev/null || true
  fi
  return 0
}

# Append one line built by jq; return 1 (writing nothing) when jq or the
# append fails.
_rollout_evidence_append() {
  local file="$1"
  local program="$2"
  shift 2
  if ! jq -cn "$program" "$@" >>"$file"; then
    return 1
  fi
  # Best-effort size cap: keep the file under ROLLOUT_EVIDENCE_MAX_B bytes by
  # rewriting it in place with the last ROLLOUT_EVIDENCE_KEEP lines. The temp
  # file plus cat > file keeps the inode and owner; a cap failure never
  # discards the evidence already on the tape.
  local max_b="${ROLLOUT_EVIDENCE_MAX_B:-1048576}"
  local keep="${ROLLOUT_EVIDENCE_KEEP:-2000}"
  if [[ "$max_b" =~ ^[0-9]+$ ]] && [[ "$keep" =~ ^[0-9]+$ ]]; then
    local size
    size="$(wc -c <"$file" 2>/dev/null)" || size=0
    if [ "$size" -gt "$max_b" ]; then
      local tmp
      tmp="$(mktemp "$file.tmp.XXXXXX" 2>/dev/null)" || return 0
      if tail -n "$keep" "$file" 2>/dev/null >"$tmp" && cat "$tmp" 2>/dev/null >"$file"; then
        rm -f "$tmp" 2>/dev/null || true
        return 0
      fi
      rm -f "$tmp" 2>/dev/null || true
    fi
  fi
  return 0
}

rollout_evidence_take() {
  local ref="${1:-}"
  local commit="${2:-}"
  local smoke_rc="${3:-}"
  local smoke_tail="${4:-}"
  if [ -z "$ref" ] || [ -z "$commit" ] || ! [[ "$smoke_rc" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  # shellcheck disable=SC2016  # $t/$job/... are jq variables, not bash expansions
  _rollout_evidence_append "$(rollout_evidence_file)" \
    '{t: $t, kind: "take", job: $job, ref: $ref, commit: $commit, smoke: $smoke}
     + (if $smoke != 0 then {smoke_tail: ($tail | .[0:500])} else {} end)' \
    --argjson t "$(date -u +%s)" \
    --arg job "${NOMAD_JOB_NAME:-local}" \
    --arg ref "$ref" \
    --arg commit "$commit" \
    --argjson smoke "$smoke_rc" \
    --arg tail "$smoke_tail"
}

rollout_evidence_poll() {
  local ref="${1:-}"
  local commit="${2:-}"
  local role="${3:-}"
  local rc="${4:-}"
  if [ -z "$ref" ] || [ -z "$commit" ] || [ -z "$role" ] || ! [[ "$rc" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  # shellcheck disable=SC2016  # $t/$job/... are jq variables, not bash expansions
  _rollout_evidence_append "$(rollout_evidence_file)" \
    '{t: $t, kind: "poll", job: $job, ref: $ref, commit: $commit, role: $role, rc: $rc}' \
    --argjson t "$(date -u +%s)" \
    --arg job "${NOMAD_JOB_NAME:-local}" \
    --arg ref "$ref" \
    --arg commit "$commit" \
    --arg role "$role" \
    --argjson rc "$rc"
}

rollout_evidence_work() {
  local role="${1:-}"
  local due="${2:-}"
  local done="${3:-}"
  local failed="${4:-}"
  if [ -z "$role" ] || ! [[ "$due" =~ ^[0-9]+$ ]] || ! [[ "$done" =~ ^[0-9]+$ ]] || ! [[ "$failed" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  local commit
  commit="$(git -C "${FACTORY_ROOT:-.}" rev-parse HEAD 2>/dev/null)" || commit="unknown"
  # shellcheck disable=SC2016  # $t/$job/... are jq variables, not bash expansions
  _rollout_evidence_append "$(rollout_evidence_file)" \
    '{t: $t, kind: "work", job: $job, commit: $commit, role: $role, due: $due, "done": $done, failed: $failed}' \
    --argjson t "$(date -u +%s)" \
    --arg job "${NOMAD_JOB_NAME:-local}" \
    --arg commit "$commit" \
    --arg role "$role" \
    --argjson due "$due" \
    --argjson "done" "$done" \
    --argjson failed "$failed"
}
