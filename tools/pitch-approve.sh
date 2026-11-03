#!/usr/bin/env bash
# =============================================================================
# tools/pitch-approve.sh — the gate merges a bot's ready pitch, or its
# claims/probes/packs PR (#2038, #2057)
#
# A pitch is an ops-repo PR adding sprints/<slug>.md, opened by planner-bot
# (planner/pitch-open.sh) or the gardener. The owner used to merge it by
# hand; since 2026-11-02 the gate merges it itself and tells the owner
# (docs/design/proposal-loop.md §3; notes/organs.md, "Pitches go through the
# existing vault gate", item 3). tools/pitch-decisions.sh writes the tape row
# today once the PR is closed.
#
# A config PR (#2057) is one a bot opens — the supervisor files its repair
# claims as claims/can-fix-<condition>.toml plus probes/can-fix-<condition>.sh
# (lib/repair-claim.sh, #2055) — whose files are only claims, probes or packs:
# claims/<id>.toml, probes/<name>.sh, packs/<name>.toml, each added or
# modified. Such a PR has no pitch file, so it never reached main; the same
# walk now merges it once every file validates. The tape is written as today:
# a merged claim becomes a claim proposal through tools/claim-proposals.sh
# later in the same gardener run; probes and packs have no record.
#
# List open ops-repo PRs the way tools/pitch-decisions.sh walks closed ones:
#   curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
#     "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls?state=open&limit=50&page=N"
# for N = 1, 2, … until a page has fewer than 50. A page that fails, or is
# not a JSON array, logs a warning and exits 1.
#
# A PR is considered when its .user.login is one of the comma-separated
# ${FORGE_BOT_USERNAMES} and the marker ${TAPE_DIR}/gate/pr-<P> is absent.
# Per such PR, in order:
#   1. path=$(pitch_pr_path P). No pitch file: the PR is a config PR when
#      _gate_config_ready P (#2057, below) succeeds; when it fails, or the PR
#      is neither a pitch nor a config PR — skip, no marker.
#   2. pitch_pr_fetch P path tmp. Ready when: pitch_sprint_block tmp
#      succeeds; tmp contains `<!-- filer:begin -->` (the architect has
#      drafted the sub-issues onto the branch); "${PITCH_LINT:-
#      tools/pitch-lint.sh}" tmp exits 0; and the block's `effect` is `none`,
#      a file under ${OPS_REPO_ROOT}, or a filename in GET /pulls/P/files —
#      a sprint whose probe is not in the ops repo is never scored
#      (tools/sprint-outcomes.sh skips a failing probe every run). Not
#      ready: one warning naming the missing piece, no marker, next run
#      retries. A config PR is ready by definition: _gate_config_ready has
#      already validated every one of its files.
#   3. tier=$("${CLASSIFY:-action-vault/classify.sh}" pitch|config); a failing
#      classifier means high. ops vault/policy.toml gives config = "low".
#   4. POST /pulls/P/merge with body {"Do":"merge"} and FORGE_TOKEN. Failure:
#      warning, no marker, the run exits 1 at the end.
#   5. notice_owner "pitch #P '<title>' approved by the gate (tier <tier>):
#      <html_url>", or for a config PR "ops PR #P '<title>' (config: <paths,
#      space-separated>) approved by the gate (tier <tier>): <html_url>".
#      Then mkdir -p ${TAPE_DIR}/gate and touch the marker.
#
# _gate_config_ready P (#2057) — is P a bot's claims/probes/packs PR?
#   GET /pulls/P/files must be a non-empty array whose every entry has status
#   added or modified and a filename matching ^claims/[a-z][a-z0-9-]*\.toml$,
#   ^probes/[A-Za-z0-9][A-Za-z0-9.-]*\.sh$ (holding no `..`) or
#   ^packs/[a-z][a-z0-9-]*\.toml$. Anything else — a removed file, a
#   sprints/, vault/ or catalog/ path — logs one line naming the PR and the
#   first offending file, and returns 1.
#   Each file is then read as it stands on the PR head with pitch_pr_fetch
#   (lib/pitch-pr.sh) and validated: a claim through CLAIMS_DIR=<tmp>/claims
#   claim_valid <id> (lib/claims.sh), a probe through bash -n, a pack through
#   a tomllib parse. The first failure logs one line naming the file and
#   returns 1; on success the PR's paths are printed space-separated.
#
# Usage:
#   tools/pitch-approve.sh
#
# Environment:
#   FORGE_API_BASE          forge API base (no trailing path)
#   FORGE_OPS_REPO          owner/name of the ops repo
#   FORGE_TOKEN            token for the Authorization header
#   FORGE_BOT_USERNAMES    comma-separated bot logins (lib/env.sh)
#   OPS_REPO_ROOT          ops clone (ensure_ops_repo syncs it at run start)
#   TAPE_DIR               tape directory (default /srv/disinto/tape)
#   PITCH_LINT             lint seam (default $REPO_ROOT/tools/pitch-lint.sh)
#   CLASSIFY               tier seam (default $REPO_ROOT/action-vault/classify.sh)
#
# Exit codes:
#   0  every open bot pitch or config PR was merged, skipped, or left
#      unready for the next run
#   1  a page could not be listed, or a ready pitch or config PR could not be
#      merged
#
# The gardener calls this right after the run lock, before ensure_ops_repo,
# so the merged pitch is pulled by the ops sync and pitch-decisions.sh files
# it in the same run. A non-zero exit only logs a warning; it never fails the
# gardener run.
#
# Hermetic apart from the forge it is pointed at and the tape markers it
# writes. No agent, no secrets (AD-006). No lib/env.sh here: the gardener
# already loaded the project.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=../lib/pitch.sh
source "$REPO_ROOT/lib/pitch.sh"
# shellcheck source=../lib/pitch-pr.sh
source "$REPO_ROOT/lib/pitch-pr.sh"
# shellcheck source=../lib/notice.sh
source "$REPO_ROOT/lib/notice.sh"
# shellcheck source=../lib/claims.sh
source "$REPO_ROOT/lib/claims.sh"

