#!/usr/bin/env bash
# formula-session.sh — Shared helpers for formula-driven polling-loop agents
#
# Provides reusable utility functions for the common polling-loop wrapper pattern
# used by planner-run.sh, predictor-run.sh, gardener-run.sh, and supervisor-run.sh.
#
# Functions:
#   acquire_run_lock    LOCK_FILE          — PID lock with stale cleanup
#   load_formula        FORMULA_FILE       — sets FORMULA_CONTENT
#   build_context_block FILE [FILE ...]    — sets CONTEXT_BLOCK
#   build_prompt_footer [EXTRA_API_LINES]  — sets PROMPT_FOOTER (API ref + env)
#   build_sdk_prompt_footer [EXTRA_API]    — omits phase protocol (SDK mode)
#   formula_worktree_setup WORKTREE        — isolated worktree for formula execution
#   resolve_agent_identity                 — resolve agent user login from FORGE_TOKEN
#   build_graph_section                    — run build-graph.py and set GRAPH_SECTION
#   build_scratch_instruction SCRATCH_FILE — return context scratch instruction
#   read_scratch_context SCRATCH_FILE      — return scratch file content block
#   ensure_ops_repo                        — clone/pull ops repo
#   ops_commit_and_push MESSAGE [FILES]    — commit/push to ops repo
#   cleanup_stale_crashed_worktrees [HOURS] — thin wrapper around worktree_cleanup_stale
#   load_formula_or_profile [ROLE] [FORMULA_FILE] — load from .profile or fallback
#   formula_tape_ulid                    — emit a 26-char Crockford-base32 ULID
#   formula_session_start [ORGAN]        — open the tape run record for a session
#   formula_session_end [RC] [TRANSCRIPT] — close it: closing run record with cost
#
# Subsystems (sourced):
#   profile.sh  — agent .profile repository: lessons-learned digest + per-session journal
#   tape.sh     — proposal-loop tape writers (#1389); run/outcome instrumentation (#1391)
#
# Requires: lib/env.sh, lib/worktree.sh, lib/agent-sdk.sh sourced first for shared helpers.

# Source agent-sdk for claude_run_with_watchdog watchdog helper
source "$(dirname "${BASH_SOURCE[0]}")/agent-sdk.sh"

# Source ops-setup for migrate_ops_repo (used by ensure_ops_repo)
source "$(dirname "${BASH_SOURCE[0]}")/ops-setup.sh"

# Source profile for .profile repo / lessons-learned digest subsystem
source "$(dirname "${BASH_SOURCE[0]}")/profile.sh"

# Source tape writers for the proposal-loop tape instrumentation (#1391)
source "$(dirname "${BASH_SOURCE[0]}")/tape.sh"

# ── Run guards ───────────────────────────────────────────────────────────

# acquire_run_lock LOCK_FILE
# Acquires a PID lock. Exits 0 if another instance is running.
# Sets an EXIT trap to clean up the lock file.
acquire_run_lock() {
  _RUN_LOCK_FILE="$1"
  if [ -f "$_RUN_LOCK_FILE" ]; then
    local lock_pid
    lock_pid=$(cat "$_RUN_LOCK_FILE" 2>/dev/null || true)
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
      log "run: already running (PID $lock_pid)"
      exit 0
    fi
    rm -f "$_RUN_LOCK_FILE"
  fi
  echo $$ > "$_RUN_LOCK_FILE"
  trap 'rm -f "$_RUN_LOCK_FILE"' EXIT
}

# ── Agent identity resolution ────────────────────────────────────────────

# resolve_agent_identity
# Resolves the agent identity (user login) from the FORGE_TOKEN.
# Exports AGENT_IDENTITY (user login string).
# Returns 0 on success, 1 on failure.
resolve_agent_identity() {
  if [ -z "${FORGE_TOKEN:-}" ]; then
    log "WARNING: FORGE_TOKEN not set, cannot resolve agent identity"
    return 1
  fi
  AGENT_IDENTITY=$(forge_whoami)
  if [ -z "$AGENT_IDENTITY" ]; then
    log "WARNING: failed to resolve agent identity from FORGE_TOKEN"
    return 1
  fi
  log "Resolved agent identity: ${AGENT_IDENTITY}"
  return 0
}

# ── Forge remote resolution ──────────────────────────────────────────────

