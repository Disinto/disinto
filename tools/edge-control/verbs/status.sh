#!/usr/bin/env bash
# status: print this caller's account row (state on the edge plane).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/accounts.sh"
print_account_row
