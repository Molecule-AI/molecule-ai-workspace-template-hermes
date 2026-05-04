"""Hermes adapter — bridges molecule A2A to the real Nous Research hermes-agent.

This template runs the actual `hermes-agent` (github.com/NousResearch/hermes-agent)
inside the workspace container. start.sh boots `hermes gateway` with the
API_SERVER platform enabled (listening on 127.0.0.1:8642) before exec'ing
`molecule-runtime`. At request time the executor proxies every A2A
message into hermes-agent's OpenAI-compatible /v1/chat/completions
endpoint, collects the response, and emits it back on the A2A queue.

The adapter deliberately does no model/provider selection of its own —
that responsibility lives inside hermes-agent (`hermes model`, `hermes
config set`). Trying to layer a second provider registry on top was the
core mistake the previous version of this template made; see
docs/PLANNING.md for the rewrite rationale.
"""
from __future__ import annotations

import asyncio
import logging
import os
import time

from molecule_runtime.adapters.base import BaseAdapter, AdapterConfig, RuntimeCapabilities

logger = logging.getLogger(__name__)


# Auth env names to audit at boot. Order is informational; presence/absence
# of each is logged so the operator can see at a glance which key the
# workspace was started with vs which is missing. NEVER log values — just
# the boolean "set"/"unset" per name.
#
# Hermes-agent consumes every per-vendor key DIRECTLY (no projection onto
# ANTHROPIC_AUTH_TOKEN like claude-code requires), so the audit list
# enumerates the same per-vendor names that start.sh forwards into
# hermes-agent's .env. The contrast with claude-code's audit (which
# includes ANTHROPIC_AUTH_TOKEN + ANTHROPIC_BASE_URL because that SDK is
# Anthropic-only) is deliberate — see task #249 reconciliation note.
#
# Adding a new vendor: add its env name here AND to start.sh's audit
# for-loop (the cross-file test in tests/test_adapter_logging.py pins
# the two lists set-equal).
_AUTH_ENV_AUDIT = (
    # Nous Portal + the OpenRouter catch-all (covers any model that
    # routes through hermes's openrouter provider, including the openai/*
    # slug fallback).
    "HERMES_API_KEY",
    "NOUS_API_KEY",
    "OPENROUTER_API_KEY",
    # Direct-SDK providers hermes calls natively.
    "OPENAI_API_KEY",
    "ANTHROPIC_API_KEY",
    "GEMINI_API_KEY",
    "GOOGLE_API_KEY",
    "DEEPSEEK_API_KEY",
    "GLM_API_KEY",
    "KIMI_API_KEY",
    "KIMI_CN_API_KEY",
    "MINIMAX_API_KEY",
    "MINIMAX_CN_API_KEY",
    "DASHSCOPE_API_KEY",
    "XIAOMI_API_KEY",
    "ARCEEAI_API_KEY",
    "NVIDIA_API_KEY",
    "OLLAMA_API_KEY",
    "HF_TOKEN",
    "AI_GATEWAY_API_KEY",
    "KILOCODE_API_KEY",
    "OPENCODE_ZEN_API_KEY",
    "OPENCODE_GO_API_KEY",
    "COPILOT_GITHUB_TOKEN",
    "GH_TOKEN",
    # Custom OpenAI-compatible provider escape hatch. start.sh forwards
    # HERMES_CUSTOM_BASE_URL + HERMES_CUSTOM_API_KEY + HERMES_CUSTOM_API_MODE
    # into hermes-agent's .env when PROVIDER=custom. Only the API_KEY is
    # auth-relevant (BASE_URL + API_MODE are routing config, not secrets);
    # auditing it lets operators diagnose vLLM / self-hosted / Cerebras
    # wiring failures from boot logs alone.
    "HERMES_CUSTOM_API_KEY",
)


def _audit_auth_env_presence() -> None:
    """Log a one-line snapshot of which auth env names are set.

    Logs NAMES + presence ("set"/"unset"), never VALUES. Lets an
    operator reading docker logs answer "is this a missing key
    problem or a wrong-model problem?" in one glance — paired with
    start.sh's pre-Python audit (which fires before the gateway
    spawns), the operator sees the same set of names twice and can
    correlate "key was present at start.sh, gone by adapter.setup()"
    if it ever happens.

    Mirrors claude-code's _audit_auth_env_presence (template-claude-code
    PR #32) but with hermes's per-vendor audit list — hermes has no
    ANTHROPIC_AUTH_TOKEN/ANTHROPIC_BASE_URL projection layer.
    """
    snapshot = ", ".join(
        f"{name}={'set' if os.environ.get(name) else 'unset'}"
        for name in _AUTH_ENV_AUDIT
    )
    logger.info("auth env audit: %s", snapshot)