# resolve_forge_remote
# Resolves FORGE_REMOTE by matching FORGE_URL hostname against git remotes.
# Falls back to "origin" if no match found.
# Requires: FORGE_URL, git repo with remotes configured.
# Exports: FORGE_REMOTE (always set).
resolve_forge_remote() {
  # Extract hostname from FORGE_URL (e.g., https://codeberg.org/user/repo -> codeberg.org)
  _forge_host=$(printf '%s' "$FORGE_URL" | sed 's|https\?://||; s|/.*||; s|:.*||')
  # Find git remote whose push URL matches the forge host
  FORGE_REMOTE=$(git remote -v | awk -v host="$_forge_host" '$2 ~ host && /\(push\)/ {print $1; exit}')
  # Fallback to origin if no match found
  FORGE_REMOTE="${FORGE_REMOTE:-origin}"
  export FORGE_REMOTE
  log "forge remote: ${FORGE_REMOTE}"
}

# ── Formula loading ──────────────────────────────────────────────────────

# load_formula FORMULA_FILE
# Reads formula TOML into FORMULA_CONTENT. Exits 1 if missing.
load_formula() {
  local formula_file="$1"
  if [ ! -f "$formula_file" ]; then
    log "ERROR: formula not found: $formula_file"
    exit 1
  fi
  # shellcheck disable=SC2034  # consumed by the calling script
  FORMULA_CONTENT=$(cat "$formula_file")
}

# load_formula_or_profile [ROLE] [FORMULA_FILE]
# Tries to load formula from .profile repo first, falls back to formulas/<role>.toml.
# Requires: AGENT_IDENTITY, profile_ensure_repo() available.
# Exports: FORMULA_CONTENT, FORMULA_SOURCE (either ".profile" or "formulas/").
# Returns 0 on success, 1 on failure.
load_formula_or_profile() {
  local role="${1:-}"
  local fallback_formula="${2:-}"

  # Try to load from .profile repo
  if [ -n "$AGENT_IDENTITY" ] && profile_ensure_repo "$AGENT_IDENTITY"; then
    if [ -f "$PROFILE_FORMULA_PATH" ]; then
      log "formula source: .profile (${PROFILE_FORMULA_PATH})"
      # shellcheck disable=SC2034
      FORMULA_CONTENT="$(cat "$PROFILE_FORMULA_PATH")"
      FORMULA_SOURCE=".profile"
      return 0
    else
      log "WARNING: .profile repo exists but formula.toml not found at ${PROFILE_FORMULA_PATH}"
    fi
  fi

  # Fallback to formulas/<role>.toml
  if [ -n "$fallback_formula" ]; then
    if [ -f "$fallback_formula" ]; then
      log "formula source: formulas/ (fallback) — ${fallback_formula}"
      # shellcheck disable=SC2034
      FORMULA_CONTENT="$(cat "$fallback_formula")"
      FORMULA_SOURCE="formulas/"
      return 0
    else
      log "ERROR: formula not found in .profile and fallback file not found: $fallback_formula"
      return 1
    fi
  fi

  # No fallback specified but role provided — construct fallback path
  if [ -n "$role" ]; then
    fallback_formula="${FACTORY_ROOT}/formulas/${role}.toml"
    if [ -f "$fallback_formula" ]; then
      log "formula source: formulas/ (fallback) — ${fallback_formula}"
      # shellcheck disable=SC2034
      FORMULA_CONTENT="$(cat "$fallback_formula")"
      # shellcheck disable=SC2034
      FORMULA_SOURCE="formulas/"
      return 0
    fi
  fi

  # No fallback specified
  log "ERROR: formula not found in .profile and no fallback specified"
  return 1
}

# build_context_block FILE [FILE ...]
# Reads each file from $PROJECT_REPO_ROOT and builds CONTEXT_BLOCK.
# Files prefixed with "ops:" are read from $OPS_REPO_ROOT instead.
build_context_block() {
  CONTEXT_BLOCK=""
  local ctx ctx_path ctx_label
  for ctx in "$@"; do
    case "$ctx" in
      ops:*)
        ctx_label="${ctx#ops:}"
        ctx_path="${OPS_REPO_ROOT}/${ctx_label}"
        ;;
      *)
        ctx_label="$ctx"
        ctx_path="${PROJECT_REPO_ROOT}/${ctx}"
        ;;
    esac
    if [ -f "$ctx_path" ]; then
      CONTEXT_BLOCK="${CONTEXT_BLOCK}
