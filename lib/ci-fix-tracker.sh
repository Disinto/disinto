#!/usr/bin/env bash
# ci-fix-tracker.sh — Per-PR CI fix counter with exhaustion detection.
#
# Persists to $CI_FIX_TRACKER as JSON: {"<pr>": <count>, ...}.
# Locks via flock on $CI_FIX_LOCK.
#
# Usage (from a caller that already sourced this file):
#   ci_fix_tracker_init                  # set $CI_FIX_TRACKER / $CI_FIX_LOCK from env
#   count=$(ci_fix_tracker_count "$pr")  # echo current count (0 if missing)
#   ci_fix_tracker_reset "$pr"           # remove entry for PR
#   result=$(ci_fix_tracker_check_and_increment "$pr" [check_only])
#                                        # echo "ok:N", "exhausted:N", or "exhausted_first_time:3"
#
# Exhaustion semantics (max 3 fix attempts):
#   count == 0..2  → ok:N       (increments to N+1)
#   count == 3     → exhausted_first_time:3  (bumps to 4, marks exhausted)
#   count >= 4     → exhausted:N (no further increment)
#   check_only     → ok:N without incrementing (only when count < 3; count >= 3 still returns exhausted)

# Ensure tracker file exists.
# Must be called before any other function.
ci_fix_tracker_init() {
  CI_FIX_TRACKER="${DISINTO_LOG_DIR}/dev/ci-fixes-${PROJECT_NAME:-default}.json"
  CI_FIX_LOCK="${CI_FIX_TRACKER}.lock"
  mkdir -p "$(dirname "$CI_FIX_TRACKER")"
  touch "$CI_FIX_TRACKER" 2>/dev/null || true
  touch "$CI_FIX_LOCK" 2>/dev/null || true
}

# ci_fix_tracker_count PR
# Echoes the current fix count for PR (0 if missing or tracker empty).
ci_fix_tracker_count() {
  local pr="$1"
  (
    flock -s 200 || exit 1
    if [ ! -s "$CI_FIX_TRACKER" ]; then
      echo 0
      return
    fi
    local val
    val=$(jq --arg pr "$pr" '.[$pr] // 0' "$CI_FIX_TRACKER" 2>/dev/null) || { echo 0; return; }
    echo "$val"
  ) 200>"$CI_FIX_LOCK"
}

# ci_fix_tracker_reset PR
# Removes the entry for PR from the tracker.
ci_fix_tracker_reset() {
  local pr="$1"
  (
    flock 200 || exit 1
    if [ ! -s "$CI_FIX_TRACKER" ]; then
      echo "{}" > "$CI_FIX_TRACKER"
    fi
    local tmp="${CI_FIX_TRACKER}.tmp.$$"
    if jq --arg pr "$pr" 'del(.[$pr])' "$CI_FIX_TRACKER" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$CI_FIX_TRACKER"
    else
      rm -f "$tmp"
    fi
  ) 200>"$CI_FIX_LOCK"
}

# ci_fix_tracker_check_and_increment PR [check_only]
# Reads (and optionally increments) the counter for PR under flock.
#
# Output:
#   ok:<N>                  — count was < 3, now stored as <N+1>
#   exhausted_first_time:3  — count was exactly 3, bumped to 4
#   exhausted:<N>           — count >= 4 (or already exhausted)
#
# If check_only is set, returns ok:<N> without modifying the file.
ci_fix_tracker_check_and_increment() {
  local pr="$1"
  local check_only="${2:-}"
  (
    flock 200 || exit 1
    if [ ! -s "$CI_FIX_TRACKER" ]; then
      echo "{}" > "$CI_FIX_TRACKER"
    fi

    local tmp="${CI_FIX_TRACKER}.tmp.$$"

    # Compute result string with jq
    local output
    output=$(jq -r --arg pr "$pr" --arg co "$check_only" \
      '. // {} | ((.[$pr] // 0)) as $count |
       if $count > 3 then "exhausted:\($count)"
       elif $count == 3 then "exhausted_first_time:3"
       elif $co == "check_only" then "ok:\($count)"
       else "ok:\($count + 1)"
       end' "$CI_FIX_TRACKER" 2>/dev/null) || { echo "exhausted:99"; return; }

    local result="$output"

    # Write back if mutation needed
    case "$result" in
      ok:*)
        if [ "$check_only" != "check_only" ]; then
          local new_count="${result#ok:}"
          if jq --arg pr "$pr" --argjson c "$new_count" '.[$pr] = $c' "$CI_FIX_TRACKER" > "$tmp" 2>/dev/null; then
            mv "$tmp" "$CI_FIX_TRACKER"
          else
            rm -f "$tmp"
          fi
        fi
        ;;
      exhausted_first_time:*)
        if jq --arg pr "$pr" '.[$pr] = 4' "$CI_FIX_TRACKER" > "$tmp" 2>/dev/null; then
          mv "$tmp" "$CI_FIX_TRACKER"
        else
          rm -f "$tmp"
        fi
        ;;
      *)
        rm -f "$tmp"
        ;;
    esac

    echo "$result"
  ) 200>"$CI_FIX_LOCK"
}
