#!/usr/bin/env bash
# test-install-mcp-wireup.sh — regression tests for the molecule a2a_mcp_server
# wire-up in install.sh (issue #41).
#
# install.sh writes ~/.hermes/config.yaml on every run; the molecule MCP
# entry must land under `mcp_servers.molecule:` with the right command,
# args, and env block so hermes-agent's MCP loader (mcp_config.py +
# mcp_tool.py) can fork the a2a_mcp_server stdio subprocess.
#
# Design mirrors test-install-prefix-strip.sh: rather than partial-source
# install.sh (which would attempt apt-get + curl downloads), we inline
# the exact emit logic and parity-grep install.sh for the load-bearing
# substrings so drift fails the test instead of shipping silently.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALL="$HERE/../install.sh"

PASS=0
FAIL=0

# The logic under test — mirrored from install.sh. Keep in sync with the
# emit block; the parity check below greps install.sh for anchor strings
# so any drift fails loudly.
emit_mcp_block() {
  if [ -n "${MOLECULE_MCP_PYTHON:-}" ]; then
    echo "mcp_servers:"
    echo "  molecule:"
    echo "    enabled: true"
    echo "    command: \"${MOLECULE_MCP_PYTHON}\""
    echo "    args: [\"-m\", \"molecule_runtime.a2a_mcp_server\"]"
    echo "    env:"
    echo "      WORKSPACE_ID: \"${WORKSPACE_ID:-}\""
    echo "      PLATFORM_URL: \"${PLATFORM_URL:-http://platform:8080}\""
    if [ -n "${MOLECULE_ORG_ID:-}" ]; then
      echo "      MOLECULE_ORG_ID: \"${MOLECULE_ORG_ID}\""
    fi
    if [ -n "${CONFIGS_DIR:-}" ]; then
      echo "      CONFIGS_DIR: \"${CONFIGS_DIR}\""
    fi
  fi
}

