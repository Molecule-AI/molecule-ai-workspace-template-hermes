#!/usr/bin/env bash
# tests/test_gateway_supervisor.sh — bash assertion tests for
# scripts/gateway-supervisor.sh.
#
# We mock `gosu`, `bash`, `hermes`, and `nohup` by prepending a tmp dir
# to PATH containing scripts of those names that behave deterministically
# (the "gateway" simulates a child process that lives for a controlled
# duration, then exits, so the supervisor's dead-PID detection can be
# exercised without waiting on real hermes-agent).
#
# Run with:   bash tests/test_gateway_supervisor.sh
# Exit code:  0 on success, 1 on any failure.
#
# No bats / pytest deps — same convention as test_derive_provider.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUPERVISOR="${SCRIPT_DIR}/scripts/gateway-supervisor.sh"

if [ ! -f "${SUPERVISOR}" ]; then
  echo "FAIL: cannot find gateway-supervisor.sh at ${SUPERVISOR}" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILURES=()

ok() {
  local name="$1"
  PASS=$((PASS + 1))
  printf "  PASS  %s\n" "${name}"
}

bad() {
  local name="$1"
  local detail="$2"
  FAIL=$((FAIL + 1))
  FAILURES+=("${name}: ${detail}")
  printf "  FAIL  %s — %s\n" "${name}" "${detail}"
}

# Set up a tmp dir with shimmed `gosu`, `bash`, `hermes` so spawn_gateway
# can run without root + without a real hermes binary. The shims live
# only for this test and are PATH-prepended.
TMP_DIR="$(mktemp -d)"
# Belt-and-suspenders cleanup: respawned (nohup'd, HUP-immune) gateways
# outlive their parent supervisor and would otherwise write to a freed
# log path after TMP_DIR is gone, surfacing as "No such file or directory"
# noise in CI output. pkill -P kills every descendant of this test
# process; the rm follows.
cleanup_at_exit() {
  pkill -P $$ 2>/dev/null || true
  sleep 0.2
  rm -rf "${TMP_DIR}"
}
trap cleanup_at_exit EXIT

# `gosu agent <cmd...>` → just runs <cmd...> (the privilege drop is
# a no-op in tests). `env HOME=/tmp PATH=... bash -c "..."` would normally
# follow; our shim forwards.
cat > "${TMP_DIR}/gosu" <<'EOF'
#!/usr/bin/env bash
# Shim: `gosu <user> <cmd...>` → exec <cmd...>
shift  # drop the user
exec "$@"
EOF
chmod +x "${TMP_DIR}/gosu"

# `hermes gateway` simulates a child that lives for HERMES_GATEWAY_LIFE_SEC
# (default 60) then exits. The supervisor detects the exit via kill -0.
# Defaulting to a long life means the cold-start test ("supervisor doesn't
# spuriously restart a healthy gateway") sees stable behavior.
cat > "${TMP_DIR}/hermes" <<'EOF'
#!/usr/bin/env bash
# Shim: `hermes gateway` → sleep then exit. Tests override
# HERMES_GATEWAY_LIFE_SEC to control crash timing.
if [ "${1:-}" = "gateway" ]; then
  sleep "${HERMES_GATEWAY_LIFE_SEC:-60}"
  exit 0
fi
exit 0
EOF
chmod +x "${TMP_DIR}/hermes"

export PATH="${TMP_DIR}:${PATH}"

LOG_FILE="${TMP_DIR}/gateway.log"
touch "${LOG_FILE}"

# Kill any orphan gateway processes from prior subtests so they don't
# write to LOG_FILE during the next test's setup, which races with
# nohup's redirect-open and surfaces as a confusing "No such file or
# directory" stderr.
reap_orphans() {
  pkill -P $$ 2>/dev/null || true
  sleep 0.2
}

# --- Test: spawn_gateway sets GATEWAY_PID to a live process ---
test_spawn_sets_pid() {
  local name="spawn_gateway sets GATEWAY_PID to live pid"
  GATEWAY_PID=""
  HERMES_GATEWAY_LIFE_SEC=10 spawn_gateway "${LOG_FILE}"
  if [ -z "${GATEWAY_PID}" ]; then
    bad "${name}" "GATEWAY_PID was not set"
    return
  fi
  if ! kill -0 "${GATEWAY_PID}" 2>/dev/null; then
    bad "${name}" "GATEWAY_PID=${GATEWAY_PID} but process is not alive"
    return
  fi
  # Cleanup
  kill "${GATEWAY_PID}" 2>/dev/null || true
  wait "${GATEWAY_PID}" 2>/dev/null || true
  ok "${name}"
}

