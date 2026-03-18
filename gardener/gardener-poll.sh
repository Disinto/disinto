#!/usr/bin/env bash
# =============================================================================
# gardener-poll.sh — Cron wrapper for the gardener agent
#
# Cron: daily (or 2x/day). Handles lock management, escalation reply
# injection, and delegates backlog grooming to gardener-agent.sh.
# Then processes dev-agent CI escalations via the recipe engine.
#
# Grooming (delegated to gardener-agent.sh):
#   - Duplicate titles / overlapping scope
#   - Missing acceptance criteria
#   - Stale issues (no activity > 14 days)
#   - Blockers starving the factory
#   - Tech-debt promotion / dust bundling
#
# CI escalation (recipe-driven, handled here):
#   - ShellCheck per-file sub-issues
#   - Generic CI failure issues
#   - Chicken-egg CI handling
#   - Cascade rebase + retry merge
#   - Flaky test quarantine
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

# Load shared environment (with optional project TOML override)
# Usage: gardener-poll.sh [projects/harb.toml]
export PROJECT_TOML="${1:-}"
# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"

LOG_FILE="$SCRIPT_DIR/gardener.log"
LOCK_FILE="/tmp/gardener-poll.lock"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%S)Z] $*" >> "$LOG_FILE"; }

# ── Lock ──────────────────────────────────────────────────────────────────
if [ -f "$LOCK_FILE" ]; then
  LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || true)
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    log "poll: gardener running (PID $LOCK_PID)"
    exit 0
  fi
  rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

log "--- Gardener poll start ---"

# ── Check for escalation replies from Matrix ──────────────────────────────
ESCALATION_REPLY=""
if [ -s /tmp/gardener-escalation-reply ]; then
  ESCALATION_REPLY=$(cat /tmp/gardener-escalation-reply)
  rm -f /tmp/gardener-escalation-reply
  log "Got escalation reply: $(echo "$ESCALATION_REPLY" | head -1)"
fi
export ESCALATION_REPLY

# ── Inject human replies into needs_human dev sessions (backup to supervisor) ─
HUMAN_REPLY_FILE="/tmp/dev-escalation-reply"
for _gr_phase_file in /tmp/dev-session-"${PROJECT_NAME}"-*.phase; do
  [ -f "$_gr_phase_file" ] || continue
  _gr_phase=$(head -1 "$_gr_phase_file" 2>/dev/null | tr -d '[:space:]' || true)
  [ "$_gr_phase" = "PHASE:needs_human" ] || continue

  _gr_issue=$(basename "$_gr_phase_file" .phase)
  _gr_issue="${_gr_issue#dev-session-${PROJECT_NAME}-}"
  [ -z "$_gr_issue" ] && continue
  _gr_session="dev-${PROJECT_NAME}-${_gr_issue}"

  tmux has-session -t "$_gr_session" 2>/dev/null || continue

  # Atomic claim — only take the file once we know a session needs it
  _gr_claimed="/tmp/dev-escalation-reply.gardener.$$"
  [ -s "$HUMAN_REPLY_FILE" ] && mv "$HUMAN_REPLY_FILE" "$_gr_claimed" 2>/dev/null || continue
  _gr_reply=$(cat "$_gr_claimed")

  _gr_inject_msg="Human reply received for issue #${_gr_issue}:

${_gr_reply}

Instructions:
1. Read the human's guidance carefully.
2. Continue your work based on their input.
3. When done, push your changes and write the appropriate phase."

  _gr_tmpfile=$(mktemp /tmp/human-inject-XXXXXX)
  printf '%s' "$_gr_inject_msg" > "$_gr_tmpfile"
  tmux load-buffer -b "human-inject-${_gr_issue}" "$_gr_tmpfile" || true
  tmux paste-buffer -t "$_gr_session" -b "human-inject-${_gr_issue}" || true
  sleep 0.5
  tmux send-keys -t "$_gr_session" "" Enter || true
  tmux delete-buffer -b "human-inject-${_gr_issue}" 2>/dev/null || true
  rm -f "$_gr_tmpfile" "$_gr_claimed"

  rm -f "/tmp/dev-renotify-${PROJECT_NAME}-${_gr_issue}"
  log "${PROJECT_NAME}: #${_gr_issue} human reply injected into session ${_gr_session} (gardener)"
  break  # only one reply to deliver
done

# ── Backlog grooming (delegated to gardener-agent.sh) ────────────────────
log "Invoking gardener-agent.sh for backlog grooming"
bash "$SCRIPT_DIR/gardener-agent.sh" "${1:-}" || log "WARNING: gardener-agent.sh exited with error"


# ── Recipe matching engine ────────────────────────────────────────────────
RECIPE_DIR="$SCRIPT_DIR/recipes"

