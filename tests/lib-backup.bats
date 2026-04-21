#!/usr/bin/env bats
# =============================================================================
# tests/lib-backup.bats — Backup import round-trip tests
#
# Validates that backup import preserves issue state (open/closed).
# Regression guard for #1163: Forgejo POST /issues always creates open;
# import must PATCH closed issues after creation.
# =============================================================================

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export FACTORY_ROOT="$ROOT"
  export FORGE_TOKEN="test-token"
  export FORGE_URL="https://forge.example.test"
  export FORGE_API="${FORGE_URL}/api/v1"
  export FORGE_REPO="disinto-admin/disinto"
  export FORGE_OPS_REPO="disinto-admin/disinto-ops"

  export CALLS_LOG="${BATS_TEST_TMPDIR}/curl-calls.log"
  : > "$CALLS_LOG"
  export ISSUE_COUNTER_FILE="${BATS_TEST_TMPDIR}/issue-counter"
  echo 100 > "$ISSUE_COUNTER_FILE"

  # Required globals from backup_import
  export BACKUP_MAPPING_FILE="${BATS_TEST_TMPDIR}/mapping.json"
  echo '{"mappings":[]}' > "$BACKUP_MAPPING_FILE"
  export BACKUP_CREATED_ISSUES=0
  export BACKUP_SKIPPED_ISSUES=0

  # curl shim — intercepts backup flow calls and returns canned responses
  curl() {
    local method="GET" url="" arg
    while [ $# -gt 0 ]; do
      arg="$1"
      case "$arg" in
        -X) method="$2"; shift 2 ;;
        -H) shift 2 ;;
        -d) shift 2 ;;
        -sf|-s|-f|--silent|--fail) shift ;;
        -o) shift 2 ;;
        -w) shift 2 ;;
        *) url="$arg"; shift ;;
      esac
    done

    printf '%s %s\n' "$method" "$url" >> "$CALLS_LOG"

    local match="nope"
    case "$method $url" in
      "GET ${FORGE_URL}/api/v1/repos/disinto-admin/disinto/issues/1") match="exist" ;;
      "GET ${FORGE_URL}/api/v1/repos/disinto-admin/disinto/issues/2") match="exist" ;;
      "GET ${FORGE_URL}/api/v1/repos/disinto-admin/disinto/issues/3") match="exist" ;;
      "GET ${FORGE_URL}/api/v1/repos/disinto-admin/disinto/issues/4") match="exist" ;;
      "GET ${FORGE_URL}/api/v1/repos/disinto-admin/disinto/labels") match="labels" ;;
      "POST ${FORGE_URL}/api/v1/repos/disinto-admin/disinto/issues") match="create" ;;
      "PATCH ${FORGE_URL}/api/v1/repos/disinto-admin/disinto/issues/"*) match="patch" ;;
    esac

    case "$match" in
      exist)
        return 1
        ;;
      labels)
        printf '[]'
        ;;
      create)
        local counter
        counter=$(cat "$ISSUE_COUNTER_FILE")
        echo "$((counter + 1))" > "$ISSUE_COUNTER_FILE"
        printf '{"number":%d,"title":"test","state":"open"}' "$counter"
        ;;
      patch)
        local issue_num="${url##*/issues/}"
        printf '{"number":%s,"state":"closed"}' "$issue_num"
        ;;
    esac
    return 0
  }

  # shellcheck source=../lib/disinto/backup.sh
  source "${ROOT}/lib/disinto/backup.sh"
}

# ── helpers ──────────────────────────────────────────────────────────────────

count_calls() {
  local method="$1" url="$2"
  local result
  result=$(grep -cF "${method} ${url}" "$CALLS_LOG" 2>/dev/null) || result=0
  echo "$result"
}

# ── tests ────────────────────────────────────────────────────────────────────

