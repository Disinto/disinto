#!/usr/bin/env bash
# tests/test-duplicate-service-detection.sh — Unit test for duplicate service detection
#
# Tests that the compose generator correctly detects duplicate service names
# between ENABLE_LLAMA_AGENT=1 and [agents.llama] TOML configuration.

set -euo pipefail

# Get the absolute path to the disinto root
DISINTO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap "rm -rf \"\$TEST_DIR\"" EXIT

FAILED=0

fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }
pass() { printf 'PASS: %s\n' "$*"; }

# Test 1: Duplicate between ENABLE_LLAMA_AGENT and [agents.llama]
echo "=== Test 1: Duplicate between ENABLE_LLAMA_AGENT and [agents.llama] ==="

# Create projects directory and test project TOML with an agent named "llama"
mkdir -p "${TEST_DIR}/projects"
cat > "${TEST_DIR}/projects/test-project.toml" <<'TOMLEOF'
name = "test-project"
description = "Test project for duplicate detection"

[ci]
woodpecker_repo_id = "123"

[agents.llama]
base_url = "http://localhost:8080"
model = "qwen:latest"
roles = ["dev"]
forge_user = "llama-bot"
TOMLEOF

# Create a minimal compose file
cat > "${TEST_DIR}/docker-compose.yml" <<'COMPOSEEOF'
# Test compose file
services:
  agents:
    image: test:latest
    command: echo "hello"

volumes:
  test-data:

networks:
  test-net:
COMPOSEEOF

# Set up the test environment
export FACTORY_ROOT="${TEST_DIR}"
export PROJECT_NAME="test-project"
export ENABLE_LLAMA_AGENT="1"
export FORGE_TOKEN=""
export FORGE_PASS=""
export CLAUDE_TIMEOUT="7200"
export POLL_INTERVAL="300"
# GARDENER_INTERVAL deprecated (#872): gardener now runs per-iteration
# via gardener/gardener-step.sh, paced by POLL_INTERVAL.
export ARCHITECT_INTERVAL="900"
export PLANNER_INTERVAL="43200"
export SUPERVISOR_INTERVAL="1200"

# Source the generators module and run the compose generator directly
source "${DISINTO_ROOT}/lib/generators.sh"

# Delete the compose file to force regeneration
rm -f "${TEST_DIR}/docker-compose.yml"

# Run the compose generator directly
if _generate_compose_impl 3000 false 2>&1 | tee "${TEST_DIR}/output.txt"; then
  # Check if the output contains the duplicate error message
  if grep -q "Duplicate service name 'agents-llama'" "${TEST_DIR}/output.txt"; then
    pass "Duplicate detection: correctly detected conflict between ENABLE_LLAMA_AGENT and [agents.llama]"
  else
    fail "Duplicate detection: should have detected conflict between ENABLE_LLAMA_AGENT and [agents.llama]"
    cat "${TEST_DIR}/output.txt" >&2
  fi
else
  # Generator should fail with non-zero exit code
  if grep -q "Duplicate service name 'agents-llama'" "${TEST_DIR}/output.txt"; then
    pass "Duplicate detection: correctly detected conflict and returned non-zero exit code"
  else
    fail "Duplicate detection: should have failed with duplicate error"
    cat "${TEST_DIR}/output.txt" >&2
  fi
fi

# Test 2: No duplicate when only ENABLE_LLAMA_AGENT is set (no conflicting TOML)
echo ""
echo "=== Test 2: No duplicate when only ENABLE_LLAMA_AGENT is set ==="

# Remove the projects directory created in Test 1
rm -rf "${TEST_DIR}/projects"

# Create a fresh compose file
cat > "${TEST_DIR}/docker-compose.yml" <<'COMPOSEEOF'
# Test compose file
services:
  agents:
    image: test:latest

volumes:
  test-data:

networks:
  test-net:
COMPOSEEOF

# Set ENABLE_LLAMA_AGENT
export ENABLE_LLAMA_AGENT="1"

# Delete the compose file to force regeneration
rm -f "${TEST_DIR}/docker-compose.yml"

if _generate_compose_impl 3000 false 2>&1 | tee "${TEST_DIR}/output2.txt"; then
  if grep -q "Duplicate" "${TEST_DIR}/output2.txt"; then
    fail "No duplicate: should not detect duplicate when only ENABLE_LLAMA_AGENT is set"
  else
    pass "No duplicate: correctly generated compose without duplicates"
  fi
else
  # Non-zero exit is fine if there's a legitimate reason (e.g., missing files)
  if grep -q "Duplicate" "${TEST_DIR}/output2.txt"; then
    fail "No duplicate: should not detect duplicate when only ENABLE_LLAMA_AGENT is set"
  else
    pass "No duplicate: generator failed for other reason (acceptable)"
  fi
fi

# Test 3: Duplicate between two TOML agents with same name
echo ""
echo "=== Test 3: Duplicate between two TOML agents with same name ==="

rm -f "${TEST_DIR}/docker-compose.yml"

# Create projects directory for Test 3
mkdir -p "${TEST_DIR}/projects"

cat > "${TEST_DIR}/projects/project1.toml" <<'TOMLEOF'
name = "project1"
description = "First project"

[ci]
woodpecker_repo_id = "1"

[agents.llama]
base_url = "http://localhost:8080"
model = "qwen:latest"
roles = ["dev"]
forge_user = "llama-bot1"
TOMLEOF

cat > "${TEST_DIR}/projects/project2.toml" <<'TOMLEOF'
name = "project2"
description = "Second project"

[ci]
woodpecker_repo_id = "2"

[agents.llama]
base_url = "http://localhost:8080"
model = "qwen:latest"
roles = ["dev"]
forge_user = "llama-bot2"
TOMLEOF

cat > "${TEST_DIR}/docker-compose.yml" <<'COMPOSEEOF'
# Test compose file
services:
  agents:
    image: test:latest

volumes:
  test-data:

networks:
  test-net:
COMPOSEEOF

unset ENABLE_LLAMA_AGENT

# Delete the compose file to force regeneration
rm -f "${TEST_DIR}/docker-compose.yml"

if _generate_compose_impl 3000 false 2>&1 | tee "${TEST_DIR}/output3.txt"; then
  if grep -q "Duplicate service name 'agents-llama'" "${TEST_DIR}/output3.txt"; then
    pass "Duplicate detection: correctly detected conflict between two [agents.llama] blocks"
  else
    fail "Duplicate detection: should have detected conflict between two [agents.llama] blocks"
    cat "${TEST_DIR}/output3.txt" >&2
  fi
else
  if grep -q "Duplicate service name 'agents-llama'" "${TEST_DIR}/output3.txt"; then
    pass "Duplicate detection: correctly detected conflict and returned non-zero exit code"
  else
    fail "Duplicate detection: should have failed with duplicate error"
    cat "${TEST_DIR}/output3.txt" >&2
  fi
fi

# Summary
echo ""
if [ "$FAILED" -ne 0 ]; then
  echo "=== TESTS FAILED ==="
  exit 1
fi
echo "=== ALL TESTS PASSED ==="
