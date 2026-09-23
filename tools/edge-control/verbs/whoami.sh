#!/usr/bin/env bash
# whoami: print this caller's account row (identity on the edge plane).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/accounts.sh"
print_account_row