# --- Test: supervisor restarts gateway when it dies ---
test_supervisor_restarts_on_death() {
  local name="supervisor respawns gateway on death within cap"

  # Spawn a short-lived gateway (lives 2s, then exits).
  GATEWAY_PID=""
  HERMES_GATEWAY_LIFE_SEC=2 spawn_gateway "${LOG_FILE}"
  local first_pid="${GATEWAY_PID}"

  # Run supervisor in background with a 1s poll. After 4s the first
  # gateway has died and the supervisor should have respawned it.
  local sup_log
  sup_log="$(mktemp)"
  (
    # Clear inherited EXIT trap so this subshell exiting doesn't wipe
    # TMP_DIR (which would race with subsequent test setups).
    trap - EXIT
    HERMES_GATEWAY_SUPERVISOR_POLL_SEC=1 \
    HERMES_GATEWAY_MAX_RESTARTS=3 \
    HERMES_GATEWAY_RESTART_WINDOW_SEC=60 \
    HERMES_GATEWAY_LIFE_SEC=10 \
    supervise_gateway "${LOG_FILE}" 2>"${sup_log}"
  ) &
  local sup_pid=$!

  sleep 5

  # GATEWAY_PID at this point should be the RESPAWNED pid (a child of the
  # supervisor subshell, not the original). The original first_pid should
  # be dead. Read GATEWAY_PID from the supervisor's stderr — when it
  # respawns, it logs "restart attempt N of M".
  if ! grep -q "restart attempt 1 of 3" "${sup_log}"; then
    bad "${name}" "supervisor did not log restart attempt; stderr: $(cat "${sup_log}")"
    kill "${sup_pid}" 2>/dev/null || true
    rm -f "${sup_log}"
    return
  fi

  # Original gateway should be dead.
  if kill -0 "${first_pid}" 2>/dev/null; then
    bad "${name}" "original gateway pid ${first_pid} still alive — test setup bug"
    kill "${first_pid}" "${sup_pid}" 2>/dev/null || true
    rm -f "${sup_log}"
    return
  fi

  # Cleanup
  kill "${sup_pid}" 2>/dev/null || true
  wait "${sup_pid}" 2>/dev/null || true
  rm -f "${sup_log}"
  ok "${name}"
}

# --- Test: supervisor exits cleanly after restart cap exhausted ---
test_supervisor_caps_restarts() {
  local name="supervisor exits after exceeding HERMES_GATEWAY_MAX_RESTARTS"

  # Spawn a gateway that crashes immediately (life=0 means sleep 0, exit).
  # The supervisor will respawn forever in the absence of a cap; with
  # cap=2 it should exit cleanly after 2 restart attempts.
  GATEWAY_PID=""
  HERMES_GATEWAY_LIFE_SEC=0 spawn_gateway "${LOG_FILE}"

  local sup_log
  sup_log="$(mktemp)"
  local sup_start
  sup_start="$(date +%s)"

  # Run supervisor in foreground (subshell). Cap=2, poll=1, window=60s.
  # Expected: supervisor logs 2 restart attempts, then "exceeded" on the
  # third dead-PID check, then returns. Total wall clock ≤ 8s on a
  # responsive runner.
  (
    trap - EXIT
    HERMES_GATEWAY_SUPERVISOR_POLL_SEC=1 \
    HERMES_GATEWAY_MAX_RESTARTS=2 \
    HERMES_GATEWAY_RESTART_WINDOW_SEC=60 \
    HERMES_GATEWAY_LIFE_SEC=0 \
    supervise_gateway "${LOG_FILE}" 2>"${sup_log}"
  )

  local sup_end
  sup_end="$(date +%s)"
  local elapsed=$((sup_end - sup_start))

  if ! grep -q "exceeded 2 restarts" "${sup_log}"; then
    bad "${name}" "supervisor did not log 'exceeded' message; stderr: $(cat "${sup_log}")"
    rm -f "${sup_log}"
    return
  fi

  if [ "${elapsed}" -gt 15 ]; then
    bad "${name}" "supervisor took ${elapsed}s to exit; expected <15s"
    rm -f "${sup_log}"
    return
  fi

  rm -f "${sup_log}"
  ok "${name}"
}

# --- Test: HERMES_GATEWAY_SUPERVISOR_DISABLE=1 short-circuits ---
test_supervisor_disable_flag() {
  local name="HERMES_GATEWAY_SUPERVISOR_DISABLE=1 returns immediately"
  local sup_log
  sup_log="$(mktemp)"

  local sup_start
  sup_start="$(date +%s)"
  HERMES_GATEWAY_SUPERVISOR_DISABLE=1 supervise_gateway "${LOG_FILE}" 2>"${sup_log}"
  local sup_end
  sup_end="$(date +%s)"

  local elapsed=$((sup_end - sup_start))

  if ! grep -q "skipping supervisor" "${sup_log}"; then
    bad "${name}" "expected 'skipping supervisor' log line; got: $(cat "${sup_log}")"
    rm -f "${sup_log}"
    return
  fi
  if [ "${elapsed}" -gt 2 ]; then
    bad "${name}" "disable flag took ${elapsed}s to return; expected <2s"
    rm -f "${sup_log}"
    return
  fi
  rm -f "${sup_log}"
  ok "${name}"
}

# --- Run all tests ---
echo "== gateway-supervisor.sh tests =="

# Source the supervisor functions into this shell.
# shellcheck disable=SC1090
. "${SUPERVISOR}"

test_spawn_sets_pid
reap_orphans
test_supervisor_disable_flag
reap_orphans
test_supervisor_restarts_on_death
reap_orphans
test_supervisor_caps_restarts
reap_orphans

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -gt 0 ]; then
  echo "Failures:"
  for f in "${FAILURES[@]}"; do
    echo "  - ${f}"
  done
  exit 1
fi
exit 0