class HermesAgentAdapter(BaseAdapter):
    """Adapter that proxies A2A requests to a locally-running hermes-agent."""

    @staticmethod
    def name() -> str:
        return "hermes"

    @staticmethod
    def display_name() -> str:
        return "Hermes Agent (Nous Research)"

    @staticmethod
    def description() -> str:
        return (
            "Runs the real Nous Research hermes-agent with its native "
            "terminal, file, web, memory, and skill tools. Model + provider "
            "are owned by hermes-agent itself (hermes model)."
        )

    @staticmethod
    def get_config_schema() -> dict:
        return {
            "model": {
                "type": "string",
                "description": (
                    "Model string passed through to hermes-agent. Accepts "
                    "any form hermes-agent understands — e.g. "
                    "'nousresearch/hermes-4-70b', 'anthropic/claude-sonnet-4-5', "
                    "'gemini/gemini-2.5-pro', 'MiniMax-M2.7', or "
                    "'openrouter/<slug>'."
                ),
            },
        }

    def capabilities(self) -> RuntimeCapabilities:
        """Hermes-agent owns several cross-cutting capabilities natively
        — see project memory `project_runtime_native_pluggable.md`.

        provides_native_session=True
            hermes-agent runs an in-container event log (memory or Redis,
            configurable via runtime.event_log.backend in its own
            config.yaml) that holds in-flight session state across A2A
            turns. The platform's a2a_queue would double-buffer the
            same state — declaring native_session lets the platform
            skip enqueueing and dispatch directly. Validates capability
            primitive #5 once that consumer lands.

        Other capabilities stay False (platform fallback owns them):
        - provides_native_heartbeat: hermes-agent doesn't broadcast
          progress events at the platform's cadence; we keep emitting
          WORKSPACE_HEARTBEAT every 30s from heartbeat.py so the canvas
          UI's idle indicator stays accurate.
        - provides_native_scheduler: hermes-agent has no built-in cron;
          platform scheduler keeps owning it.
        - provides_native_status_mgmt: hermes-agent doesn't surface a
          ready/degraded/failed signal back to us; platform's
          error_rate inference still drives the workspace status.
        - provides_native_retry / activity_decoration / channel_dispatch:
          not implemented in hermes-agent's API server — platform
          fallback applies.
        """
        return RuntimeCapabilities(
            provides_native_session=True,
        )

    def idle_timeout_override(self) -> int:
        """hermes-agent synthesis on slower providers (anthropic Opus,
        custom models behind hermes' provider router) routinely exceeds
        the platform default 5min idle window. The single-text reply
        path also doesn't broadcast tool-call progress events while the
        upstream LLM is thinking — so the platform's broadcaster-silence
        timer would cancel a legit-but-slow synthesis. 15 min covers
        every observed turn so far without leaving genuinely-wedged
        runs hanging too long.

        Capability primitive #2 — see workspace/adapter_base.py:
        idle_timeout_override and PR #2139 for the platform-side
        consumer in a2a_proxy.dispatchA2A.
        """
        return 900  # 15 minutes

    async def setup(self, config: AdapterConfig) -> None:
        """Verify the hermes-agent API surface this workspace will use.

        start.sh boots `hermes gateway` before molecule-runtime. With
        MOLECULE_A2A_PLATFORM_ENABLED=true (default) we probe the
        plugin's /a2a/health endpoint; otherwise we fall back to the
        legacy api-server /health. Failing here marks the workspace
        unhealthy rather than silently forwarding to a dead port.
        """
        # Boot-smoke contract (molecule-core#2275): start.sh's smoke-mode
        # branch exec's molecule-runtime without spawning the gateway,
        # so neither the plugin port nor :8642 is listening. Skip the
        # health probe under smoke mode — the runtime's smoke
        # short-circuit fires after create_executor() returns.
        if os.environ.get("MOLECULE_SMOKE_MODE") == "1":
            return

        # Audit which auth-relevant env vars are present (NAMES ONLY —
        # never values). Boot-time visibility into "is the key missing
        # or wrong" is the diagnosis question that bit the 2026-05-02
        # crash-loop incident in claude-code; ship the same surgical
        # fix here proactively so a hermes operator with multiple
        # vendor keys can tell "is MINIMAX_API_KEY visible to my
        # workspace?" from `docker logs` alone. start.sh logs the same
        # set as a shell loop pre-gosu; this entry confirms it survived
        # the privilege drop and got handed to the Python adapter.
        _audit_auth_env_presence()

        try:
            import httpx  # noqa: F401
        except ImportError as exc:  # pragma: no cover
            raise RuntimeError(
                "Hermes adapter bridge requires httpx — "
                "add to requirements.txt and rebuild the image."
            ) from exc

        import httpx

        # Default off — see executor.py module docstring. Workspace boot
        # was wedging on the plugin /a2a/health probe because the plugin
        # didn't bind :8645 inside the deployed image. Falls back to the
        # legacy /v1/chat/completions /health probe until that's fixed.
        use_plugin = os.environ.get(
            "MOLECULE_A2A_PLATFORM_ENABLED", "false"
        ).strip().lower() in ("1", "true", "yes", "on")

        if use_plugin:
            host = os.environ.get("MOLECULE_A2A_PLATFORM_HOST", "127.0.0.1")
            port = int(os.environ.get("MOLECULE_A2A_PLATFORM_PORT", "8645"))
            health_url = f"http://{host}:{port}/a2a/health"
            err_hint = (
                "Check /var/log/hermes-gateway.log inside the container — "
                "the molecule-a2a platform stanza in ~/.hermes/config.yaml "
                "should make hermes load the plugin and bind this port."
            )
        else:
            base = os.environ.get(
                "HERMES_API_BASE", "http://127.0.0.1:8642/v1"
            ).rstrip("/")
            health_url = base.replace("/v1", "") + "/health"
            err_hint = "Check /var/log/hermes-gateway.log inside the container."

        # Retry the gateway probe with linear backoff up to a configurable
        # budget. start.sh used to gate `exec molecule-runtime` on the
        # gateway being healthy; that gate was removed (see start.sh's
        # "Race molecule-runtime with hermes gateway" block) so this probe
        # now runs against a still-warming-up gateway. Budget defaults to
        # 120s which matches the old in-shell wait — operators can shrink
        # it to fail-fast (development) or extend it (slow first-boot DB
        # migrations) via HERMES_GATEWAY_READY_BUDGET_SEC.
        #
        # AsyncClient — sync httpx inside an async setup() can deadlock
        # against an aiohttp server sharing the same event loop (only
        # bites in tests; real deployments separate processes).
        try:
            budget_sec = int(os.environ.get("HERMES_GATEWAY_READY_BUDGET_SEC", "120"))
        except ValueError:
            budget_sec = 120
        deadline = time.monotonic() + max(budget_sec, 5)
        last_exc: Exception | None = None
        attempt = 0
        async with httpx.AsyncClient(timeout=5.0) as client:
            while time.monotonic() < deadline:
                attempt += 1
                try:
                    r = await client.get(health_url)
                    r.raise_for_status()
                    if attempt > 1:
                        elapsed = budget_sec - max(0, int(deadline - time.monotonic()))
                        logger.info(
                            "hermes gateway probe succeeded after %d attempt(s) (~%ds elapsed)",
                            attempt, elapsed,
                        )
                    last_exc = None
                    break
                except Exception as exc:  # noqa: BLE001
                    last_exc = exc
                    if time.monotonic() + 2 >= deadline:
                        break
                    await asyncio.sleep(2)
        if last_exc is not None:  # pragma: no cover
            raise RuntimeError(
                f"hermes-agent surface not reachable at {health_url} after "
                f"{attempt} attempt(s) over ~{budget_sec}s. {err_hint}"
            ) from last_exc

    async def create_executor(self, config: AdapterConfig):
        from executor import HermesAgentProxyExecutor

        executor = HermesAgentProxyExecutor(config)
        await executor.start()
        return executor


Adapter = HermesAgentAdapter
