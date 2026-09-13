#!/usr/bin/env bash
# Acceptance test for issue #1315 — Research-mode architect files experiment sub-issues.
#
# Verifies the research-mode architect pipeline:
#   - architect-run.sh selects formulas/run-architect-research.toml when
#     PROJECT_KIND=research, and keeps formulas/run-architect.toml for every
#     other kind (software path unchanged)
#   - the research formula decomposes campaigns (not product sprints) into
#     experiment filer entries (experiment label + #1295 template fields),
#     defines tracking green as run-ledger exit 0 + artifacts present (NOT
#     the deployed label), and keeps the architect read-only on the project repo
#   - formulas/file-subissues.toml is kind-aware: it posts the `experiment`
#     label for research instead of `backlog`
#   - the tracking green gate is kind-aware bash: research green = the
#     issue's `<!-- action-id: <id> -->` marker has a run-ledger row with
#     exit 0 and a non-empty artifacts array (no closed/deployed/acceptance
#     requirement); software green stays closed + deployed + acceptance rc=0;
#     the ops clone is refreshed per run via ensure_ops_repo
#   - architect/AGENTS.md documents the selection + green-gate definitions
#
# Acceptance criteria coverage:
#   - software kind still uses the existing architect formula   (selection check)
#   - research kind uses a formula whose filer entries are      (research-formula checks)
#     experiment issues (experiment label, not backlog)
#   - tracking text defines green as run record + artifact,     (research-formula + AGENTS.md checks)
#     not deployed
#   - architect-bot remains read-only on the project repo       (guard + formula checks)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/acceptance-helpers.sh"

ac_require_cmd bash grep python3

# ── Files under test ─────────────────────────────────────────────────────────
ARCH_RUN="$REPO_ROOT/architect/architect-run.sh"
SW_FORMULA="$REPO_ROOT/formulas/run-architect.toml"
RS_FORMULA="$REPO_ROOT/formulas/run-architect-research.toml"
FILER_FORMULA="$REPO_ROOT/formulas/file-subissues.toml"
ARCH_AGENTS="$REPO_ROOT/architect/AGENTS.md"

ac_assert_file "$ARCH_RUN" "architect runner script missing"
ac_assert_file "$SW_FORMULA" "software architect formula missing"
ac_assert_file "$RS_FORMULA" "research architect formula missing (#1315)"
ac_assert_file "$FILER_FORMULA" "filer formula missing"
ac_assert_file "$ARCH_AGENTS" "architect AGENTS.md missing"

# ── Formula selection branches on PROJECT_KIND (software default) ────────────
PICK_FN="$(ac_extract_fn architect_formula_file "$ARCH_RUN")"

ac_log "verifying architect formula selection on PROJECT_KIND"

pick() {
  PICK_KIND="${1:-}" PICK_FN="$PICK_FN" FACTORY_ROOT="$REPO_ROOT" bash -c '
    set -u
    [ -n "${PICK_KIND:-}" ] && export PROJECT_KIND="$PICK_KIND"
    eval "$PICK_FN"
    architect_formula_file
  ' 2>&1
}

# Unset kind → software default → existing software formula (unchanged).
ac_assert_eq "$(pick "" )" "$REPO_ROOT/formulas/run-architect.toml" "unset PROJECT_KIND must keep the software architect formula"
# Explicit software kind → same existing formula.
ac_assert_eq "$(pick software)" "$REPO_ROOT/formulas/run-architect.toml" "software PROJECT_KIND must keep the existing architect formula"
# Research kind → the new research formula.
ac_assert_eq "$(pick research)" "$REPO_ROOT/formulas/run-architect-research.toml" "research PROJECT_KIND must select run-architect-research.toml (#1315)"