# match_recipe — Find first matching recipe for escalation context
# Args: $1=step_names_json  $2=output_file_path  $3=pr_info_json
# Stdout: JSON {name, playbook} — "generic" fallback if no match
match_recipe() {
  _mr_stderr=$(mktemp /tmp/recipe-match-err-XXXXXX)
  _mr_result=$(RECIPE_DIR="$RECIPE_DIR" python3 - "$1" "$2" "$3" 2>"$_mr_stderr" <<'PYEOF'
import sys, os, re, json, glob
try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib  # Python < 3.11 fallback (pip install tomli)

recipe_dir = os.environ["RECIPE_DIR"]
recipes = []
for path in sorted(glob.glob(os.path.join(recipe_dir, "*.toml"))):
    with open(path, "rb") as f:
        recipes.append(tomllib.load(f))

recipes.sort(key=lambda r: r.get("priority", 50))

step_names = json.loads(sys.argv[1])
output_path = sys.argv[2]
pr_info = json.loads(sys.argv[3])

step_output = ""
if os.path.isfile(output_path):
    with open(output_path) as f:
        step_output = f.read()

for recipe in recipes:
    trigger = recipe.get("trigger", {})
    matched = True

    if matched and "step_name" in trigger:
        if not any(re.search(trigger["step_name"], n) for n in step_names):
            matched = False

    if matched and "output" in trigger:
        if not re.search(trigger["output"], step_output):
            matched = False

    if matched and "pr_mergeable" in trigger:
        if pr_info.get("mergeable") != trigger["pr_mergeable"]:
            matched = False

    if matched and "pr_files" in trigger:
        changed = pr_info.get("changed_files", [])
        if not any(re.search(trigger["pr_files"], f) for f in changed):
            matched = False

    if matched and "min_attempts" in trigger:
        if pr_info.get("attempts", 1) < trigger["min_attempts"]:
            matched = False

    if matched and trigger.get("failures_on_unchanged"):
        # Check if errors reference files NOT changed in the PR
        # Patterns: ShellCheck "In file.sh line 5:", generic "file.sh:5:10: error",
        #           ESLint/pylint "file.py:10:5: E123", Go "file.go:5:3:"
        error_files = set()
        error_files.update(re.findall(r"(?<=In )\S+(?= line \d+:)", step_output))
        error_files.update(re.findall(r"^(\S+\.\w+):\d+", step_output, re.MULTILINE))
        changed = set(pr_info.get("changed_files", []))
        if not error_files or error_files <= changed:
            matched = False

    if matched:
        print(json.dumps({"name": recipe["name"], "playbook": recipe.get("playbook", [])}))
        sys.exit(0)

print(json.dumps({"name": "generic", "playbook": [{"action": "create-generic-issue"}]}))
PYEOF
) || true
  if [ -s "$_mr_stderr" ]; then
    log "WARNING: match_recipe error: $(head -3 "$_mr_stderr" | tr '\n' ' ')"
  fi
  rm -f "$_mr_stderr"
  if [ -z "$_mr_result" ] || ! echo "$_mr_result" | jq -e '.name' >/dev/null 2>&1; then
    echo '{"name":"generic","playbook":[{"action":"create-generic-issue"}]}'
  else
    echo "$_mr_result"
  fi
}

# ── Playbook action functions ────────────────────────────────────────────
# Globals used by playbook functions (set by escalation loop):
#   ESC_ISSUE, ESC_PR, ESC_ATTEMPTS, ESC_PIPELINE — escalation context
#   _PB_FAILED_STEPS — "pid\tname" per line of failed CI steps
#   _PB_LOG_DIR — temp dir with step-{pid}.log files
#   _PB_SUB_CREATED — sub-issue counter for current escalation
#   _esc_total_created — running total across all escalations