### ${ctx_label}
$(cat "$ctx_path")
"
    fi
  done
}

# ── Ops repo helpers ────────────────────────────────────────────────────

# ensure_ops_repo
# Clones or pulls the ops repo so agents can read/write operational data.
# Requires: OPS_REPO_ROOT, FORGE_OPS_REPO, FORGE_URL, FORGE_TOKEN.
# No-op if OPS_REPO_ROOT already exists and is up-to-date.
ensure_ops_repo() {
  local ops_root="${OPS_REPO_ROOT:-}"
  [ -n "$ops_root" ] || return 0

  if [ -d "${ops_root}/.git" ]; then
    # Pull latest from primary branch
    git -C "$ops_root" fetch origin "${PRIMARY_BRANCH}" --quiet 2>/dev/null || true
    git -C "$ops_root" checkout "${PRIMARY_BRANCH}" --quiet 2>/dev/null || true
    git -C "$ops_root" pull --ff-only origin "${PRIMARY_BRANCH}" --quiet 2>/dev/null || true
    migrate_ops_repo "$ops_root" "${PRIMARY_BRANCH}"
    return 0
  fi

  # Clone from Forgejo
  local ops_repo="${FORGE_OPS_REPO:-}"
  [ -n "$ops_repo" ] || return 0
  local forge_url="${FORGE_URL:-http://localhost:3000}"
  # Use clean URL — credential helper supplies auth (#604)
  local clone_url="${forge_url}/${ops_repo}.git"

  log "Cloning ops repo: ${ops_repo} -> ${ops_root}"
  if git clone --quiet "$clone_url" "$ops_root" 2>/dev/null; then
    log "Ops repo cloned: ${ops_root}"
  else
    log "WARNING: failed to clone ops repo ${ops_repo} — creating local directory"
    mkdir -p "$ops_root"
  fi
}