TAPE_DIR="${TAPE_DIR:-/srv/disinto/tape}"
PITCH_LINT="${PITCH_LINT:-$REPO_ROOT/tools/pitch-lint.sh}"
CLASSIFY="${CLASSIFY:-$REPO_ROOT/action-vault/classify.sh}"

# A config PR (#2057) touches only claim, probe or pack files of the ops repo.
_CONFIG_FILE_RE='^(claims/[a-z][a-z0-9-]*\.toml|probes/[A-Za-z0-9][A-Za-z0-9.-]*\.sh|packs/[a-z][a-z0-9-]*\.toml)$'

if ! command -v jq >/dev/null 2>&1; then
  printf 'pitch-approve: jq is required\n' >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  printf 'pitch-approve: curl is required\n' >&2
  exit 1
fi

# Warnings only. stdout stays empty so a caller can tell a merge from a log.
log() { printf 'pitch-approve: WARNING: %s\n' "$*" >&2; }

# ops_get PATH — GET under the ops repo. The caller sees curl's status.
ops_get() {
  curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}${1}"
}

# ops_post PATH BODY — POST under the ops repo with a JSON body.
ops_post() {
  curl -sf -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$2" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}${1}"
}

# is_bot LOGIN — 0 when LOGIN appears in the comma list FORGE_BOT_USERNAMES.
is_bot() {
  local login="$1" list
  list="${FORGE_BOT_USERNAMES:-}"
  if [ -z "$list" ] || [ -z "$login" ]; then
    return 1
  fi
  case ",${list}," in
    *,${login},*) return 0 ;;
    *) return 1 ;;
  esac
}

# mark_approved P — create gate/pr-P. A failure leaves the approval unmarked.
mark_approved() {
  local number="$1"
  local dir="${TAPE_DIR}/gate"
  mkdir -p "$dir" || return 1
  touch "${dir}/pr-${number}" || return 1
}

# probe_present P EFFECT — the effect of a scorable sprint: `none`, a file
# under OPS_REPO_ROOT, or a file the PR itself adds. An empty effect is not
# scorable.
probe_present() {
  local number="$1" effect="$2" body="" match="" rc=0
  if [ "$effect" = "none" ]; then
    return 0
  fi
  if [ -n "$effect" ] && [ -f "${OPS_REPO_ROOT:-}/${effect}" ]; then
    return 0
  fi
  if [ -z "$effect" ]; then
    return 1
  fi
  rc=0
  body="$(ops_get "/pulls/${number}/files")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    return 1
  fi
  # Captured, not jq -e: jq 1.6 reports success on empty output.
  match="$(printf '%s' "$body" | jq -r --arg e "$effect" \
    '.[] | .filename // empty | select(. == $e)' 2>/dev/null || true)"
  [ -n "$match" ]
}