# ── Software path still intact ───────────────────────────────────────────────
# Both dispatch sites load via the kind-selected variable.
ac_log "verifying software dispatch path intact"
[ "$(grep -cF 'load_formula_or_profile "architect" "$ARCHITECT_FORMULA"' "$ARCH_RUN")" -ge 2 ] \
  || ac_fail "both architect dispatch sites must load the kind-selected formula"
# The bash regression guard (read-only contract, #764) must still run in main.
grep -qE '^check_architect_issue_filing[[:space:]]*$' "$ARCH_RUN" \
  || ac_fail "read-only regression guard no longer called in main"
# The software tracking-green definition literal must survive.
grep -qF 'TRACKING_GREEN_DEF="closed AND has deployed label AND acceptance test rc=0"' "$ARCH_RUN" \
  || ac_fail "software tracking-green literal removed"
# The software formula stays sprint-shaped (backlog filer entries).
grep -qF 'labels: [backlog]' "$SW_FORMULA" \
  || ac_fail "software run-architect.toml no longer sprint-shaped (backlog filer entries gone)"

# ── Research formula content ─────────────────────────────────────────────────
ac_log "verifying research architect formula"

python3 -c "import tomllib; tomllib.load(open('$RS_FORMULA','rb'))" \
  || ac_fail "research formula is not valid TOML"

# Campaigns, not product sprints.
grep -qi "campaign" "$RS_FORMULA" || ac_fail "research formula does not decompose campaigns"

# Filer entries are experiment issues with the #1295 template fields.
grep -qF 'labels: [experiment]' "$RS_FORMULA" \
  || ac_fail "research formula filer entries do not use the experiment label"
grep -qi "NEVER use \`labels: \[backlog\]\`" "$RS_FORMULA" \
  || ac_fail "research formula does not forbid backlog filer entries"
for field in "## Image" "## Argv" "## Host class" "## Artifact glob" "## Resource class"; do
  grep -qF "$field" "$RS_FORMULA" || ac_fail "research formula filer entry missing #1295 field: $field"
done

# Tracking green = run record + artifact present, NOT deployed.
grep -qF "ops/runs/" "$RS_FORMULA" || ac_fail "research formula tracking green does not reference the run ledger (ops/runs/)"
grep -qF "exit: 0" "$RS_FORMULA" || ac_fail "research formula tracking green does not require run exit 0"
grep -qF "ops/artifacts/" "$RS_FORMULA" || ac_fail "research formula tracking green does not require artifact paths present"
grep -qF "NOT the \`deployed\` label" "$RS_FORMULA" \
  || ac_fail "research formula tracking green must explicitly reject the deployed label"

# Architect stays read-only on the project repo (contract preserved).
grep -qF "READ-ONLY" "$RS_FORMULA" \
  || ac_fail "research formula does not state the project-repo read-only contract"

# Filer entries carry the action-id marker the bash green gate reads back
# from the filed issue body (the filer posts the body verbatim).
grep -qF '<!-- action-id: <' "$RS_FORMULA" \
  || ac_fail "research formula filer entries do not carry the action-id marker (#1315)"

# ── Filer is kind-aware ──────────────────────────────────────────────────────
ac_log "verifying filer formula label selection"
grep -qF 'PROJECT_KIND' "$FILER_FORMULA" \
  || ac_fail "file-subissues.toml is not kind-aware (#1315)"
grep -qF 'LABEL_NAME="experiment"' "$FILER_FORMULA" \
  || ac_fail "file-subissues.toml does not select the experiment label for research"
grep -qF 'LABEL_NAME="backlog"' "$FILER_FORMULA" \
  || ac_fail "file-subissues.toml lost the software backlog label default"
grep -qF 'select(.name == $n)' "$FILER_FORMULA" \
  || ac_fail "file-subissues.toml no longer resolves the kind label by name"
grep -qF 'BACKLOG_ID' "$FILER_FORMULA" \
  && ac_fail "file-subissues.toml still uses the hardcoded BACKLOG_ID"

