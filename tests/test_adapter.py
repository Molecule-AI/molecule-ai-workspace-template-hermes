"""Tests for adapter.py.

Coverage targets the public adapter surface:
  - Static introspection (name, display_name, description, schema)
  - Capabilities (provides_native_session=True, others False)
  - idle_timeout_override (15min)
  - setup() smoke-mode short-circuit
  - setup() health probe via plugin path (default) and chat_completions
    path (when MOLECULE_A2A_PLATFORM_ENABLED=false)
  - create_executor() returns a started executor
"""

from __future__ import annotations

import socket
from typing import Any

import pytest
from aiohttp import web

from adapter import HermesAgentAdapter, Adapter
from molecule_runtime.adapters.base import AdapterConfig


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


# ---- structural -----------------------------------------------------


def test_adapter_alias():
    assert Adapter is HermesAgentAdapter


def test_static_introspection():
    assert HermesAgentAdapter.name() == "hermes"
    assert HermesAgentAdapter.display_name() == "Hermes Agent (Nous Research)"
    desc = HermesAgentAdapter.description()
    assert "Nous Research" in desc
    schema = HermesAgentAdapter.get_config_schema()
    assert "model" in schema
    assert schema["model"]["type"] == "string"


def test_capabilities_provide_native_session():
    caps = HermesAgentAdapter().capabilities()
    assert caps.provides_native_session is True


def test_idle_timeout_override_is_15_min():
    assert HermesAgentAdapter().idle_timeout_override() == 900


# ---- setup() lifecycle ----------------------------------------------


@pytest.mark.asyncio
async def test_setup_skips_under_smoke_mode(monkeypatch):
    monkeypatch.setenv("MOLECULE_SMOKE_MODE", "1")
    # No HTTP server running anywhere — would fail if probe was attempted.
    cfg = AdapterConfig(model="hermes-test")
    await HermesAgentAdapter().setup(cfg)


@pytest.mark.asyncio
async def test_setup_probes_plugin_health_when_enabled(monkeypatch):
    """When MOLECULE_A2A_PLATFORM_ENABLED=true, setup() probes
    /a2a/health (NOT the legacy /v1/health). Plugin path is opt-in
    while the image-side install is being verified — see executor.py
    module docstring."""

    monkeypatch.delenv("MOLECULE_SMOKE_MODE", raising=False)
    monkeypatch.setenv("MOLECULE_A2A_PLATFORM_ENABLED", "true")

    health_port = _free_port()
    paths_hit: list[str] = []

    async def health_handler(request: web.Request) -> web.Response:
        paths_hit.append(request.path)
        return web.json_response({"ok": True, "platform": "molecule-a2a"})

    app = web.Application()
    app.router.add_get("/a2a/health", health_handler)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", health_port)
    await site.start()

    try:
        monkeypatch.setenv("MOLECULE_A2A_PLATFORM_PORT", str(health_port))
        cfg = AdapterConfig(model="hermes-test")
        await HermesAgentAdapter().setup(cfg)
    finally:
        await site.stop()
        await runner.cleanup()

    assert paths_hit == ["/a2a/health"]


@pytest.mark.asyncio
async def test_setup_probes_chat_completions_health_when_disabled(monkeypatch):
    monkeypatch.delenv("MOLECULE_SMOKE_MODE", raising=False)
    monkeypatch.setenv("MOLECULE_A2A_PLATFORM_ENABLED", "false")

    api_port = _free_port()
    paths_hit: list[str] = []

    async def health_handler(request: web.Request) -> web.Response:
        paths_hit.append(request.path)
        return web.json_response({"status": "ok"})

    app = web.Application()
    app.router.add_get("/health", health_handler)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", api_port)
    await site.start()

    try:
        monkeypatch.setenv(
            "HERMES_API_BASE", f"http://127.0.0.1:{api_port}/v1"
        )
        cfg = AdapterConfig(model="hermes-test")
        await HermesAgentAdapter().setup(cfg)
    finally:
        await site.stop()
        await runner.cleanup()

    assert paths_hit == ["/health"]


# ---- setup() retry-with-backoff ---------------------------------------
# The probe used to be single-shot with a 5s timeout because start.sh
# only exec'd molecule-runtime AFTER hermes-gateway was healthy. start.sh
# now backgrounds the gateway and exec's molecule-runtime immediately
# (race shape, see start.sh "Race molecule-runtime with hermes gateway"
# block + hermes-template#50). The adapter's probe handles the
# synchronization with retry + linear backoff up to a configurable budget.


