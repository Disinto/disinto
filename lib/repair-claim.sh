#!/usr/bin/env bash
# repair-claim.sh — a suspended remedy drafts its can-fix claim (#2055)
#
# docs/design/proposal-loop.md §5: a suspension records the failure as a
# missing capability, so the planner can pitch the step that adds it. The
# supervisor drafts that capability as a claim: one ops-repo PR that adds or
# revises claims/can-fix-<CONDITION>.toml (and, when main lacks it, the
# probe that checks it). The gate (#2057) merges the PR; until then it waits
# open. This file does not merge, does not file issues, and does not source
# lib/env.sh.
#
# Source from the caller:
#   source "$(dirname "$0")/repair-claim.sh"
#
# Functions:
#   repair_claim_pr CONDITION SCRIPT STATE COUNTS
#     CONDITION must match ^[a-z][a-z0-9-]*$; STATE one of suspended|lifted;
#     COUNTS the "<failed> <counted>" line repair_suspended printed. The
#     claim id is can-fix-<CONDITION>.
#       1. GET /pulls?state=open&limit=50. When a PR whose title starts with
#          `claims: <id>` is already open, print its number and return 0 —
#          one open draft per claim.
#       2. Draft the claim file and the probe file in a temp dir.
#       3. POST /branches for claims/<id>-<YYYYmmddHHMM> from
#          ${PRIMARY_BRANCH:-main}; a failed create is accepted only when
#          GET /branches/<branch> shows the branch.
#       4. PUT /contents/claims/<id>.toml on the branch; PUT
#          /contents/probes/<id>.sh only when the base branch has no such
#          file. Each PUT carries sha only when a GET of that path on the
#          branch returns one. No author, no committer: the token's user
#          commits. Message: `claims: <id> <STATE>`.
#       5. POST /pulls, title `claims: <id> (<STATE> <ISO date>)`, head the
#          branch, base the primary branch. Print the PR number.
#     Any failed forge call: one stderr line, return 1. A bad CONDITION or
#     STATE returns 1 before any call.
#
# Env: FORGE_TOKEN, FORGE_API_BASE, FORGE_OPS_REPO, PRIMARY_BRANCH (default
# main). Requires: curl, jq, base64. Tests: tests/acceptance/issue-2055.sh.
set -euo pipefail

# _repair_claim_put BRANCH PATH SRC MESSAGE — commit SRC at PATH on BRANCH
# through the contents API. sha only when a GET of the path on the branch
# returns one; a failed GET is "no blob", not a failure, since a new file
# needs no sha. Return 1 when the PUT fails.
_repair_claim_put() {
  local branch="$1" path="$2" src="$3" message="$4"
  local api meta data payload sha
  api="${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}"

  # The blob's sha is needed only to update an existing file; a failed GET
  # reads as "no blob", never as a failure of the draft.
  meta="$(curl -sf -H "Authorization: token $FORGE_TOKEN" \
          "$api/contents/$path?ref=$branch")" || meta=""
  sha="$(printf '%s' "$meta" | jq -r '.sha // empty')" || sha=""

  data="$(base64 -w0 < "$src")" || return 1
  payload="$(jq -n --arg b "$branch" --arg m "$message" --arg c "$data" \
    --arg s "$sha" \
    'if $s != "" then {branch: $b, message: $m, content: $c, sha: $s}
     else {branch: $b, message: $m, content: $c} end')" || return 1

  curl -sf -X PUT -H "Authorization: token $FORGE_TOKEN" \
    -H "Content-Type: application/json" -d "$payload" \
    "$api/contents/$path" >/dev/null || return 1
}

# _repair_claim_open_branch BRANCH BASE — POST /branches from BASE. A failed
# create is accepted only when GET /branches/BRANCH shows the branch.
_repair_claim_open_branch() {
  local branch="$1" base="$2" api payload show shown
  api="${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}"
  payload="$(jq -n --arg new "$branch" --arg old "$base" \
    '{new_branch_name: $new, old_branch_name: $old}')" || return 1
  if curl -sf -X POST \
      -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "${api}/branches" >/dev/null; then
    return 0
  fi
  show="$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${api}/branches/${branch}")" || return 1
  shown="$(printf '%s' "$show" | jq -r '.name // empty')" || return 1
  [ "$shown" = "$branch" ]
}

