#!/usr/bin/env bash
set -euo pipefail

# verify-chat-sandbox.sh — One-shot sandbox verification for disinto-chat (#706)
#
# Runs against a live compose project and asserts hardening constraints.
# Exit 0 if all pass, non-zero otherwise.

CONTAINER="disinto-chat"
PASS=0
FAIL=0

pass() { printf '  ✓ %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL + 1)); }

echo "=== disinto-chat sandbox verification ==="
echo

# --- docker inspect checks ---

inspect_json=$(docker inspect "$CONTAINER" 2>/dev/null) || {
    echo "ERROR: container '$CONTAINER' not found or not running"
    exit 1
}

# ReadonlyRootfs
readonly_rootfs=$(echo "$inspect_json" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['HostConfig']['ReadonlyRootfs'])")
if [ "$readonly_rootfs" = "True" ]; then
    pass "ReadonlyRootfs=true"
else
    fail "ReadonlyRootfs expected true, got $readonly_rootfs"
fi

# CapAdd — should be null or empty
cap_add=$(echo "$inspect_json" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['HostConfig']['CapAdd'])")
if [ "$cap_add" = "None" ] || [ "$cap_add" = "[]" ]; then
    pass "CapAdd=null (no extra capabilities)"
else
    fail "CapAdd expected null, got $cap_add"
fi

# CapDrop — should contain ALL
cap_drop=$(echo "$inspect_json" | python3 -c "import sys,json; caps=json.load(sys.stdin)[0]['HostConfig']['CapDrop'] or []; print(' '.join(caps))")
if echo "$cap_drop" | grep -q "ALL"; then
    pass "CapDrop contains ALL"
else
    fail "CapDrop expected ALL, got: $cap_drop"
fi

# PidsLimit
pids_limit=$(echo "$inspect_json" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['HostConfig']['PidsLimit'])")
if [ "$pids_limit" = "128" ]; then
    pass "PidsLimit=128"
else
    fail "PidsLimit expected 128, got $pids_limit"
fi

# Memory limit (512MB = 536870912 bytes)
mem_limit=$(echo "$inspect_json" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['HostConfig']['Memory'])")
if [ "$mem_limit" = "536870912" ]; then
    pass "Memory=512m"
else
    fail "Memory expected 536870912, got $mem_limit"
fi

# SecurityOpt — must contain no-new-privileges
sec_opt=$(echo "$inspect_json" | python3 -c "import sys,json; opts=json.load(sys.stdin)[0]['HostConfig']['SecurityOpt'] or []; print(' '.join(opts))")
if echo "$sec_opt" | grep -q "no-new-privileges"; then
    pass "SecurityOpt contains no-new-privileges"
else
    fail "SecurityOpt missing no-new-privileges (got: $sec_opt)"
fi

# No docker.sock bind mount
binds=$(echo "$inspect_json" | python3 -c "import sys,json; binds=json.load(sys.stdin)[0]['HostConfig']['Binds'] or []; print(' '.join(binds))")
if echo "$binds" | grep -q "docker.sock"; then
    fail "docker.sock is bind-mounted"
else
    pass "No docker.sock mount"
fi

echo

# --- runtime exec checks ---

# touch /root/x should fail (read-only rootfs + unprivileged user)
if docker exec "$CONTAINER" touch /root/x 2>/dev/null; then
    fail "touch /root/x succeeded (should fail)"
else
    pass "touch /root/x correctly denied"
fi

# /var/run/docker.sock must not exist
if docker exec "$CONTAINER" ls /var/run/docker.sock 2>/dev/null; then
    fail "/var/run/docker.sock is accessible"
else
    pass "/var/run/docker.sock not accessible"
fi

# /etc/shadow should not be readable
if docker exec "$CONTAINER" cat /etc/shadow 2>/dev/null; then
    fail "cat /etc/shadow succeeded (should fail)"
else
    pass "cat /etc/shadow correctly denied"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
