#!/usr/bin/env bash
# Spawn + supervise the hermes-agent gateway process.
#
# Why this is its own file: PR #51 made start.sh exec ``molecule-runtime``
# immediately after backgrounding hermes gateway, so a mid-run crash of
# the gateway would leave molecule-runtime serving /agent-card 200 while
# every JSON-RPC call silently failed (executor proxies to :8642, which
# is dead). The supervisor closes that gap by polling the gateway PID
# and respawning on death, capped to avoid restart loops on persistent
# auth/config failures.
#
# Sourced by start.sh — exposes two functions:
#
#   spawn_gateway <log_file>
#       nohup-spawns ``hermes gateway`` under gosu agent with the
#       fixed PATH from start.sh's environment. Sets the GATEWAY_PID
#       global to the spawned pid. Idempotent: callers can invoke it
#       again to respawn.
#
#   supervise_gateway <log_file>
#       Backgrounded supervisor loop. Polls GATEWAY_PID every
#       ``HERMES_GATEWAY_SUPERVISOR_POLL_SEC`` seconds (default 5).
#       On dead PID: spawn_gateway respawns, restart counter increments.
#       Exits the supervisor subshell when restarts exceed
#       ``HERMES_GATEWAY_MAX_RESTARTS`` (default 5) inside a rolling
#       ``HERMES_GATEWAY_RESTART_WINDOW_SEC`` window (default 300s).
#       Set ``HERMES_GATEWAY_SUPERVISOR_DISABLE=1`` to skip the
#       supervisor entirely (escape hatch for debugging or for runs
#       where the operator wants the legacy "container dies on first
#       gateway crash" behavior).
#
# All knobs default to values that match the old in-shell wait budget
# (5×60s ≈ 5min upper bound for transient gateway flapping); operators
# can tune via env without re-baking the image.

set -u

# spawn_gateway <log_file>
#
# Spawn hermes-gateway as a backgrounded child of the calling shell.
# Sets GATEWAY_PID to the new pid. The HOME=/tmp + explicit PATH match
# the original start.sh invocation — see the "Start hermes gateway in
# the background" block in start.sh for the rationale (HERMES_HOME
# resolution + read-only PATH lookup under T1 sandbox).
spawn_gateway() {
  local log_file="$1"
  nohup gosu agent env HOME=/tmp \
      PATH="/home/agent/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
      bash -c "cd /tmp && hermes gateway" \
      >>"${log_file}" 2>&1 &
  GATEWAY_PID=$!
}

# supervise_gateway <log_file>
#
# Run the supervisor loop. Caller should backgound this with `&` and
# leave it running; on container death the supervisor dies with the
# parent.
#
# The rolling window resets the restart counter when window_sec elapses
# without exhaustion. Without that, a single transient crash early in
# the workspace's life would count against a much-later crash and cause
# a healthy long-running workspace to die on its sixth lifetime
# restart. Counting restarts within a window matches the Linux
# `systemd` Restart= semantics and the Kubernetes BackOff cap pattern.
supervise_gateway() {
  local log_file="$1"

  if [ "${HERMES_GATEWAY_SUPERVISOR_DISABLE:-}" = "1" ]; then
    echo "[start.sh:supervisor] HERMES_GATEWAY_SUPERVISOR_DISABLE=1 — skipping supervisor; gateway crashes will not auto-restart." >&2
    return 0
  fi

  local max_restarts="${HERMES_GATEWAY_MAX_RESTARTS:-5}"
  local window_sec="${HERMES_GATEWAY_RESTART_WINDOW_SEC:-300}"
  local poll_sec="${HERMES_GATEWAY_SUPERVISOR_POLL_SEC:-5}"

  local restarts=0
  local window_start
  window_start="$(date +%s)"

  while true; do
    sleep "${poll_sec}"

    # Reset rolling window if it has elapsed without exhaustion.
    local now
    now="$(date +%s)"
    if [ "$((now - window_start))" -ge "${window_sec}" ]; then
      restarts=0
      window_start="${now}"
    fi

    # Live-PID check. kill -0 is a permission/existence probe that
    # doesn't actually signal — just tells us if the process still
    # exists in the kernel's pid table.
    if kill -0 "${GATEWAY_PID}" 2>/dev/null; then
      continue
    fi

    restarts=$((restarts + 1))
    if [ "${restarts}" -gt "${max_restarts}" ]; then
      echo "[start.sh:supervisor] hermes gateway exceeded ${max_restarts} restarts within ${window_sec}s; giving up. Workspace will continue serving /agent-card but JSON-RPC will fail until the next container restart." >&2
      return 0
    fi

    echo "[start.sh:supervisor] hermes gateway died (pid was ${GATEWAY_PID}); restart attempt ${restarts} of ${max_restarts}" >&2
    spawn_gateway "${log_file}"
  done
}