# _repair_claim_probe_exists ID BASE — rc 0 when the base branch already
# holds probes/ID.sh. A failed GET means "absent", not "error": the draft
# then adds the probe.
_repair_claim_probe_exists() {
  local id="$1" base="$2" api body sha
  api="${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}"
  if ! body="$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${api}/contents/probes/${id}.sh?ref=${base}")"; then
    return 1
  fi
  sha="$(printf '%s' "$body" | jq -r '.sha // empty')" || sha=""
  [ -n "$sha" ]
}

# repair_claim_pr CONDITION SCRIPT STATE COUNTS — see the file header.
repair_claim_pr() {
  local condition="${1:-}" script="${2:-}" state="${3:-}" counts="${4:-}"
  local id api base branch iso failed counted
  local tmp claim probe body number pr_json pr_number pr_body pull_payload
  local rc=0

  if [[ ! "$condition" =~ ^[a-z][a-z0-9-]*$ ]]; then
    printf 'repair-claim: refusing unsafe condition name: %s\n' "$condition" >&2
    return 1
  fi
  case "$state" in
    suspended|lifted) ;;
    *)
      printf 'repair-claim: state must be suspended or lifted, got: %s\n' "$state" >&2
      return 1
      ;;
  esac

  id="can-fix-${condition}"
  api="${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}"
  base="${PRIMARY_BRANCH:-main}"

  # One open draft per claim: report it instead of opening a second.
  if ! body="$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${api}/pulls?state=open&limit=50")"; then
    printf 'repair-claim: failed to list open pulls for %s\n' "$id" >&2
    return 1
  fi
  if ! number="$(printf '%s' "$body" | jq -r --arg prefix "claims: ${id}" '
    .[]
    | select((.title // "") | startswith($prefix))
    | .number
    | select(. != null)
  ' | head -n 1)"; then
    printf 'repair-claim: failed to parse the open-pulls list for %s\n' "$id" >&2
    return 1
  fi
  if [ -n "$number" ]; then
    printf '%s\n' "$number"
    return 0
  fi

  read -r failed counted <<< "${counts:-}" || true
  [[ "$failed" =~ ^[0-9]+$ ]] || failed=0
  [[ "$counted" =~ ^[0-9]+$ ]] || counted=0
  iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  tmp="$(mktemp -d)" || {
    printf 'repair-claim: cannot create a temp dir for %s\n' "$id" >&2
    return 1
  }
  claim="$tmp/claim.toml"
  probe="$tmp/probe.sh"

  # The claim file: the layout of claims/dev-comes-back.toml, with the
  # drafting provenance on the first line.
  {
    printf '# Drafted by the supervisor: %s %s, %s of the last %s tries failed (proposal-loop.md §5).\n' \
      "$state" "$iso" "$failed" "$counted"
    printf 'statement = "the %s remedy (%s) clears the condition it acts on"\n' \
      "$condition" "$script"
    printf 'class = "internal"\n'
    printf 'check = "probes/%s.sh"\n' "$id"
    printf 'expect = ">= 0.5"\n'
    printf 'window = "7d"\n'
    printf 'rests_on = []\n'
  } > "$claim" || {
    printf 'repair-claim: cannot write the draft claim for %s\n' "$id" >&2
    rm -rf "$tmp"
    return 1
  }

  # The probe file: the shape of probes/dev-unreturned.sh, reading the same
  # repair tape the supervisor wrote the counts from.
  sed "s/__CONDITION__/$condition/g; s/__ID__/$id/g" > "$probe" <<'PROBE_EOF'
#!/usr/bin/env bash
# probes/__ID__.sh — the check of the __ID__ claim (#2055).
# The share of the __CONDITION__ remedy's acted repair outcomes in the probe
# window that cleared: cleared / acted, rounded to 2 places. An outcome with
# no bits.acted counts as acted. No acted outcome in the window: nothing on
# stdout, one line on stderr, exit 1.
set -euo pipefail

tape="${TAPE_DIR:-/srv/disinto/tape}/tape.jsonl"
window="${PROBE_WINDOW_DAYS:-7}"

ratio="$(jq -r -Rs --arg class "__CONDITION__" --argjson window "$window" '
  def epoch: (.t | try fromdateiso8601) // null;
  [ split("\n")[] | select(length > 0) | try fromjson ] as $recs
  | [ $recs[]
      | select(.type == "proposal" and .loop == "repair" and .class == $class)
      | select(epoch != null and epoch >= (now - ($window * 86400)))
      | .id ] as $ids
  | [ $recs[]
      | select(.type == "outcome")
      | ((.proposal_id // .proposal) as $p
        | select($p != null and ($ids | index($p)) != null))
      | select((((.bits // {}).acted // 1) == 1)) ] as $outs
  | ($outs | length) as $acted
  | if $acted == 0 then empty
    else
      ($outs
        | map(if (((.bits // {}).cleared // ((.bits // {}).regression_cleared) // 0) == 1)
             then 1 else 0 end)
        | add)
      / $acted
    end
' "$tape" 2>/dev/null)" || ratio=""

if [ -z "$ratio" ]; then
  printf 'probes/__ID__.sh: no acted __CONDITION__ repair outcome in the last %s days\n' \
    "$window" >&2
  exit 1
fi
printf '%.2f\n' "$ratio"
PROBE_EOF
  chmod +x "$probe" || {
    printf 'repair-claim: cannot make the draft probe executable for %s\n' "$id" >&2
    rm -rf "$tmp"
    return 1
  }

  branch="claims/${id}-$(date -u +%Y%m%d%H%M)"

  if ! _repair_claim_open_branch "$branch" "$base"; then
    printf 'repair-claim: could not open branch %s for %s\n' "$branch" "$id" >&2
    rc=1
  fi

  if [ "$rc" -eq 0 ] \
    && ! _repair_claim_put "$branch" "claims/${id}.toml" "$claim" "claims: ${id} ${state}"; then
    printf 'repair-claim: failed to write claims/%s.toml on %s\n' "$id" "$branch" >&2
    rc=1
  fi

  if [ "$rc" -eq 0 ] && ! _repair_claim_probe_exists "$id" "$base"; then
    if ! _repair_claim_put "$branch" "probes/${id}.sh" "$probe" "claims: ${id} ${state}"; then
      printf 'repair-claim: failed to write probes/%s.sh on %s\n' "$id" "$branch" >&2
      rc=1
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    pr_body="$(printf '%s\n' \
      "the ${condition} remedy (${script}) clears the condition it acts on" \
      "" \
      "${failed} of the last ${counted} tries failed (${state}, ${iso})" \
      "" \
      "Script: ${script}" \
      "" \
      "Drafted by the supervisor (proposal-loop.md §5). The gate merges it; tools/claim-proposals.sh makes it a claim proposal and its first check reads the same tape. A lifted revision is a new proposal, checked afresh.")"
    pull_payload="$(jq -n \
      --arg title "claims: ${id} (${state} ${iso})" \
      --arg head "$branch" \
      --arg base "$base" \
      --arg body "$pr_body" \
      '{title: $title, head: $head, base: $base, body: $body}')" || rc=1
    if [ "$rc" -eq 0 ]; then
      pr_json="$(curl -sf -X POST \
        -H "Authorization: token ${FORGE_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$pull_payload" \
        "${api}/pulls")" || rc=1
    fi
    if [ "$rc" -eq 0 ]; then
      pr_number="$(printf '%s' "$pr_json" | jq -r '.number // empty')" || pr_number=""
      [ -n "$pr_number" ] || rc=1
    fi
  fi

  rm -rf "$tmp"
  if [ "$rc" -ne 0 ]; then
    return 1
  fi
  printf '%s\n' "$pr_number"
}