# ops_commit_and_push MESSAGE [FILE ...]
# Stage, commit, and push changes in the ops repo.
# If no files specified, stages all changes.
ops_commit_and_push() {
  local msg="$1"
  shift
  local ops_root="${OPS_REPO_ROOT:-}"
  [ -d "${ops_root}/.git" ] || return 0

  (
    cd "$ops_root" || return
    if [ $# -gt 0 ]; then
      git add "$@"
    else
      git add -A
    fi
    if ! git diff --cached --quiet; then
      git commit -m "$msg"
      git push origin "${PRIMARY_BRANCH}" --quiet 2>/dev/null || true
    fi
  )
}

# ── Scratch file helpers (compaction survival) ────────────────────────────

# build_scratch_instruction SCRATCH_FILE
# Returns a prompt block instructing Claude to periodically flush context
# to a scratch file so understanding survives context compaction.
build_scratch_instruction() {
  local scratch_file="$1"
  cat <<_SCRATCH_EOF_
## Context scratch file (compaction survival)

Periodically (every 10-15 tool calls), write a summary of:
- What you have discovered so far
- Decisions made and why
- What remains to do
to: ${scratch_file}

If this file existed at session start, its contents have already been injected into your prompt above.
This file is ephemeral — not evidence or permanent memory, just a compaction survival mechanism.
_SCRATCH_EOF_
}

# read_scratch_context SCRATCH_FILE
# If the scratch file exists, returns a context block for prompt injection.
# Returns empty string if the file does not exist.
read_scratch_context() {
  local scratch_file="$1"
  if [ -f "$scratch_file" ]; then
    printf '## Previous context (from scratch file)\n%s\n' "$(head -c 8192 "$scratch_file")"
  fi
}

# ── Graph report helper ───────────────────────────────────────────────────

# build_graph_section
# Runs build-graph.py and sets GRAPH_SECTION to a markdown block containing
# the JSON report.  Sets GRAPH_SECTION="" on failure (non-fatal).
# Requires globals: PROJECT_NAME, FACTORY_ROOT, PROJECT_REPO_ROOT, LOG_FILE.
build_graph_section() {
  local report="/tmp/${PROJECT_NAME}-graph-report.json"
  # shellcheck disable=SC2034  # consumed by the calling script's PROMPT
  GRAPH_SECTION=""
  if python3 "$FACTORY_ROOT/lib/build-graph.py" \
       --project-root "$PROJECT_REPO_ROOT" \
       --output "$report" 2>>"$LOG_FILE"; then
    # shellcheck disable=SC2034
    local report_content
    report_content="$(cat "$report")"
    # shellcheck disable=SC2034
    GRAPH_SECTION="
## Structural analysis
\`\`\`json
${report_content}
\`\`\`"
    log "graph report generated: $(jq -r '.stats | "\(.nodes) nodes, \(.edges) edges"' "$report")"
  else
    log "WARN: build-graph.py failed — continuing without structural analysis"
  fi
}

# ── SDK helpers ───────────────────────────────────────────────────────────

# build_sdk_prompt_footer [EXTRA_API_LINES]
# Like build_prompt_footer but omits the phase protocol section (SDK mode).
# Sets PROMPT_FOOTER.
build_sdk_prompt_footer() {
  # shellcheck disable=SC2034  # consumed by build_prompt_footer
  PHASE_FILE=""  # not used in SDK mode
  build_prompt_footer "${1:-}"
  PROMPT_FOOTER="${PROMPT_FOOTER%%## Phase protocol*}"
}

# formula_worktree_setup WORKTREE
# Creates an isolated worktree for synchronous formula execution.
# Fetches primary branch, cleans stale worktree, creates new one, and
# sets an EXIT trap for cleanup.
# Requires globals: PROJECT_REPO_ROOT, PRIMARY_BRANCH.
# Self-heals FORGE_REMOTE by calling resolve_forge_remote when unset — this
# eliminates a silent-abort bug class in callers that forgot the precondition
# (see #1120 / #551). Callers still need FORGE_URL set so resolve_forge_remote
# can match a git remote (or fall back to "origin").
formula_worktree_setup() {
  local worktree="$1"
  cd "$PROJECT_REPO_ROOT" || return
  if [ -z "${FORGE_REMOTE:-}" ]; then
    resolve_forge_remote
  fi
  git fetch "${FORGE_REMOTE}" "$PRIMARY_BRANCH" 2>/dev/null || true
  worktree_cleanup "$worktree"
  git worktree add "$worktree" "${FORGE_REMOTE}/${PRIMARY_BRANCH}" --detach 2>/dev/null
  # shellcheck disable=SC2064  # expand worktree now, not at trap time
  trap "worktree_cleanup '$worktree'" EXIT
}

# ── Prompt helpers ──────────────────────────────────────────────────────

# build_prompt_footer [EXTRA_API_LINES]
# Assembles the common forge API reference + environment block for formula prompts.
# Sets PROMPT_FOOTER.
# Pass additional API endpoint lines (pre-formatted, newline-prefixed) via $1.
# Requires globals: FORGE_API, FACTORY_ROOT, PROJECT_REPO_ROOT,
#                   PRIMARY_BRANCH.
build_prompt_footer() {
  local extra_api="${1:-}"
  # shellcheck disable=SC2034  # consumed by the calling script's PROMPT
  PROMPT_FOOTER="## Forge API reference
Base URL: ${FORGE_API}
Auth header: -H \"Authorization: token \${FORGE_TOKEN}\"
  Read issue:  curl -sf -H \"Authorization: token \${FORGE_TOKEN}\" '${FORGE_API}/issues/{number}' | jq '.body'
  List labels: curl -sf -H \"Authorization: token \${FORGE_TOKEN}\" '${FORGE_API}/labels'${extra_api}
NEVER echo or include the actual token value in output — always reference \${FORGE_TOKEN}.

## Environment
FACTORY_ROOT=${FACTORY_ROOT}
PROJECT_REPO_ROOT=${PROJECT_REPO_ROOT}
OPS_REPO_ROOT=${OPS_REPO_ROOT}
PRIMARY_BRANCH=${PRIMARY_BRANCH}"
}

# ── Stale crashed worktree cleanup ────────────────────────────────────────

# cleanup_stale_crashed_worktrees [MAX_AGE_HOURS]
# Thin wrapper around worktree_cleanup_stale() from lib/worktree.sh.
# Kept for backwards compatibility with existing callers.
# Requires: lib/worktree.sh sourced.
cleanup_stale_crashed_worktrees() {
  worktree_cleanup_stale "${1:-24}"
}

# ── Proposal-loop tape instrumentation (#1391) ────────────────────────────
#
# Every formula session is a "run" on the proposal-loop tape with an
# "outcome" (#1389). The organ wrapper brackets its agent session with
# formula_session_start / formula_session_end; all tape work happens here,
# once, so every organ that runs formulas is covered.
#
# These functions are TOTAL: they always return 0. A tape failure (unwritable
# $TAPE_DIR, missing jq/flock, validation refusal) logs a WARNING and is
# ignored — the organ never fails because of the tape.

# formula_tape_ulid
# Emits a 26-char Crockford-base32 ULID: 10 chars of 48-bit millisecond
# timestamp + 16 chars of 80 random bits. Pure bash + od, so it works on the
# busybox CI image (no python, no uuidgen requirement).
formula_tape_ulid() {
  local alph="0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  local ts_hex rand out="" v i c
  ts_hex=$(printf '%012x' $(( $(date -u +%s) * 1000 )))
  v=$((16#$ts_hex))
  for ((i = 9; i >= 0; i--)); do
    c=$((v % 32)); out="${alph:c:1}$out"; v=$((v / 32))
  done
  rand=$(od -An -N10 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  rand="${rand}00000000000000000000"
  rand="${rand:0:20}"
  # Two 40-bit chunks (10 hex digits each) → 8 base32 chars each; 40 bits
  # fits in bash's 64-bit arithmetic, 80 does not.
  local chunk
  for chunk in "${rand:0:10}" "${rand:10:10}"; do
    v=$((16#$chunk))
    for ((i = 7; i >= 0; i--)); do
      c=$((v % 32)); out="${alph:c:1}$out"; v=$((v / 32))
    done
  done
  printf '%s' "$out"
}

# formula_session_start [ORGAN]
# Opens the tape run record for the current formula session:
#   - run id = fresh ULID; proposal = $TAPE_PROPOSAL_ID when set (with a
#     minimal tape_proposal appended if the tape has no record for that id
#     yet), else the run ULID
#   - organ = $1 (default "organ"), agent = <harness>/<model>
#     (AGENT_HARNESS, default claude, + CLAUDE_MODEL when set)
# Appends one OPEN tape_run line (started + attempts set, ended/status
# omitted). Sets the _FORMULA_TAPE_* state consumed by formula_session_end.
# Always returns 0.
formula_session_start() {
  local organ="${1:-organ}"
  local run_id proposal started agent
  run_id=$(formula_tape_ulid) || run_id=""
  [ -n "$run_id" ] || run_id="run-$$-$(date -u +%s)"
  proposal="${TAPE_PROPOSAL_ID:-$run_id}"
  started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  agent="${AGENT_HARNESS:-claude}"
  [ -n "${CLAUDE_MODEL:-}" ] && agent="${agent}/${CLAUDE_MODEL}"

  _FORMULA_TAPE_ACTIVE=1
  _FORMULA_TAPE_RUN_ID="$run_id"
  _FORMULA_TAPE_PROPOSAL="$proposal"
  _FORMULA_TAPE_ORGAN="$organ"
  _FORMULA_TAPE_AGENT="$agent"
  _FORMULA_TAPE_STARTED="$started"
  _FORMULA_TAPE_START_EPOCH=$(date -u +%s)
  _FORMULA_TAPE_ATTEMPTS=1

  # Known caller proposal? Append a minimal proposal record if none exists
  # yet. The parse is line-tolerant (try fromjson) so a torn final line from
  # a concurrent writer can only cost us a duplicate, never a crash.
  if [ -n "${TAPE_PROPOSAL_ID:-}" ]; then
    local tape_file="${TAPE_DIR}/tape.jsonl"
    local found=""
    if [ -f "$tape_file" ]; then
      found=$(jq -R -r -s --arg id "$proposal" '
          [splits("\n")]
          | map(select(. != "") | (try fromjson))
          | map(select(type == "object"))
          | map(select(.type == "proposal" and .id == $id) | .id)
          | first // ""
        ' "$tape_file" 2>/dev/null) || found=""
    fi
    if [ -z "$found" ]; then
      local ctx
      ctx=$(jq -cn --arg organ "$organ" '{organ: $organ}')
      if ! tape_proposal "$proposal" formula "$organ" '' '' "$ctx" '' auto "$proposal" \
          >/dev/null 2>&1; then
        log "WARNING: tape: failed to append minimal proposal ${proposal}"
      fi
    fi
  fi

  if ! tape_run "$proposal" "$organ" "$agent" "$started" '' \
      "$_FORMULA_TAPE_ATTEMPTS" '{}' '' >/dev/null 2>&1; then
    log "WARNING: tape: failed to append open run record for ${proposal}"
  fi
  return 0
}

# formula_session_end [EXIT_CODE] [TRANSCRIPT_FILE]
# Closes the run opened by formula_session_start:
#   - closing tape_run (records are immutable — a second append with
#     ended + status completed|failed set), carrying the session cost on the
#     run's `cost` object: duration_s (integer seconds, >=0), tokens_in/
#     tokens_out when the transcript's final result row carries usage (the
#     same parse as before — omitted when it does not), and transcript = the
#     tape_payload hash of the transcript when the store succeeds (key
#     omitted on failure). No tape_outcome is written: run status lives on the
#     run record, not on a separate outcome (#1474).
# TRANSCRIPT_FILE defaults to the harness diagnostics file
# (${DISINTO_LOG_DIR:-/tmp}/${LOG_AGENT}/agent-run-last.json).
# No-ops (return 0) when no session was started. A tape failure logs a
# WARNING and is ignored.
formula_session_end() {
  local exit_code="${1:-0}" transcript="${2:-}"
  case "$exit_code" in '' | *[!0-9]*) exit_code=0 ;; esac
  [ -n "$transcript" ] || \
    transcript="${DISINTO_LOG_DIR:-/tmp}/${LOG_AGENT:-dev}/agent-run-last.json"

  if [ "${_FORMULA_TAPE_ACTIVE:-0}" != "1" ]; then
    return 0
  fi

  local ended epoch_now duration_s status
  ended=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  epoch_now=$(date -u +%s)
  duration_s=$(( epoch_now - _FORMULA_TAPE_START_EPOCH ))
  [ "$duration_s" -ge 0 ] || duration_s=0
  if [ "$exit_code" -eq 0 ]; then status="completed"; else status="failed"; fi

  # Transcript → payload ref + token counts from the final result row
  # (usage.input_tokens / usage.output_tokens, same shape the harness
  # normalises into metrics). Missing file or missing usage → omitted.
  local tokens_in="" tokens_out="" payload_ref="" last_row
  if [ -f "$transcript" ]; then
    if ! payload_ref=$(tape_payload "$transcript" 2>/dev/null); then
      log "WARNING: tape: failed to store transcript payload: ${transcript}"
      payload_ref=""
    fi
    last_row=$(jq -cs 'last' "$transcript" 2>/dev/null) || last_row=""
    if [ -n "$last_row" ]; then
      tokens_in=$(printf '%s' "$last_row" | jq -r '.usage.input_tokens // empty' 2>/dev/null) || tokens_in=""
      tokens_out=$(printf '%s' "$last_row" | jq -r '.usage.output_tokens // empty' 2>/dev/null) || tokens_out=""
    fi
  fi
  case "$tokens_in" in '' | *[!0-9]*) tokens_in="" ;; esac
  case "$tokens_out" in '' | *[!0-9]*) tokens_out="" ;; esac

  # Session cost on the closing run record (not an outcome — #1474):
  #   duration_s always (int, >=0); tokens_in/tokens_out when the transcript
  #   carries usage; transcript = tape_payload hash when the store succeeded.
  local cost
  cost=$(jq -cn \
      --argjson d "$duration_s" \
      --arg ti "$tokens_in" \
      --arg to "$tokens_out" \
      --arg h "$payload_ref" '
    {duration_s: $d}
    + (if $ti != "" then {tokens_in: ($ti | tonumber)} else {} end)
    + (if $to != "" then {tokens_out: ($to | tonumber)} else {} end)
    + (if $h != "" then {transcript: $h} else {} end)')

  if ! tape_run "$_FORMULA_TAPE_PROPOSAL" "$_FORMULA_TAPE_ORGAN" "$_FORMULA_TAPE_AGENT" \
      "$_FORMULA_TAPE_STARTED" "$ended" "$_FORMULA_TAPE_ATTEMPTS" "$cost" "$status" \
      >/dev/null 2>&1; then
    log "WARNING: tape: failed to append closing run record"
  fi

  _FORMULA_TAPE_ACTIVE=0
  return 0
}

# ── Back-compat shims (deprecated — update callers to use profile_*) ────
# These shims exist so existing callers aren't broken on day one.
# Remove after follow-up PRs update callers to the new names.

# Deprecated: use profile_prepare_context instead
formula_prepare_profile_context() { profile_prepare_context "$@"; }

# Deprecated: use profile_lessons_block instead
formula_lessons_block() { profile_lessons_block "$@"; }