# ── AGENTS.md documents the research mode ────────────────────────────────────
ac_log "verifying architect AGENTS.md research documentation"
grep -qF "run-architect-research.toml" "$ARCH_AGENTS" \
  || ac_fail "architect AGENTS.md does not document the research formula"
grep -qF "#1315" "$ARCH_AGENTS" \
  || ac_fail "architect AGENTS.md does not reference #1315"
grep -qF "ops/runs/<id>.json" "$ARCH_AGENTS" \
  || ac_fail "architect AGENTS.md missing the research run-ledger green definition"
grep -qF "NOT the \`deployed\` label" "$ARCH_AGENTS" \
  || ac_fail "architect AGENTS.md research green definition must reject the deployed label"
grep -qF "check_research_subissue_green" "$ARCH_AGENTS" \
  || ac_fail "architect AGENTS.md does not document the research green gate"

# ── Tracking green gate is kind-aware (round-2 review) ───────────────────────
ac_log "verifying the kind-aware tracking green gate"

# check_subissue_green dispatches on PROJECT_KIND to kind-specific gates.
grep -qE '^check_subissue_green\(\) \{' "$ARCH_RUN" \
  || ac_fail "check_subissue_green gate missing from architect-run.sh"
grep -qE '^check_research_subissue_green\(\) \{' "$ARCH_RUN" \
  || ac_fail "research green gate (check_research_subissue_green) missing (#1315)"
grep -qE '^check_software_subissue_green\(\) \{' "$ARCH_RUN" \
  || ac_fail "software green gate (check_software_subissue_green) missing"
grep -qF 'check_research_subissue_green "$1"' "$ARCH_RUN" \
  || ac_fail "check_subissue_green does not dispatch research to the research gate"
grep -qF 'check_software_subissue_green "$1"' "$ARCH_RUN" \
  || ac_fail "check_subissue_green does not dispatch software to the software gate"
# The research gate refreshes the ops clone so it reads fresh run records.
grep -qF 'ensure_ops_repo' "$ARCH_RUN" \
  || ac_fail "architect-run.sh must refresh the ops repo clone for the research green gate (ensure_ops_repo)"

RESEARCH_GATE="$(ac_extract_fn check_research_subissue_green "$ARCH_RUN")"
printf '%s' "$RESEARCH_GATE" | grep -qF 'action-id' \
  || ac_fail "research green gate does not read the action-id marker from the issue body"
printf '%s' "$RESEARCH_GATE" | grep -qF '/runs' \
  || ac_fail "research green gate does not read the run ledger (runs/)"
printf '%s' "$RESEARCH_GATE" | grep -qF 'exit == 0' \
  || ac_fail "research green gate does not require run exit 0"
printf '%s' "$RESEARCH_GATE" | grep -qF 'artifacts' \
  || ac_fail "research green gate does not require artifacts present"
# The research gate must NOT demand the software green definition.
printf '%s' "$RESEARCH_GATE" | grep -qF 'deployed' \
  && ac_fail "research green gate must not require the deployed label"
printf '%s' "$RESEARCH_GATE" | grep -qF 'tests/acceptance' \
  && ac_fail "research green gate must not run acceptance tests"

# Functional gate checks: drive the real dispatcher extracted from
# architect-run.sh against a stubbed Forgejo API + temp ops repo.
DISPATCH_GATE="$(ac_extract_fn check_subissue_green "$ARCH_RUN")"
SOFTWARE_GATE="$(ac_extract_fn check_software_subissue_green "$ARCH_RUN")"