run_case() {
  local label="$1"
  shift
  bash -c "
    set -u
    $(declare -f emit_mcp_block)
    MOLECULE_MCP_PYTHON=''
    WORKSPACE_ID=''
    PLATFORM_URL=''
    MOLECULE_ORG_ID=''
    CONFIGS_DIR=''
    $*
    emit_mcp_block
  " 2>/dev/null
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -F -q -- "$needle"; then
    echo "  PASS  $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL  $label  →  missing substring: $needle"
    echo "        actual output:"
    printf '%s\n' "$haystack" | sed 's/^/          /'
    FAIL=$((FAIL+1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if ! printf '%s' "$haystack" | grep -F -q -- "$needle"; then
    echo "  PASS  $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL  $label  →  unexpected substring present: $needle"
    FAIL=$((FAIL+1))
  fi
}

assert_empty() {
  local label="$1" actual="$2"
  if [ -z "$actual" ]; then
    echo "  PASS  $label"
    PASS=$((PASS+1))
  else
    echo "  FAIL  $label  →  expected empty, got:"
    printf '%s\n' "$actual" | sed 's/^/          /'
    FAIL=$((FAIL+1))
  fi
}

echo "== install.sh mcp wire-up =="

# --- Case A: full env (production EC2 shape) ---
out=$(run_case "full env" '
  MOLECULE_MCP_PYTHON=/usr/bin/python3
  WORKSPACE_ID=ws-abc-123
  PLATFORM_URL=https://platform.staging.moleculesai.app
  MOLECULE_ORG_ID=org-uuid-xyz
  CONFIGS_DIR=/configs
')
assert_contains "A.1: emits mcp_servers header" "mcp_servers:" "$out"
assert_contains "A.2: emits molecule entry"     "  molecule:"   "$out"
assert_contains "A.3: enabled: true"            "    enabled: true" "$out"
assert_contains "A.4: command points at resolved python" "    command: \"/usr/bin/python3\"" "$out"
assert_contains "A.5: args invokes a2a_mcp_server module" \
  "    args: [\"-m\", \"molecule_runtime.a2a_mcp_server\"]" "$out"
assert_contains "A.6: WORKSPACE_ID forwarded"   "      WORKSPACE_ID: \"ws-abc-123\"" "$out"
assert_contains "A.7: PLATFORM_URL forwarded"   "      PLATFORM_URL: \"https://platform.staging.moleculesai.app\"" "$out"
assert_contains "A.8: MOLECULE_ORG_ID forwarded" "      MOLECULE_ORG_ID: \"org-uuid-xyz\"" "$out"
assert_contains "A.9: CONFIGS_DIR forwarded"    "      CONFIGS_DIR: \"/configs\"" "$out"

# --- Case B: minimum required env (WORKSPACE_ID + PLATFORM_URL only) ---
out=$(run_case "minimal env" '
  MOLECULE_MCP_PYTHON=/usr/local/bin/python3
  WORKSPACE_ID=ws-min
  PLATFORM_URL=http://platform:8080
')
assert_contains "B.1: still emits mcp_servers when ORG_ID/CONFIGS_DIR unset" \
  "mcp_servers:" "$out"
assert_contains "B.2: WORKSPACE_ID present" "WORKSPACE_ID: \"ws-min\"" "$out"
assert_not_contains "B.3: optional MOLECULE_ORG_ID NOT emitted when unset" \
  "MOLECULE_ORG_ID:" "$out"
assert_not_contains "B.4: optional CONFIGS_DIR NOT emitted when unset" \
  "CONFIGS_DIR:" "$out"

# --- Case C: PLATFORM_URL falls back to platform:8080 (matches a2a_client.py) ---
out=$(run_case "PLATFORM_URL fallback" '
  MOLECULE_MCP_PYTHON=/usr/bin/python3
  WORKSPACE_ID=ws-fallback
')
assert_contains "C.1: PLATFORM_URL defaults to http://platform:8080" \
  "      PLATFORM_URL: \"http://platform:8080\"" "$out"

# --- Case D: no python found → block is skipped entirely ---
out=$(run_case "no python found" '
  MOLECULE_MCP_PYTHON=
  WORKSPACE_ID=ws-nopy
  PLATFORM_URL=http://platform:8080
')
assert_empty "D.1: empty MOLECULE_MCP_PYTHON skips entire mcp_servers block" "$out"

# --- Case E: WORKSPACE_ID may be empty (boot-smoke / dev) → entry still valid YAML ---
out=$(run_case "empty WORKSPACE_ID is valid YAML" '
  MOLECULE_MCP_PYTHON=/usr/bin/python3
  WORKSPACE_ID=
  PLATFORM_URL=http://platform:8080
')
assert_contains "E.1: empty WORKSPACE_ID emits as empty string" \
  "      WORKSPACE_ID: \"\"" "$out"

# --- Case F: detect_python loop picks the venv interpreter first ----
# Mirror of the install.sh detection loop introduced in PR #43. The
# loop walks /opt/molecule-venv/bin first so the system /usr/bin/python3
# (stdlib only, no molecule_runtime) doesn't get picked, which used to
# cause every hermes provision to silently log "skipping a2a MCP wire-up"
# and boot the agent without list_peers/delegate_task.
#
# Mirroring (rather than sourcing install.sh) keeps the test isolated
# from install.sh's apt-get/curl side effects. The parity-grep block
# below ensures the mirrored candidate list stays in sync with install.sh
# — drift fails loudly instead of shipping silently.
detect_python() {
  local result=""
  local resolved=""
  for candidate in "$@"; do
    case "$candidate" in
      /*) resolved="$candidate" ;;
      *)  resolved="$(command -v "$candidate" 2>/dev/null || true)" ;;
    esac
    if [ -n "$resolved" ] && [ -x "$resolved" ] && \
       "$resolved" -c "import molecule_runtime" >/dev/null 2>&1; then
      result="$resolved"
      break
    fi
  done
  echo "$result"
}

echo
echo "== detect_python loop (PR #43) =="
DETECT_WORK="$(mktemp -d)"
trap "rm -rf '$DETECT_WORK'" EXIT

mkdir -p "$DETECT_WORK/venv-importable/bin" "$DETECT_WORK/venv-broken/bin" \
         "$DETECT_WORK/path-importable"

# Mock interpreter that pretends `python3 -c "import molecule_runtime"` succeeds.
make_importable_python() {
  cat > "$1" <<'PYEOF'
#!/bin/bash
case "$*" in
  *"import molecule_runtime"*) exit 0 ;;
  *) exit 1 ;;
esac
PYEOF
  chmod +x "$1"
}

# Mock interpreter that always fails to import molecule_runtime (system python shape).
make_broken_python() {
  cat > "$1" <<'PYEOF'
#!/bin/bash
exit 1
PYEOF
  chmod +x "$1"
}

make_importable_python "$DETECT_WORK/venv-importable/bin/python3"
make_broken_python     "$DETECT_WORK/venv-broken/bin/python3"
make_importable_python "$DETECT_WORK/path-importable/python3"

# F.1: venv path first, even when a working PATH python exists
result=$(PATH="$DETECT_WORK/path-importable:/usr/bin:/bin" \
  detect_python "$DETECT_WORK/venv-importable/bin/python3" python3)
if [ "$result" = "$DETECT_WORK/venv-importable/bin/python3" ]; then
  echo "  PASS  F.1: detect_python picks venv path BEFORE PATH python3"
  PASS=$((PASS+1))
else
  echo "  FAIL  F.1: expected '$DETECT_WORK/venv-importable/bin/python3', got '$result'"
  FAIL=$((FAIL+1))
fi

# F.2: venv-broken → falls through to PATH (mirrors a partially-installed AMI)
result=$(PATH="$DETECT_WORK/path-importable:/usr/bin:/bin" \
  detect_python "$DETECT_WORK/venv-broken/bin/python3" python3)
if [ "$result" = "$DETECT_WORK/path-importable/python3" ]; then
  echo "  PASS  F.2: detect_python falls through to PATH when venv python doesn't import"
  PASS=$((PASS+1))
else
  echo "  FAIL  F.2: expected '$DETECT_WORK/path-importable/python3', got '$result'"
  FAIL=$((FAIL+1))
fi

# F.3: nothing importable → returns empty (install.sh then logs the warning + skips block)
result=$(PATH="/usr/bin:/bin" \
  detect_python "$DETECT_WORK/venv-broken/bin/python3" /no/such/python)
if [ -z "$result" ]; then
  echo "  PASS  F.3: detect_python returns empty when no candidate imports molecule_runtime"
  PASS=$((PASS+1))
else
  echo "  FAIL  F.3: expected empty, got '$result'"
  FAIL=$((FAIL+1))
fi

# F.4: missing absolute candidate is skipped without erroring
result=$(detect_python /no/such/python "$DETECT_WORK/venv-importable/bin/python3")
if [ "$result" = "$DETECT_WORK/venv-importable/bin/python3" ]; then
  echo "  PASS  F.4: detect_python skips non-existent absolute paths and continues"
  PASS=$((PASS+1))
else
  echo "  FAIL  F.4: expected '$DETECT_WORK/venv-importable/bin/python3', got '$result'"
  FAIL=$((FAIL+1))
fi

# F.5: empty PATH-resolved candidate (command -v miss) is skipped
result=$(PATH="/empty-only" \
  detect_python python3 "$DETECT_WORK/venv-importable/bin/python3")
if [ "$result" = "$DETECT_WORK/venv-importable/bin/python3" ]; then
  echo "  PASS  F.5: detect_python skips PATH candidates that command -v can't resolve"
  PASS=$((PASS+1))
else
  echo "  FAIL  F.5: expected '$DETECT_WORK/venv-importable/bin/python3', got '$result'"
  FAIL=$((FAIL+1))
fi

# --- Parity check: install.sh must contain the same anchor strings ---
echo
echo "== parity with install.sh =="
PARITY_FAIL=0
for pattern in \
  'MOLECULE_MCP_PYTHON' \
  'import molecule_runtime' \
  'mcp_servers:' \
  '  molecule:' \
  '    enabled: true' \
  'molecule_runtime.a2a_mcp_server' \
  'WORKSPACE_ID:' \
  'PLATFORM_URL:' \
  'MOLECULE_ORG_ID:' \
  'CONFIGS_DIR:' \
  '/opt/molecule-venv/bin/python3' \
  '/opt/molecule-venv/bin/python'; do
  if ! grep -F -q -- "$pattern" "$INSTALL"; then
    echo "  FAIL  install.sh missing substring: $pattern"
    PARITY_FAIL=$((PARITY_FAIL+1))
  fi
done
if [ "$PARITY_FAIL" -eq 0 ]; then
  echo "  PASS  install.sh contains expected logic blocks"
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+PARITY_FAIL))
fi

# Ordering invariant: venv candidates MUST appear BEFORE the PATH-based
# `python3`/`python` lookup in install.sh's detection loop. Reverse the
# order and the original silent-skip bug is back: command -v resolves
# python3 first, /usr/bin/python3 has stdlib only, the import test fails
# but the pre-fix loop returned the resolved path anyway. Pin the order.
venv_line=$(grep -nE '/opt/molecule-venv/bin/python3' "$INSTALL" | head -1 | cut -d: -f1)
path_line=$(grep -nE 'for candidate in' "$INSTALL" | head -1 | cut -d: -f1)
if [ -n "$venv_line" ] && [ -n "$path_line" ] && [ "$venv_line" -ge "$path_line" ] \
   && grep -E "for candidate in /opt/molecule-venv/bin/python3 /opt/molecule-venv/bin/python python3 python" "$INSTALL" >/dev/null; then
  echo "  PASS  install.sh detection loop tries venv candidates before PATH names"
  PASS=$((PASS+1))
else
  echo "  FAIL  install.sh detection loop has wrong candidate order or pattern (venv must come first)"
  FAIL=$((FAIL+1))
fi

# --- Idempotency: install.sh's config.yaml emit is a single-block rewrite ---
# (the `{ ... } > "$HERMES_HOME/config.yaml"` pattern means re-running can't
# accumulate duplicate mcp_servers entries by construction).
echo
echo "== idempotency =="
if grep -F -q '} >"$HERMES_HOME/config.yaml"' "$INSTALL"; then
  echo "  PASS  install.sh uses single-block redirect to config.yaml (overwrite-on-rerun)"
  PASS=$((PASS+1))
else
  echo "  FAIL  install.sh no longer uses } >\"\$HERMES_HOME/config.yaml\" — re-runs may duplicate mcp_servers"
  FAIL=$((FAIL+1))
fi

echo
echo "== results: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