# Create per-file ShellCheck sub-issues from CI output
playbook_shellcheck_per_file() {
  local step_pid step_name step_log_file step_logs
  while IFS=$'\t' read -r step_pid step_name; do
    [ -z "$step_pid" ] && continue
    echo "$step_name" | grep -qi "shellcheck" || continue
    step_log_file="${_PB_LOG_DIR}/step-${step_pid}.log"
    [ -f "$step_log_file" ] || continue
    step_logs=$(cat "$step_log_file")

    local sc_files
    sc_files=$(echo "$step_logs" | grep -oP '(?<=In )\S+(?= line \d+:)' | sort -u || true)

    local sc_file file_errors sc_codes sub_title sub_body new_issue
    while IFS= read -r sc_file; do
      [ -z "$sc_file" ] && continue
      # grep -F for literal filename match (dots in filenames are regex wildcards)
      file_errors=$(echo "$step_logs" | grep -F -A3 "In ${sc_file} line" | head -30)
      # SC codes only from this file's errors, not the whole step log
      sc_codes=$(echo "$file_errors" | grep -oP 'SC\d+' | sort -u | tr '\n' ' ' | sed 's/ $//' || true)

      sub_title="fix: ShellCheck errors in ${sc_file} (from PR #${ESC_PR})"
      sub_body="## ShellCheck CI failure — \`${sc_file}\`

Spawned by gardener from escalated issue #${ESC_ISSUE} (PR #${ESC_PR} failed CI after ${ESC_ATTEMPTS} attempt(s)).

### Errors
\`\`\`
${file_errors}
\`\`\`

Fix all ShellCheck errors${sc_codes:+ (${sc_codes})} in \`${sc_file}\` so PR #${ESC_PR} CI passes.

### Context
- Parent issue: #${ESC_ISSUE}
- PR: #${ESC_PR}
- Pipeline: #${ESC_PIPELINE} (step: ${step_name})"

      new_issue=$(curl -sf -X POST \
        -H "Authorization: token ${CODEBERG_TOKEN}" \
        -H "Content-Type: application/json" \
        "${CODEBERG_API}/issues" \
        -d "$(jq -nc --arg t "$sub_title" --arg b "$sub_body" \
          '{"title":$t,"body":$b,"labels":["backlog"]}')" 2>/dev/null | jq -r '.number // ""') || true

      if [ -n "$new_issue" ]; then
        log "Created sub-issue #${new_issue}: ShellCheck in ${sc_file} (from #${ESC_ISSUE})"
        _PB_SUB_CREATED=$((_PB_SUB_CREATED + 1))
        _esc_total_created=$((_esc_total_created + 1))
        matrix_send "gardener" "📋 Created sub-issue #${new_issue}: ShellCheck in ${sc_file} (from escalated #${ESC_ISSUE})" 2>/dev/null || true
      fi
    done <<< "$sc_files"
  done <<< "$_PB_FAILED_STEPS"
}

# Create per-file issues from any lint/check CI output (generic — no step name filter)
playbook_lint_per_file() {
  local step_pid step_name step_log_file step_logs
  while IFS=$'\t' read -r step_pid step_name; do
    [ -z "$step_pid" ] && continue
    step_log_file="${_PB_LOG_DIR}/step-${step_pid}.log"
    [ -f "$step_log_file" ] || continue
    step_logs=$(cat "$step_log_file")

    # Extract unique file paths from lint output (multiple formats):
    #   ShellCheck: "In file.sh line 5:"
    #   Generic:    "file.sh:5:10: error"
    local lint_files
    lint_files=$( {
      echo "$step_logs" | grep -oP '(?<=In )\S+(?= line \d+:)' || true
      echo "$step_logs" | grep -oP '^\S+\.\w+(?=:\d+)' || true
    } | sort -u)

    local lint_file file_errors sc_codes sub_title sub_body new_issue
    while IFS= read -r lint_file; do
      [ -z "$lint_file" ] && continue
      # Extract errors for this file (try both formats)
      file_errors=$(echo "$step_logs" | grep -F -A3 "In ${lint_file} line" 2>/dev/null | head -30 || true)
      if [ -z "$file_errors" ]; then
        file_errors=$(echo "$step_logs" | grep -F "${lint_file}:" | head -30 || true)
      fi
      [ -z "$file_errors" ] && continue
      # Extract SC codes if present (harmless for non-ShellCheck output)
      sc_codes=$(echo "$file_errors" | grep -oP 'SC\d+' | sort -u | tr '\n' ' ' | sed 's/ $//' || true)

      sub_title="fix: lint errors in ${lint_file} (from PR #${ESC_PR})"
      sub_body="## Lint CI failure — \`${lint_file}\`

Spawned by gardener from escalated issue #${ESC_ISSUE} (PR #${ESC_PR} failed CI after ${ESC_ATTEMPTS} attempt(s)).

### Errors
\`\`\`
${file_errors}
\`\`\`

Fix all errors${sc_codes:+ (${sc_codes})} in \`${lint_file}\` so PR #${ESC_PR} CI passes.

### Context
- Parent issue: #${ESC_ISSUE}
- PR: #${ESC_PR}
- Pipeline: #${ESC_PIPELINE} (step: ${step_name})"

      new_issue=$(curl -sf -X POST \
        -H "Authorization: token ${CODEBERG_TOKEN}" \
        -H "Content-Type: application/json" \
        "${CODEBERG_API}/issues" \
        -d "$(jq -nc --arg t "$sub_title" --arg b "$sub_body" \
          '{"title":$t,"body":$b,"labels":["backlog"]}')" 2>/dev/null | jq -r '.number // ""') || true

      if [ -n "$new_issue" ]; then
        log "Created sub-issue #${new_issue}: lint in ${lint_file} (from #${ESC_ISSUE})"
        _PB_SUB_CREATED=$((_PB_SUB_CREATED + 1))
        _esc_total_created=$((_esc_total_created + 1))
        matrix_send "gardener" "📋 Created sub-issue #${new_issue}: lint in ${lint_file} (from escalated #${ESC_ISSUE})" 2>/dev/null || true
      fi
    done <<< "$lint_files"
  done <<< "$_PB_FAILED_STEPS"
}

# Create one combined issue for non-ShellCheck CI failures
playbook_create_generic_issue() {
  local generic_fail="" step_pid step_name step_log_file step_logs esc_section
  while IFS=$'\t' read -r step_pid step_name; do
    [ -z "$step_pid" ] && continue
    # Skip shellcheck steps (handled by shellcheck-per-file action)
    echo "$step_name" | grep -qi "shellcheck" && continue
    step_log_file="${_PB_LOG_DIR}/step-${step_pid}.log"
    [ -f "$step_log_file" ] || continue
    step_logs=$(cat "$step_log_file")

    esc_section="=== ${step_name} ===
$(echo "$step_logs" | tail -50)"
    if [ -z "$generic_fail" ]; then
      generic_fail="$esc_section"
    else
      generic_fail="${generic_fail}
${esc_section}"
    fi
  done <<< "$_PB_FAILED_STEPS"

  [ -z "$generic_fail" ] && return 0

  local sub_title sub_body new_issue
  sub_title="fix: CI failures in PR #${ESC_PR} (from issue #${ESC_ISSUE})"
  sub_body="## CI failure — fix required

Spawned by gardener from escalated issue #${ESC_ISSUE} (PR #${ESC_PR} failed CI after ${ESC_ATTEMPTS} attempt(s)).

### Failed step output
\`\`\`
${generic_fail}
\`\`\`

### Context
- Parent issue: #${ESC_ISSUE}
- PR: #${ESC_PR}${ESC_PIPELINE:+
- Pipeline: #${ESC_PIPELINE}}"

  new_issue=$(curl -sf -X POST \
    -H "Authorization: token ${CODEBERG_TOKEN}" \
    -H "Content-Type: application/json" \
    "${CODEBERG_API}/issues" \
    -d "$(jq -nc --arg t "$sub_title" --arg b "$sub_body" \
      '{"title":$t,"body":$b,"labels":["backlog"]}')" 2>/dev/null | jq -r '.number // ""') || true

  if [ -n "$new_issue" ]; then
    log "Created sub-issue #${new_issue}: CI failures for PR #${ESC_PR} (from #${ESC_ISSUE})"
    _PB_SUB_CREATED=$((_PB_SUB_CREATED + 1))
    _esc_total_created=$((_esc_total_created + 1))
    matrix_send "gardener" "📋 Created sub-issue #${new_issue}: CI failures for PR #${ESC_PR} (from escalated #${ESC_ISSUE})" 2>/dev/null || true
  fi
}

# Create issue to make failing CI step non-blocking (chicken-egg-ci)
playbook_make_step_non_blocking() {
  local failing_steps sub_title sub_body new_issue
  failing_steps=$(echo "$_PB_FAILED_STEPS" | cut -f2 | tr '\n' ', ' | sed 's/,$//' || true)

  sub_title="fix: make CI step non-blocking for pre-existing failures (PR #${ESC_PR})"
  sub_body="## Chicken-egg CI failure

PR #${ESC_PR} (issue #${ESC_ISSUE}) introduces a CI step that fails on pre-existing code.

Failing step(s): ${failing_steps}

### Playbook
1. Add \`|| true\` to the failing step(s) in the Woodpecker config
2. This makes the step advisory (non-blocking) until pre-existing violations are fixed

### Context
- Parent issue: #${ESC_ISSUE}
- PR: #${ESC_PR}${ESC_PIPELINE:+
- Pipeline: #${ESC_PIPELINE}}"

  new_issue=$(curl -sf -X POST \
    -H "Authorization: token ${CODEBERG_TOKEN}" \
    -H "Content-Type: application/json" \
    "${CODEBERG_API}/issues" \
    -d "$(jq -nc --arg t "$sub_title" --arg b "$sub_body" \
      '{"title":$t,"body":$b,"labels":["backlog"]}')" 2>/dev/null | jq -r '.number // ""') || true

  if [ -n "$new_issue" ]; then
    log "Created #${new_issue}: make step non-blocking (chicken-egg from #${ESC_ISSUE})"
    _PB_SUB_CREATED=$((_PB_SUB_CREATED + 1))
    _esc_total_created=$((_esc_total_created + 1))
    matrix_send "gardener" "📋 Created #${new_issue}: make CI step non-blocking (chicken-egg, from #${ESC_ISSUE})" 2>/dev/null || true
  fi
}

# Create follow-up issue to remove || true bypass (chicken-egg-ci)
playbook_create_followup_remove_bypass() {
  local sub_title sub_body new_issue
  sub_title="fix: remove || true bypass once pre-existing violations are fixed (PR #${ESC_PR})"
  sub_body="## Follow-up: remove CI bypass

After all pre-existing violation issues from PR #${ESC_PR} are resolved, remove the \`|| true\` bypass from the CI step to make it blocking again.

### Depends on
All per-file fix issues created from escalated issue #${ESC_ISSUE}.

### Context
- Parent issue: #${ESC_ISSUE}
- PR: #${ESC_PR}"

  new_issue=$(curl -sf -X POST \
    -H "Authorization: token ${CODEBERG_TOKEN}" \
    -H "Content-Type: application/json" \
    "${CODEBERG_API}/issues" \
    -d "$(jq -nc --arg t "$sub_title" --arg b "$sub_body" \
      '{"title":$t,"body":$b,"labels":["backlog"]}')" 2>/dev/null | jq -r '.number // ""') || true

  if [ -n "$new_issue" ]; then
    log "Created follow-up #${new_issue}: remove bypass (from #${ESC_ISSUE})"
    _PB_SUB_CREATED=$((_PB_SUB_CREATED + 1))
    _esc_total_created=$((_esc_total_created + 1))
  fi
}

# Rebase PR onto main branch (cascade-rebase)
playbook_rebase_pr() {
  log "Rebasing PR #${ESC_PR} onto ${PRIMARY_BRANCH}"
  local result
  local http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: token ${CODEBERG_TOKEN}" \
    -H "Content-Type: application/json" \
    "${CODEBERG_API}/pulls/${ESC_PR}/update" \
    -d '{"style":"rebase"}' 2>/dev/null) || true

  if [ "${http_code:-0}" -ge 200 ] && [ "${http_code:-0}" -lt 300 ]; then
    log "Rebase initiated for PR #${ESC_PR} (HTTP ${http_code})"
    _PB_SUB_CREATED=$((_PB_SUB_CREATED + 1))
    matrix_send "gardener" "🔄 Rebased PR #${ESC_PR} onto ${PRIMARY_BRANCH} (cascade-rebase, from #${ESC_ISSUE})" 2>/dev/null || true
  else
    log "WARNING: rebase API call failed for PR #${ESC_PR} (HTTP ${http_code:-error})"
  fi
}

# Re-approve PR if review was dismissed by force-push (cascade-rebase)
playbook_re_approve_if_dismissed() {
  local reviews dismissed
  reviews=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${CODEBERG_API}/pulls/${ESC_PR}/reviews" 2>/dev/null || true)
  [ -z "$reviews" ] || [ "$reviews" = "null" ] && return 0

  dismissed=$(echo "$reviews" | jq -r '[.[] | select(.state == "APPROVED" and .dismissed == true)] | length' 2>/dev/null || true)
  if [ "${dismissed:-0}" -gt 0 ]; then
    curl -sf -X POST \
      -H "Authorization: token ${CODEBERG_TOKEN}" \
      -H "Content-Type: application/json" \
      "${CODEBERG_API}/pulls/${ESC_PR}/reviews" \
      -d '{"event":"APPROVED","body":"Re-approved after rebase (cascade-rebase recipe)"}' 2>/dev/null || true
    log "Re-approved PR #${ESC_PR} after rebase"
    _PB_SUB_CREATED=$((_PB_SUB_CREATED + 1))
  fi
}

# Retry merging the PR (cascade-rebase)
playbook_retry_merge() {
  local result
  result=$(curl -sf -X POST \
    -H "Authorization: token ${CODEBERG_TOKEN}" \
    -H "Content-Type: application/json" \
    "${CODEBERG_API}/pulls/${ESC_PR}/merge" \
    -d '{"Do":"rebase","delete_branch_after_merge":true}' 2>/dev/null) || true

  if [ -n "$result" ]; then
    log "Merge retry initiated for PR #${ESC_PR}"
    _PB_SUB_CREATED=$((_PB_SUB_CREATED + 1))
    matrix_send "gardener" "✅ Merge retry for PR #${ESC_PR} (cascade-rebase, from #${ESC_ISSUE})" 2>/dev/null || true
  else
    log "WARNING: merge retry failed for PR #${ESC_PR}"
  fi
}

# Retrigger CI pipeline (flaky-test)
playbook_retrigger_ci() {
  [ -z "$ESC_PIPELINE" ] && return 0
  # Max 2 retriggers per issue spec
  if [ "${ESC_ATTEMPTS:-1}" -ge 3 ]; then
    log "Max retriggers reached for pipeline #${ESC_PIPELINE} (${ESC_ATTEMPTS} attempts)"
    return 0
  fi
  log "Retriggering CI pipeline #${ESC_PIPELINE} (attempt ${ESC_ATTEMPTS})"
  local http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer ${WOODPECKER_TOKEN}" \
    "${WOODPECKER_SERVER}/api/repos/${WOODPECKER_REPO_ID}/pipelines/${ESC_PIPELINE}" 2>/dev/null) || true

  if [ "${http_code:-0}" -ge 200 ] && [ "${http_code:-0}" -lt 300 ]; then
    log "Pipeline #${ESC_PIPELINE} retriggered (HTTP ${http_code})"
    _PB_SUB_CREATED=$((_PB_SUB_CREATED + 1))
    matrix_send "gardener" "🔄 Retriggered CI for PR #${ESC_PR} (flaky-test, attempt ${ESC_ATTEMPTS})" 2>/dev/null || true
  else
    log "WARNING: retrigger failed for pipeline #${ESC_PIPELINE} (HTTP ${http_code:-error})"
  fi
}

# Quarantine flaky test and create fix issue (flaky-test)
playbook_quarantine_test() {
  # Only quarantine if retriggers exhausted
  if [ "${ESC_ATTEMPTS:-1}" -lt 3 ]; then
    return 0
  fi

  local failing_steps sub_title sub_body new_issue
  failing_steps=$(echo "$_PB_FAILED_STEPS" | cut -f2 | tr '\n' ', ' | sed 's/,$//' || true)

  sub_title="fix: quarantine flaky test (PR #${ESC_PR}, from #${ESC_ISSUE})"
  sub_body="## Flaky test detected

CI for PR #${ESC_PR} (issue #${ESC_ISSUE}) failed intermittently across ${ESC_ATTEMPTS} attempts.

Failing step(s): ${failing_steps:-unknown}

### Playbook
1. Identify the flaky test(s) from CI output
2. Quarantine (skip/mark pending) the flaky test(s)
3. Create targeted fix for the root cause

### Context
- Parent issue: #${ESC_ISSUE}
- PR: #${ESC_PR}${ESC_PIPELINE:+
- Pipeline: #${ESC_PIPELINE}}"

  new_issue=$(curl -sf -X POST \
    -H "Authorization: token ${CODEBERG_TOKEN}" \
    -H "Content-Type: application/json" \
    "${CODEBERG_API}/issues" \
    -d "$(jq -nc --arg t "$sub_title" --arg b "$sub_body" \
      '{"title":$t,"body":$b,"labels":["backlog"]}')" 2>/dev/null | jq -r '.number // ""') || true

  if [ -n "$new_issue" ]; then
    log "Created quarantine issue #${new_issue} for flaky test (from #${ESC_ISSUE})"
    _PB_SUB_CREATED=$((_PB_SUB_CREATED + 1))
    _esc_total_created=$((_esc_total_created + 1))
    matrix_send "gardener" "📋 Created #${new_issue}: quarantine flaky test (from #${ESC_ISSUE})" 2>/dev/null || true
  fi
}

# run_playbook — Execute matched recipe's playbook actions
# Args: $1=recipe_json from match_recipe
run_playbook() {
  local recipe_json="$1"
  local recipe_name actions action
  recipe_name=$(echo "$recipe_json" | jq -r '.name')
  actions=$(echo "$recipe_json" | jq -r '.playbook[].action' 2>/dev/null || true)

  while IFS= read -r action; do
    [ -z "$action" ] && continue
    case "$action" in
      shellcheck-per-file)           playbook_shellcheck_per_file ;;
      lint-per-file)                 playbook_lint_per_file ;;
      create-generic-issue)          playbook_create_generic_issue ;;
      make-step-non-blocking)        playbook_make_step_non_blocking ;;
      create-followup-remove-bypass) playbook_create_followup_remove_bypass ;;
      rebase-pr)                     playbook_rebase_pr ;;
      re-approve-if-dismissed)       playbook_re_approve_if_dismissed ;;
      retry-merge)                   playbook_retry_merge ;;
      retrigger-ci)                  playbook_retrigger_ci ;;
      quarantine-test)               playbook_quarantine_test ;;
      label-backlog)                 ;; # default label, no-op (issues created with backlog)
      *)                             log "WARNING: unknown playbook action '${action}' in recipe '${recipe_name}'" ;;
    esac
  done <<< "$actions"
}

# ── Process dev-agent escalations (per-project, recipe-driven) ───────────
ESCALATION_FILE="${FACTORY_ROOT}/supervisor/escalations-${PROJECT_NAME}.jsonl"
ESCALATION_DONE="${FACTORY_ROOT}/supervisor/escalations-${PROJECT_NAME}.done.jsonl"

if [ -s "$ESCALATION_FILE" ]; then
  # Atomically snapshot the file before processing to prevent race with
  # concurrent dev-poll appends: new entries go to a fresh ESCALATION_FILE
  # while we process the snapshot, so nothing is ever silently dropped.
  ESCALATION_SNAP="${ESCALATION_FILE}.processing.$$"
  mv "$ESCALATION_FILE" "$ESCALATION_SNAP"

  ESCALATION_COUNT=$(wc -l < "$ESCALATION_SNAP")
  log "Processing ${ESCALATION_COUNT} escalation(s) for ${PROJECT_NAME}"
  _esc_total_created=0

  while IFS= read -r esc_entry; do
    [ -z "$esc_entry" ] && continue

    ESC_ISSUE=$(echo "$esc_entry" | jq -r '.issue // empty')
    ESC_PR=$(echo "$esc_entry" | jq -r '.pr // empty')
    ESC_ATTEMPTS=$(echo "$esc_entry" | jq -r '.attempts // 3')
    ESC_REASON=$(echo "$esc_entry" | jq -r '.reason // empty')

    if [ -z "$ESC_ISSUE" ] || [ -z "$ESC_PR" ]; then
      echo "$esc_entry" >> "$ESCALATION_DONE"
      continue
    fi

    log "Escalation: issue #${ESC_ISSUE} PR #${ESC_PR} reason=${ESC_REASON} (${ESC_ATTEMPTS} CI attempt(s))"

    # Handle idle_timeout escalations — no CI steps to inspect, just notify
    if [[ "$ESC_REASON" == idle_timeout* ]]; then
      _issue_url="https://codeberg.org/${CODEBERG_REPO}/issues/${ESC_ISSUE}"
      sub_title="chore: investigate idle timeout for issue #${ESC_ISSUE}"
      sub_body="## Dev-agent idle timeout

The dev-agent session for issue #${ESC_ISSUE} was idle for 2h without a phase update and was killed.$([ "${ESC_PR:-0}" != "0" ] && printf '\n\nPR #%s may still be open.' "$ESC_PR")

### What to check
1. Was the agent stuck waiting for input? Check the issue spec for ambiguity.
2. Was there an infrastructure issue (tmux crash, disk full, etc.)?
3. Re-run the issue by restoring the \`backlog\` label if the spec is clear.

### Context
- Issue: [#${ESC_ISSUE}](${_issue_url})$([ "${ESC_PR:-0}" != "0" ] && printf '\n- PR: #%s' "$ESC_PR")"

      new_issue=$(curl -sf -X POST \
        -H "Authorization: token ${CODEBERG_TOKEN}" \
        -H "Content-Type: application/json" \
        "${CODEBERG_API}/issues" \
        -d "$(jq -nc --arg t "$sub_title" --arg b "$sub_body" \
          '{"title":$t,"body":$b,"labels":["backlog"]}')" 2>/dev/null | jq -r '.number // ""') || true

      if [ -n "$new_issue" ]; then
        log "Created idle-timeout sub-issue #${new_issue} for #${ESC_ISSUE}"
        _esc_total_created=$((_esc_total_created + 1))
        matrix_send "gardener" "⏱ Created #${new_issue}: idle timeout on #${ESC_ISSUE}" 2>/dev/null || true
      fi

      echo "$esc_entry" >> "$ESCALATION_DONE"
      continue
    fi

    # Fetch PR metadata (SHA, mergeable status)
    ESC_PR_DATA=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${CODEBERG_API}/pulls/${ESC_PR}" 2>/dev/null || true)
    ESC_PR_SHA=$(echo "$ESC_PR_DATA" | jq -r '.head.sha // ""' 2>/dev/null || true)
    _PB_PR_MERGEABLE=$(echo "$ESC_PR_DATA" | jq '.mergeable // null' 2>/dev/null || true)

    ESC_PIPELINE=""
    if [ -n "$ESC_PR_SHA" ]; then
      # Validate SHA is a 40-char hex string before interpolating into SQL
      if [[ "$ESC_PR_SHA" =~ ^[0-9a-fA-F]{40}$ ]]; then
        ESC_PIPELINE=$(wpdb -c "SELECT number FROM pipelines WHERE repo_id=${WOODPECKER_REPO_ID} AND commit='${ESC_PR_SHA}' ORDER BY created DESC LIMIT 1;" 2>/dev/null | xargs || true)
      else
        log "WARNING: ESC_PR_SHA '${ESC_PR_SHA}' is not a valid hex SHA — skipping pipeline lookup"
      fi
    fi

    # Fetch failed CI steps and their logs into temp dir
    _PB_FAILED_STEPS=""
    _PB_LOG_DIR=$(mktemp -d /tmp/recipe-logs-XXXXXX)
    _PB_SUB_CREATED=0
    _PB_LOGS_AVAILABLE=0

    if [ -n "$ESC_PIPELINE" ]; then
      _PB_FAILED_STEPS=$(curl -sf \
        -H "Authorization: Bearer ${WOODPECKER_TOKEN}" \
        "${WOODPECKER_SERVER}/api/repos/${WOODPECKER_REPO_ID}/pipelines/${ESC_PIPELINE}" 2>/dev/null | \
        jq -r '.workflows[]?.children[]? | select(.state=="failure") | "\(.pid)\t\(.name)"' 2>/dev/null || true)

      while IFS=$'\t' read -r step_pid step_name; do
        [ -z "$step_pid" ] && continue
        [[ "$step_pid" =~ ^[0-9]+$ ]] || { log "WARNING: invalid step_pid '${step_pid}' — skipping"; continue; }
        step_logs=$(woodpecker-cli pipeline log show "${CODEBERG_REPO}" "${ESC_PIPELINE}" "${step_pid}" 2>/dev/null | tail -150 || true)
        if [ -n "$step_logs" ]; then
          echo "$step_logs" > "${_PB_LOG_DIR}/step-${step_pid}.log"
          _PB_LOGS_AVAILABLE=1
        fi
      done <<< "$_PB_FAILED_STEPS"
    fi

    # Fetch PR changed files for recipe matching
    _PB_PR_FILES_JSON="[]"
    _PB_PR_FILES=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${CODEBERG_API}/pulls/${ESC_PR}/files" 2>/dev/null | jq -r '.[].filename // empty' 2>/dev/null || true)
    if [ -n "$_PB_PR_FILES" ]; then
      _PB_PR_FILES_JSON=$(echo "$_PB_PR_FILES" | jq -Rsc 'split("\n") | map(select(length > 0))')
    fi

    # Build recipe matching context
    _RECIPE_STEP_NAMES=$(echo "$_PB_FAILED_STEPS" | cut -f2 | jq -Rsc 'split("\n") | map(select(length > 0))')
    _RECIPE_OUTPUT_FILE="${_PB_LOG_DIR}/all-output.txt"
    cat "${_PB_LOG_DIR}"/step-*.log > "$_RECIPE_OUTPUT_FILE" 2>/dev/null || touch "$_RECIPE_OUTPUT_FILE"
    _RECIPE_PR_INFO=$(jq -nc \
      --argjson m "${_PB_PR_MERGEABLE:-null}" \
      --argjson a "${ESC_ATTEMPTS}" \
      --argjson files "${_PB_PR_FILES_JSON}" \
      '{mergeable:$m, attempts:$a, changed_files:$files}')

    # Match escalation against recipes and execute playbook
    MATCHED_RECIPE=$(match_recipe "$_RECIPE_STEP_NAMES" "$_RECIPE_OUTPUT_FILE" "$_RECIPE_PR_INFO")
    RECIPE_NAME=$(echo "$MATCHED_RECIPE" | jq -r '.name')
    log "Recipe matched: ${RECIPE_NAME} for #${ESC_ISSUE} PR #${ESC_PR}"

    run_playbook "$MATCHED_RECIPE"

    # Fallback: no sub-issues created — create investigation issue
    if [ "$_PB_SUB_CREATED" -eq 0 ]; then
      sub_title="fix: investigate CI failure for PR #${ESC_PR} (from issue #${ESC_ISSUE})"
      if [ "$_PB_LOGS_AVAILABLE" -eq 1 ]; then
        sub_body="## CI failure — investigation required

Spawned by gardener from escalated issue #${ESC_ISSUE} (PR #${ESC_PR} failed CI after ${ESC_ATTEMPTS} attempt(s)). Recipe '${RECIPE_NAME}' matched but produced no sub-issues.

Check PR #${ESC_PR} CI output, identify the failing checks, and fix them so the PR can merge."
      else
        sub_body="## CI failure — investigation required

Spawned by gardener from escalated issue #${ESC_ISSUE} (PR #${ESC_PR} failed CI after ${ESC_ATTEMPTS} attempt(s)). CI logs were unavailable at escalation time.

Check PR #${ESC_PR} CI output, identify the failing checks, and fix them so the PR can merge."
      fi

      new_issue=$(curl -sf -X POST \
        -H "Authorization: token ${CODEBERG_TOKEN}" \
        -H "Content-Type: application/json" \
        "${CODEBERG_API}/issues" \
        -d "$(jq -nc --arg t "$sub_title" --arg b "$sub_body" \
          '{"title":$t,"body":$b,"labels":["backlog"]}')" 2>/dev/null | jq -r '.number // ""') || true

      if [ -n "$new_issue" ]; then
        log "Created fallback sub-issue #${new_issue} for escalated #${ESC_ISSUE}"
        _esc_total_created=$((_esc_total_created + 1))
        matrix_send "gardener" "📋 Created sub-issue #${new_issue}: investigate CI for PR #${ESC_PR} (from escalated #${ESC_ISSUE})" 2>/dev/null || true
      fi
    fi

    # Cleanup temp files
    rm -rf "$_PB_LOG_DIR"

    # Mark as processed
    echo "$esc_entry" >> "$ESCALATION_DONE"
  done < "$ESCALATION_SNAP"

  rm -f "$ESCALATION_SNAP"
  log "Escalations processed — moved to $(basename "$ESCALATION_DONE")"

  # Report resolution count to supervisor for its fixed() summary
  if [ "${_esc_total_created:-0}" -gt 0 ]; then
    printf '%d %s\n' "$_esc_total_created" "$PROJECT_NAME" \
      >> "${FACTORY_ROOT}/supervisor/gardener-esc-resolved.log"
  fi
fi

log "--- Gardener poll done ---"