@test "backup_import preserves closed issue state via PATCH" {
  local issues_file="${BATS_TEST_TMPDIR}/issues/disinto.json"
  mkdir -p "$(dirname "$issues_file")"
  cat > "$issues_file" <<'JSON'
[
  {"number":1,"title":"Open Issue 1","body":"desc1","labels":[],"state":"open"},
  {"number":2,"title":"Closed Issue 1","body":"desc2","labels":[],"state":"closed"},
  {"number":3,"title":"Open Issue 2","body":"desc3","labels":[],"state":"open"},
  {"number":4,"title":"Closed Issue 2","body":"desc4","labels":[],"state":"closed"}
]
JSON

  export BACKUP_TEMP_DIR="${BATS_TEST_TMPDIR}"

  run backup_import_issues "disinto-admin/disinto" "$issues_file"

  # All 4 issues should be created (POST)
  local post_count
  post_count=$(count_calls "POST" "${FORGE_URL}/api/v1/repos/disinto-admin/disinto/issues")
  [ "$post_count" -eq 4 ]

  # Exactly 2 PATCH calls — one per closed issue
  local patch_count
  patch_count=$(count_calls "PATCH" "${FORGE_URL}/api/v1/repos/disinto-admin/disinto/issues/")
  [ "$patch_count" -eq 2 ]

  # Each issue existence check happened once
  local get1 get2
  get1=$(count_calls "GET" "${FORGE_URL}/api/v1/repos/disinto-admin/disinto/issues/1")
  get2=$(count_calls "GET" "${FORGE_URL}/api/v1/repos/disinto-admin/disinto/issues/2")
  [ "$get1" -eq 1 ]
  [ "$get2" -eq 1 ]
}

@test "backup_import skips already-existing issues" {
  local issues_file="${BATS_TEST_TMPDIR}/issues/disinto.json"
  mkdir -p "$(dirname "$issues_file")"
  cat > "$issues_file" <<'JSON'
[
  {"number":1,"title":"Existing Issue","body":"desc","labels":[],"state":"open"}
]
JSON

  # Override curl to simulate issue #1 already exists
  curl() {
    local method="GET" url="" arg
    while [ $# -gt 0 ]; do
      arg="$1"
      case "$arg" in
        -X) method="$2"; shift 2 ;;
        -H) shift 2 ;;
        -d) shift 2 ;;
        -sf|-s|-f|--silent|--fail) shift ;;
        -o) shift 2 ;;
        -w) shift 2 ;;
        *) url="$arg"; shift ;;
      esac
    done
    printf '%s %s\n' "$method" "$url" >> "$CALLS_LOG"
    if [[ "$method $url" == *"issues/1"* ]]; then
      printf '{"number":1,"title":"Existing"}'
    else
      return 1
    fi
  }

  export BACKUP_TEMP_DIR="${BATS_TEST_TMPDIR}"

  run backup_import_issues "disinto-admin/disinto" "$issues_file"
  [ "$status" -eq 0 ]

  # Issue was skipped — no POST, no PATCH
  local post_count patch_count
  post_count=$(count_calls "POST" "${FORGE_URL}/api/v1/repos/disinto-admin/disinto/issues")
  patch_count=$(count_calls "PATCH" "${FORGE_URL}/api/v1/repos/disinto-admin/disinto/issues/")
  [ "$post_count" -eq 0 ]
  [ "$patch_count" -eq 0 ]
}

@test "backup_import handles issues with labels" {
  local issues_file="${BATS_TEST_TMPDIR}/issues/disinto.json"
  mkdir -p "$(dirname "$issues_file")"
  cat > "$issues_file" <<'JSON'
[
  {"number":1,"title":"Labeled Issue","body":"desc","labels":["bug","priority"],"state":"closed"}
]
JSON

  export BACKUP_TEMP_DIR="${BATS_TEST_TMPDIR}"

  run backup_import_issues "disinto-admin/disinto" "$issues_file"

  # Issue created
  local post_count
  post_count=$(count_calls "POST" "${FORGE_URL}/api/v1/repos/disinto-admin/disinto/issues")
  [ "$post_count" -eq 1 ]

  # Closed issue gets PATCHed
  local patch_count
  patch_count=$(count_calls "PATCH" "${FORGE_URL}/api/v1/repos/disinto-admin/disinto/issues/")
  [ "$patch_count" -eq 1 ]
}