# _gate_config_ready P — is P a bot's claims/probes/packs PR (#2057)?
#   0  every file of the PR is a claim, probe or pack that validates; the
#      PR's paths are printed space-separated on stdout
#   1  the file list is unusable, or the first offending or invalid file has
#      already been warned about
_gate_config_ready() {
  local number="${1:-}"
  local body kind entry status filename path dest id rc tmp
  local -a paths=()

  if ! body="$(ops_get "/pulls/${number}/files")"; then
    log "PR ${number}: its file list could not be read; not merged"
    return 1
  fi
  kind="$(printf '%s' "$body" | jq -r 'type' 2>/dev/null || printf 'invalid')"
  if [ "$kind" != "array" ]; then
    log "PR ${number}: its file list is ${kind}, not an array; not merged"
    return 1
  fi
  if [ "$(jq -r 'length' <<< "$body")" -eq 0 ]; then
    log "PR ${number} adds no file at all; not merged"
    return 1
  fi
  while IFS= read -r entry; do
    status="$(printf '%s' "$entry" | jq -r '.status // empty' 2>/dev/null || true)"
    filename="$(printf '%s' "$entry" | jq -r '.filename // empty' 2>/dev/null || true)"
    if [ "$status" != "added" ] && [ "$status" != "modified" ]; then
      log "PR ${number} ${status:-changes} ${filename:-a file}: the gate merges only added or modified claims, probes and packs"
      return 1
    fi
    if ! [[ "$filename" =~ $_CONFIG_FILE_RE ]] || [[ "$filename" == *..* ]]; then
      log "PR ${number} touches ${filename:-a nameless file}, which is no claim, probe or pack; not merged"
      return 1
    fi
    paths+=("$filename")
  done < <(jq -c '.[]' <<< "$body")
  if [ "${#paths[@]}" -eq 0 ]; then
    log "PR ${number}: its file list could not be read; not merged"
    return 1
  fi

  tmp="$(mktemp -d)" || {
    log "could not create a temp dir for PR ${number}; not merged"
    return 1
  }
  for path in "${paths[@]}"; do
    dest="${tmp}/${path}"
    if ! mkdir -p "${dest%/*}"; then
      log "could not stage ${path} of PR ${number}; not merged"
      rm -rf "$tmp"
      return 1
    fi
    if ! pitch_pr_fetch "$number" "$path" "$dest" >/dev/null; then
      log "could not read ${path} of PR ${number} at its head; not merged"
      rm -rf "$tmp"
      return 1
    fi
    rc=0
    case "${path%%/*}" in
      claims)
        id="${path##*/}"
        id="${id%.toml}"
        CLAIMS_DIR="${tmp}/claims" claim_valid "$id" >/dev/null 2>&1 || rc=$?
        if [ "$rc" -ne 0 ]; then
          log "PR ${number}: claim ${path} fails claim_valid; not merged"
          rm -rf "$tmp"
          return 1
        fi
        ;;
      probes)
        if ! bash -n "$dest"; then
          log "PR ${number}: probe ${path} fails bash -n; not merged"
          rm -rf "$tmp"
          return 1
        fi
        ;;
      packs)
        if ! python3 -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' "$dest"; then
          log "PR ${number}: pack ${path} is not valid TOML; not merged"
          rm -rf "$tmp"
          return 1
        fi
        ;;
    esac
  done
  rm -rf "$tmp"
  printf '%s\n' "${paths[*]}"
  return 0
}

# classify_tier KIND — the blast-radius tier of a merged PR ("pitch" or
# "config"); high when the classifier fails or prints nothing.
classify_tier() {
  local kind="$1" tier="" rc=0
  tier="$("${CLASSIFY}" "$kind" 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$tier" ]; then
    tier="high"
  fi
  printf '%s\n' "$tier"
}

