#!/usr/bin/env bash
# merge-ready.sh — merge sweeper for fully-baked PRs.
#
# Restores hands-free landing: dev's walk-to-merge only covers its own
# claimed issue PRs, so ops PRs (no linked issue) and PRs orphaned by a dead
# author session sat APPROVED-but-open forever, blocking the pipeline behind
# them (#1250 blocked #1227 for 12h+). This sweep merges anything that meets
# ALL of:
#   - open, mergeable=true, no "blocked"/"do-not-merge" label
#   - review-bot formal APPROVE pinned to the current HEAD (#1089 head-aware)
#   - no review-bot REQUEST_CHANGES on the current HEAD
#   - CI success on HEAD (ci_commit_status)
#   - approval older than MERGE_COOLDOWN_MIN (default 30) — human veto window
#
# Runs as dev-bot (merge identity); review stays independent (review-bot
# never merges what it approves). Called from dev-poll.sh each tick.
# Expects: forge_api, ci_commit_status, pr_merge, pr_merge_block_clear,
#          pr_live_reviews, pr_live_review_count, mirror_push, issue_close,
#          log, FORGE_API, FORGE_TOKEN, PROJECT_NAME.
# shellcheck disable=SC2154  # sourced context provides API/helpers

MERGE_COOLDOWN_MIN="${MERGE_COOLDOWN_MIN:-30}"

merge_ready_sweep() {
  local pr_list num sha approved_at
  pr_list=$(forge_api GET "/pulls?state=open&limit=50" 2>/dev/null) || return 0

  for num in $(printf '%s' "$pr_list" | jq -r '.[].number' 2>/dev/null); do
    # --- open + mergeable + labels ---
    local pr_json mergeable labels
    pr_json=$(forge_api GET "/pulls/${num}" 2>/dev/null) || continue
    mergeable=$(printf '%s' "$pr_json" | jq -r '.mergeable // false')
    [ "$mergeable" = "true" ] || continue
    labels=$(printf '%s' "$pr_json" | jq -r '[.labels[].name] | join(",")' 2>/dev/null) || labels=""
    case ",$labels," in
      *,blocked,*|*,do-not-merge,*) continue ;;
    esac
    sha=$(printf '%s' "$pr_json" | jq -r '.head.sha // empty')
    [ -n "$sha" ] || continue

    # --- review-bot verdict on current HEAD (reuse tested helpers) ---
    local reviews_json live_reviews changes_on_head approve_on_head
    reviews_json=$(forge_api GET "/pulls/${num}/reviews" 2>/dev/null) || continue
    live_reviews=$(pr_live_reviews "$reviews_json" "$sha")
    changes_on_head=$(printf '%s' "$live_reviews" | jq -r '[.[] | select(.user.login == "review-bot" and .state == "REQUEST_CHANGES")] | length')
    [ "${changes_on_head:-0}" -gt 0 ] && continue
    approve_on_head=$(printf '%s' "$live_reviews" | jq -r '[.[] | select(.user.login == "review-bot" and .state == "APPROVED")] | sort_by(.submitted_at // .updated_at) | last // empty')
    [ -n "$approve_on_head" ] && [ "$approve_on_head" != "null" ] || continue
    approved_at=$(printf '%s' "$approve_on_head" | jq -r '.submitted_at // .updated_at // empty')
    if [ -n "$approved_at" ]; then
      local age_min approved_ts
      approved_ts=$(date -d "$approved_at" +%s 2>/dev/null) || continue
      age_min=$(( ($(date +%s) - approved_ts) / 60 ))
      [ "$age_min" -ge "$MERGE_COOLDOWN_MIN" ] || continue
    fi

    # --- CI green on HEAD ---
    local ci_state
    ci_state=$(ci_commit_status "$sha" 2>/dev/null) || ci_state="unknown"
    [ "$ci_state" = "success" ] || { log "merge-ready: PR #${num} approved but CI=${ci_state} — skipping"; continue; }

    log "merge-ready: merging PR #${num} (approved, CI green, mergeable)"
    if pr_merge "$num" 2>/dev/null; then
      log "merge-ready: PR #${num} merged"
      pr_merge_block_clear "$num"
      # --- post-merge housekeeping ---
      git -C "${PROJECT_REPO_ROOT:-}" fetch origin "${PRIMARY_BRANCH:-}" 2>/dev/null || true
      git -C "${PROJECT_REPO_ROOT:-}" checkout "${PRIMARY_BRANCH:-}" 2>/dev/null || true
      git -C "${PROJECT_REPO_ROOT:-}" pull --ff-only origin "${PRIMARY_BRANCH:-}" 2>/dev/null || true
      mirror_push
      # linked-issue cleanup (extract same way dev-poll does)
      local linked_issue
      linked_issue=$(printf '%s' "$pr_json" | jq -r '.head.ref // ""' | grep -oP '(?<=fix/issue-)\d+' || true)
      if [ -z "$linked_issue" ]; then
        linked_issue=$(printf '%s' "$pr_json" | jq -r '.title // ""' | grep -oP '#\K\d+' | tail -1 || true)
      fi
      if [ -z "$linked_issue" ]; then
        linked_issue=$(printf '%s' "$pr_json" | jq -r '.body // ""' | grep -oiP '(?:closes?d? |fixes? |resolves? )#\K\d+' | head -1 || true)
      fi
      if [ -n "$linked_issue" ] && [ "$linked_issue" != "0" ]; then
        issue_close "$linked_issue"
        # Remove in-progress label
        local ip_id
        ip_id=$(_ilc_in_progress_id 2>/dev/null) || true
        if [ -n "$ip_id" ]; then
          curl -sf -X DELETE -H "Authorization: token ${FORGE_TOKEN}" "${API}/issues/${linked_issue}/labels/${ip_id}" >/dev/null 2>&1 || true
        fi
        rm -f "/tmp/dev-session-${PROJECT_NAME}-${linked_issue}.sid" \
              "/tmp/dev-impl-summary-${PROJECT_NAME}-${linked_issue}.txt"
      fi
      ci_fix_tracker_reset "$num"
    else
      log "merge-ready: PR #${num} merge failed: ${_PR_MERGE_ERROR:-unknown}"
    fi
  done
}