gate_run() {
  # $1 = PROJECT_KIND ("" = unset), $2 = ledger row: green|failed|no-artifacts|none
  local kind="$1" ledger="$2" rc=0
  GATE_KIND="$kind" GATE_LEDGER="$ledger" \
  DISPATCH_GATE_FN="$DISPATCH_GATE" RESEARCH_GATE_FN="$RESEARCH_GATE" \
  SOFTWARE_GATE_FN="$SOFTWARE_GATE" \
  bash -c '
    set -u
    [ -n "${GATE_KIND:-}" ] && export PROJECT_KIND="$GATE_KIND"
    export FORGE_TOKEN=dummy FORGE_API_BASE=http://forge FORGE_REPO=p/p
    log() { :; }
    curl() {
      case "$*" in
        *issues/42/labels)
          printf "%s" "[{\"name\":\"deployed\"}]"
          ;;
        *)
          printf "%s" "{\"number\":42,\"state\":\"closed\",\"body\":\"experiment #42\\n\\n<!-- action-id: probe-action -->\\n\"}"
          ;;
      esac
    }
    export OPS_REPO_ROOT="$(mktemp -d)"
    export PROJECT_REPO_ROOT="$(mktemp -d)"
    trap "rm -rf \"$OPS_REPO_ROOT\" \"$PROJECT_REPO_ROOT\"" EXIT
    case "${GATE_LEDGER:-none}" in
      green)
        mkdir -p "$OPS_REPO_ROOT/runs"
        printf "%s" "{\"id\":\"probe-action-1\",\"action_id\":\"probe-action\",\"git_tree\":\"t\",\"image\":\"i\",\"host\":\"h\",\"argv\":[\"x\"],\"started\":\"s\",\"ended\":\"e\",\"exit\":0,\"artifacts\":[\"out/result.json\"]}" \
          > "$OPS_REPO_ROOT/runs/probe-action-1.json"
        ;;
      failed)
        mkdir -p "$OPS_REPO_ROOT/runs"
        printf "%s" "{\"id\":\"probe-action-1\",\"action_id\":\"probe-action\",\"git_tree\":\"t\",\"image\":\"i\",\"host\":\"h\",\"argv\":[\"x\"],\"started\":\"s\",\"ended\":\"e\",\"exit\":1,\"artifacts\":[\"out/result.json\"]}" \
          > "$OPS_REPO_ROOT/runs/probe-action-1.json"
        ;;
      no-artifacts)
        mkdir -p "$OPS_REPO_ROOT/runs"
        printf "%s" "{\"id\":\"probe-action-1\",\"action_id\":\"probe-action\",\"git_tree\":\"t\",\"image\":\"i\",\"host\":\"h\",\"argv\":[\"x\"],\"started\":\"s\",\"ended\":\"e\",\"exit\":0,\"artifacts\":[]}" \
          > "$OPS_REPO_ROOT/runs/probe-action-1.json"
        ;;
    esac
    mkdir -p "$PROJECT_REPO_ROOT/tests/acceptance"
    printf "%s\n" "exit 0" > "$PROJECT_REPO_ROOT/tests/acceptance/issue-42.sh"
    eval "$RESEARCH_GATE_FN"
    eval "$SOFTWARE_GATE_FN"
    eval "$DISPATCH_GATE_FN"
    check_subissue_green "#42"
  ' || rc=$?
  return "$rc"
}

# research: ledger row exit 0 + artifacts → green (no closed/deployed needed)
gate_run research green || ac_fail "research gate must be green for a run-ledger row with exit 0 and artifacts"
# research: failed run → not green (gate rc != 0)
gate_run research failed && ac_fail "research gate must NOT be green for a failed run (exit != 0)"
# research: run with no artifacts → not green (gate rc != 0)
gate_run research no-artifacts && ac_fail "research gate must NOT be green when the run recorded no artifacts"
# research: no ledger row → not green (gate rc != 0)
gate_run research none && ac_fail "research gate must NOT be green with no run-ledger row"
# software: unchanged gate (closed + deployed + acceptance rc=0 → green)
gate_run software green || ac_fail "software gate regression: closed + deployed + acceptance rc=0 must stay green"
# unset kind: software default gate
gate_run "" green || ac_fail "unset PROJECT_KIND must keep the software green gate (closed + deployed + acceptance)"

ac_pass