# handle_open_pr PR_JSON — approve one open bot pitch or config PR, or leave
# it for the next run.
#   0  not a bot, neither a pitch nor a config PR, already marked, or left
#      unready (retry)
#   1  a ready pitch or config PR failed to merge or failed to be marked
handle_open_pr() {
  local pr_json="$1"
  local number="" login="" marker="" kind="" config_paths="" path="" tmp="" block="" effect="" tier="" rc=0
  number="$(printf '%s' "$pr_json" | jq -r '.number // empty' 2>/dev/null || true)"
  if ! [[ "$number" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  login="$(printf '%s' "$pr_json" | jq -r '.user.login // empty' 2>/dev/null || true)"
  if ! is_bot "$login"; then
    return 0
  fi
  marker="${TAPE_DIR}/gate/pr-${number}"
  if [ -e "$marker" ]; then
    return 0
  fi

  # 1. A pitch adds exactly one sprints/<slug>.md. Without it the PR is a
  #    config PR — claims, probes and packs only (#2057) — when every file
  #    validates; anything else is skipped with no marker.
  kind=""
  config_paths=""
  path=""
  if path="$(pitch_pr_path "$number")"; then
    kind="pitch"
  elif config_paths="$(_gate_config_ready "$number")"; then
    kind="config"
  else
    return 0
  fi

  # 2. A pitch is ready only with its sprint block, drafted sub-issues, a
  #    clean lint and a scorable effect. A config PR is already validated.
  if [ "$kind" = "pitch" ]; then
    tmp="$(mktemp)" || {
      log "could not create a temp file for pitch #${number}; no marker written"
      return 1
    }
    if ! pitch_pr_fetch "$number" "$path" "$tmp" >/dev/null; then
      log "could not read pitch file ${path} for PR ${number}; retry next run"
      rm -f "$tmp"
      return 0
    fi
    if ! block="$(pitch_sprint_block "$tmp")"; then
      log "pitch #${number} is missing its sprint block; not merged"
      rm -f "$tmp"
      return 0
    fi
    if ! grep -qF '<!-- filer:begin -->' "$tmp"; then
      log "pitch #${number} has no filer block: the sub-issues are not drafted; not merged"
      rm -f "$tmp"
      return 0
    fi
    rc=0
    "$PITCH_LINT" "$tmp" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      log "pitch #${number} fails pitch-lint (rc=${rc}); the drafted sub-issues are not clean; not merged"
      rm -f "$tmp"
      return 0
    fi
    effect="$(sprint_field "$block" effect)"
    if ! probe_present "$number" "$effect"; then
      log "pitch #${number} effect probe '${effect:-missing}' is not in the ops clone or the PR files; not merged"
      rm -f "$tmp"
      return 0
    fi
    rm -f "$tmp"
  fi

  # 3. Tier from the vault classifier.
  tier="$(classify_tier "$kind")"

  # 4. The gate merges. A failed merge leaves the PR open, writes no marker,
  # and makes the run exit 1 at the end.
  if ! ops_post "/pulls/${number}/merge" '{"Do":"merge"}' >/dev/null; then
    log "gate merge failed for ${kind} PR #${number}; no marker written, retry next run"
    return 1
  fi

  # 5. Tell the owner, then mark. A config notice names every file the gate
  # merged, so the owner can see which claim, probe or pack reached main.
  local title="" html="" message=""
  title="$(printf '%s' "$pr_json" | jq -r '.title // empty' 2>/dev/null || true)"
  html="$(printf '%s' "$pr_json" | jq -r '.html_url // empty' 2>/dev/null || true)"
  if [ "$kind" = "pitch" ]; then
    message="pitch #${number} '${title}' approved by the gate (tier ${tier}): ${html}"
  else
    message="ops PR #${number} '${title}' (config: ${config_paths}) approved by the gate (tier ${tier}): ${html}"
  fi
  if ! notice_owner "$message"; then
    log "notice for ${kind} PR #${number} could not be queued; the merge still stands"
  fi
  if ! mark_approved "$number"; then
    log "could not write the gate marker for ${kind} PR #${number}"
    return 1
  fi
  log "${kind} PR #${number} merged by the gate (tier ${tier})"
  return 0
}

# walk_open — every page of open ops-repo PRs.
#   0  each bot pitch or config PR was merged, skipped, or left unready
#   1  a page could not be listed, or a ready pitch or config PR could not be
#      merged
walk_open() {
  local page=0 body="" kind="" count="" entry="" failed=0
  while true; do
    page=$((page + 1))
    if ! body="$(ops_get "/pulls?state=open&limit=50&page=${page}")"; then
      log "could not list open ops-repo PRs (page ${page})"
      return 1
    fi
    kind="$(jq -r 'type' <<< "$body" 2>/dev/null || printf 'invalid')"
    if [ "$kind" != "array" ]; then
      log "open PR listing (page ${page}) returned ${kind}, not an array"
      return 1
    fi
    count="$(jq -r 'length' <<< "$body" 2>/dev/null || printf '0')"
    while IFS= read -r entry; do
      handle_open_pr "$entry" || failed=1
    done < <(jq -c '.[]' <<< "$body")
    if [ "$count" -lt 50 ]; then
      break
    fi
  done
  return "$failed"
}

open_rc=0
walk_open || open_rc=$?
exit "$open_rc"
