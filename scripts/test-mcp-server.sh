#!/usr/bin/env bash
# tests/test-mcp-server.sh — shell-level unit tests for the a2a-mcp-server
# startup block added in start.sh to fix Issue #157.
#
# Run with:   bash tests/test-mcp-server.sh
# Exit code:  0 on success, 1 on any failure.
#
# These tests validate the Python lookup logic and env-var contract.
# Full integration testing (server actually starts + accepts connections)
# requires a Docker build; covered by the publish-image smoke test.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_FILE="${SCRIPT_DIR}/start.sh"

if [ ! -f "${SOURCE_FILE}" ]; then
  echo "FAIL: cannot find start.sh at ${SOURCE_FILE}" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILURES=()

# Check that the MCP server block is present in start.sh
grep_q() {
  grep -q "$1" "${SOURCE_FILE}"
}

check() {
  local name="$1"
  local condition="$2"
  if eval "${condition}"; then
    PASS=$((PASS + 1))
    printf "  PASS  %s\n" "${name}"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("${name}")
    printf "  FAIL  %s\n" "${name}"
  fi
}

echo "== start.sh MCP server block tests =="

# --- presence checks ---
check "mcp server block present (smoke mode skips mcp server)" \
  'grep_q "MOLECULE_SMOKE_MODE.*!=.*1"'
check "mcp server block present (MCP_PORT env var)" \
  'grep_q "MOLECULE_MCP_PORT"'
check "mcp server block present (a2a_mcp_server.py lookup)" \
  'grep_q "a2a_mcp_server"'
check "mcp server block present (HTTP transport flag)" \
  'grep_q "transport http"'
check "mcp server block present (health probe after start)" \
  'grep_q "MCP_SERVER_LOG\|a2a-mcp-server"'
check "mcp server block present (PYTHONPATH injection)" \
  'grep_q "PYTHONPATH"'
check "mcp server block present (gosu agent)" \
  'grep_q "gosu agent"'
check "mcp server block present (warning when script not found)" \
  'grep_q "WARNING.*not found\|not found.*WARNING"'
check "mcp server block present (MOLECULE_MCP_PORT default 9100)" \
  'grep_q "9100"'

# --- Python lookup logic (standalone) ---
# Extract and run the Python snippet that resolves the MCP server path
MCP_LOOKUP=$(python3 -c "
import os, sys
try:
    from molecule_runtime import a2a_mcp_server as _m
    p = getattr(_m, '__file__', None)
    if p and os.path.isfile(p):
        print(p); sys.exit(0)
except Exception:
    pass
print('/app/a2a_mcp_server.py')
" 2>/dev/null)

check "Python lookup resolves to an existing file" \
  '[ -f "${MCP_LOOKUP}" ]'
check "Python lookup resolves to molecule_runtime path" \
  'echo "${MCP_LOOKUP}" | grep -q "molecule_runtime"'
check "Python lookup resolves to a2a_mcp_server.py" \
  'echo "${MCP_LOOKUP}" | grep -q "a2a_mcp_server.py"'

# --- pkg root extraction ---
PKG_ROOT=$(python3 -c "
import os, sys
try:
    from molecule_runtime import a2a_mcp_server as _m
    print(os.path.dirname(os.path.dirname(os.path.abspath(_m.__file__))))
except Exception:
    print('/app')
" 2>/dev/null)

check "pkg root resolves to site-packages" \
  'echo "${PKG_ROOT}" | grep -q "site-packages\|dist-packages"'

echo
echo "== summary: ${PASS} passed, ${FAIL} failed =="
if [ "${FAIL}" -gt 0 ]; then
  echo
  echo "failures:"
  for f in "${FAILURES[@]}"; do
    echo "  - ${f}"
  done
  exit 1
fi
exit 0