@pytest.mark.asyncio
async def test_setup_retries_until_gateway_becomes_healthy(monkeypatch):
    """Gateway slow to come up: probe fails first attempt, succeeds
    on a later one within the budget. setup() returns successfully —
    operator's workspace works as soon as gateway is ready, no
    crash-and-restart required."""
    monkeypatch.delenv("MOLECULE_SMOKE_MODE", raising=False)
    monkeypatch.setenv("MOLECULE_A2A_PLATFORM_ENABLED", "false")
    monkeypatch.setenv("HERMES_GATEWAY_READY_BUDGET_SEC", "30")

    api_port = _free_port()
    state = {"started": False}
    paths_hit: list[str] = []

    async def health_handler(request: web.Request) -> web.Response:
        paths_hit.append(request.path)
        if not state["started"]:
            return web.Response(status=503)  # gateway warming up
        return web.json_response({"status": "ok"})

    app = web.Application()
    app.router.add_get("/health", health_handler)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", api_port)
    await site.start()

    try:
        monkeypatch.setenv("HERMES_API_BASE", f"http://127.0.0.1:{api_port}/v1")
        # Flip "started" after a couple of probe failures so the retry
        # loop actually exercises its retry path. The retry sleep is 2s,
        # so flipping after a small delay lets attempt 2 or 3 succeed.
        async def flip_after_delay():
            import asyncio as _asyncio
            await _asyncio.sleep(2.5)
            state["started"] = True

        import asyncio as _asyncio
        flip_task = _asyncio.create_task(flip_after_delay())

        cfg = AdapterConfig(model="hermes-test")
        await HermesAgentAdapter().setup(cfg)

        await flip_task
    finally:
        await site.stop()
        await runner.cleanup()

    # We saw at least 2 probes (one failure + one success).
    assert len(paths_hit) >= 2
    assert paths_hit[-1] == "/health"


@pytest.mark.asyncio
async def test_setup_raises_after_budget_exhausted(monkeypatch):
    """Gateway never becomes healthy: probe retries exhaust the budget,
    setup() raises RuntimeError with a helpful "after N attempt(s) over
    ~Ns" message. main.py's PR #2756 try/except mounts the not-configured
    handler so /agent-card stays 200 — operator sees a clean -32603 with
    the gateway-not-reachable reason."""
    monkeypatch.delenv("MOLECULE_SMOKE_MODE", raising=False)
    monkeypatch.setenv("MOLECULE_A2A_PLATFORM_ENABLED", "false")
    # Tight budget so the test runs in seconds, not minutes.
    monkeypatch.setenv("HERMES_GATEWAY_READY_BUDGET_SEC", "5")

    # Point at a port where nothing is listening — every probe fails.
    monkeypatch.setenv("HERMES_API_BASE", f"http://127.0.0.1:{_free_port()}/v1")

    cfg = AdapterConfig(model="hermes-test")
    with pytest.raises(RuntimeError, match=r"hermes-agent surface not reachable.*attempt"):
        await HermesAgentAdapter().setup(cfg)


@pytest.mark.asyncio
async def test_setup_invalid_budget_falls_back_to_default(monkeypatch):
    """Garbage in HERMES_GATEWAY_READY_BUDGET_SEC must not crash setup()
    with a ValueError — fall back to the 120s default. Operators
    misconfigure env vars; the runtime should be resilient.

    We don't actually wait 120s here — the test points at a port with
    a server that responds 200 immediately, so the probe succeeds on
    attempt 1 regardless of the budget value."""
    monkeypatch.delenv("MOLECULE_SMOKE_MODE", raising=False)
    monkeypatch.setenv("MOLECULE_A2A_PLATFORM_ENABLED", "false")
    monkeypatch.setenv("HERMES_GATEWAY_READY_BUDGET_SEC", "not-an-int")

    api_port = _free_port()

    async def health_handler(request: web.Request) -> web.Response:
        return web.json_response({"status": "ok"})

    app = web.Application()
    app.router.add_get("/health", health_handler)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", api_port)
    await site.start()

    try:
        monkeypatch.setenv("HERMES_API_BASE", f"http://127.0.0.1:{api_port}/v1")
        cfg = AdapterConfig(model="hermes-test")
        await HermesAgentAdapter().setup(cfg)  # no exception
    finally:
        await site.stop()
        await runner.cleanup()


# ---- create_executor lifecycle ---------------------------------------


@pytest.mark.asyncio
async def test_create_executor_returns_started_executor(monkeypatch):
    """create_executor() with plugin path enabled must return an
    executor whose reply server is already running (start() was
    called). Plugin path is opt-in while the image-side install is
    verified — see executor.py module docstring."""

    cb_port = _free_port()
    monkeypatch.setenv("MOLECULE_A2A_PLATFORM_ENABLED", "true")
    monkeypatch.setenv("MOLECULE_A2A_CALLBACK_PORT", str(cb_port))

    cfg = AdapterConfig(model="hermes-test")
    executor = await HermesAgentAdapter().create_executor(cfg)
    try:
        assert executor._started is True
        assert executor._reply_runner is not None
        assert executor._reply_site is not None
    finally:
        await executor.stop()


@pytest.mark.asyncio
async def test_create_executor_when_plugin_disabled_skips_reply_server(monkeypatch):
    monkeypatch.setenv("MOLECULE_A2A_PLATFORM_ENABLED", "false")
    cfg = AdapterConfig(model="hermes-test")
    executor = await HermesAgentAdapter().create_executor(cfg)
    try:
        assert executor._started is True
        # No reply server when fallback path is in use.
        assert executor._reply_runner is None
        assert executor._reply_site is None
    finally:
        await executor.stop()
