"""Tests for the adapter-side boot debug logging helpers.

The 2026-05-02 crash-loop diagnosis (in template-claude-code) hinged on
operators being able to see, from `docker logs` alone, *which* auth env
names were set vs unset at boot. This test pins the same contract for the
hermes template — `_audit_auth_env_presence` must emit a single INFO line
listing every name in `_AUTH_ENV_AUDIT` with its presence status, and
must NEVER include the value.

Hermes diverges from claude-code in WHICH names are in the audit set:
hermes-agent reads each per-vendor env directly (no projection onto
ANTHROPIC_AUTH_TOKEN), so the audit list enumerates the full per-vendor
set that start.sh forwards into hermes-agent's .env.

Test isolation: adapter.py imports molecule_runtime + a2a-style deps at
module load. Neither is installed in this template's lean test env (the
template ships its own stripped-down test set so CI doesn't pull a heavy
runtime wheel just to lint the adapter helpers). We stub them with empty
modules so the audit helpers can import cleanly.
"""
from __future__ import annotations

import importlib.util
import logging
import re
import sys
import types
from pathlib import Path

import pytest


@pytest.fixture
def adapter_module(monkeypatch):
    """Load the template's adapter module without its molecule_runtime dep.

    The full adapter requires molecule_runtime at import time, which
    isn't installed in the lean test env. We stub it with an empty
    module exposing the three names adapter.py imports
    (BaseAdapter, AdapterConfig, RuntimeCapabilities) so the
    module-level helpers (_AUTH_ENV_AUDIT, _audit_auth_env_presence)
    can be imported in isolation.
    """
    pkg = types.ModuleType("molecule_runtime")
    sub = types.ModuleType("molecule_runtime.adapters")
    base = types.ModuleType("molecule_runtime.adapters.base")
    base.BaseAdapter = type("BaseAdapter", (), {})
    base.AdapterConfig = type("AdapterConfig", (), {})
    base.RuntimeCapabilities = type("RuntimeCapabilities", (), {})
    monkeypatch.setitem(sys.modules, "molecule_runtime", pkg)
    monkeypatch.setitem(sys.modules, "molecule_runtime.adapters", sub)
    monkeypatch.setitem(sys.modules, "molecule_runtime.adapters.base", base)

    template_dir = Path(__file__).resolve().parent.parent
    monkeypatch.syspath_prepend(str(template_dir))

    # Force-reload so the stubs take effect even if a sibling test
    # already imported the real (or partially-stubbed) module first.
    sys.modules.pop("adapter", None)
    spec = importlib.util.spec_from_file_location(
        "adapter", template_dir / "adapter.py"
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_audit_lists_every_name_with_presence(adapter_module, monkeypatch, caplog):
    """The audit log must enumerate every name in _AUTH_ENV_AUDIT, set or unset."""
    # Set ONE vendor key with a sentinel value; clear everything else.
    monkeypatch.setenv("MINIMAX_API_KEY", "fake-secret-MUST-NOT-LEAK")
    for name in adapter_module._AUTH_ENV_AUDIT:
        if name != "MINIMAX_API_KEY":
            monkeypatch.delenv(name, raising=False)

    with caplog.at_level(logging.INFO, logger="adapter"):
        adapter_module._audit_auth_env_presence()

    # Single log record, INFO level, prefix "auth env audit:"
    matching = [r for r in caplog.records if "auth env audit" in r.getMessage()]
    assert len(matching) == 1, (
        f"expected exactly one audit record, got {len(matching)}"
    )
    msg = matching[0].getMessage()

    # Every audited name appears with set/unset status
    for name in adapter_module._AUTH_ENV_AUDIT:
        assert f"{name}=" in msg, f"audit message missing {name}: {msg!r}"

    # MINIMAX_API_KEY is set, the others unset
    assert "MINIMAX_API_KEY=set" in msg
    assert "ANTHROPIC_API_KEY=unset" in msg
    assert "GLM_API_KEY=unset" in msg
    assert "DEEPSEEK_API_KEY=unset" in msg

    # Critical security assertion: the SECRET VALUE itself must NOT
    # appear. If this regresses, the audit is leaking secrets to
    # operator-visible docker logs and (worse) to the platform's
    # central log aggregator.
    assert "fake-secret-MUST-NOT-LEAK" not in msg, (
        "audit log leaked the env VALUE — must be names + set/unset only"
    )


def test_audit_with_all_unset(adapter_module, monkeypatch, caplog):
    """All names report 'unset' when no auth env is configured.

    This is the crash-loop scenario — workspace boots with no provider
    key at all. The audit must still fire (an all-unset line is the
    operator's fastest signal that the env injection failed entirely
    upstream, not just that one specific key was missed).
    """
    for name in adapter_module._AUTH_ENV_AUDIT:
        monkeypatch.delenv(name, raising=False)

    with caplog.at_level(logging.INFO, logger="adapter"):
        adapter_module._audit_auth_env_presence()

    matching = [r for r in caplog.records if "auth env audit" in r.getMessage()]
    assert len(matching) == 1
    msg = matching[0].getMessage()
    for name in adapter_module._AUTH_ENV_AUDIT:
        assert f"{name}=unset" in msg


def test_audit_treats_empty_string_as_unset(adapter_module, monkeypatch, caplog):
    """Empty-string env values report as 'unset' — matches start.sh semantics.

    workspace-server's nil/empty handling could plausibly export
    MINIMAX_API_KEY="" instead of omitting it. The shell side already
    treats `${VAR:+...}` as unset for empty strings (which is why
    start.sh's .env-write block doesn't forward empty keys), so the
    Python audit must agree: an empty key is, semantically, unset.
    Otherwise the operator sees `MINIMAX_API_KEY=set` in the audit
    while hermes-agent silently rejects it as missing.
    """
    monkeypatch.setenv("MINIMAX_API_KEY", "")
    for name in adapter_module._AUTH_ENV_AUDIT:
        if name != "MINIMAX_API_KEY":
            monkeypatch.delenv(name, raising=False)

    with caplog.at_level(logging.INFO, logger="adapter"):
        adapter_module._audit_auth_env_presence()

    msg = [
        r.getMessage()
        for r in caplog.records
        if "auth env audit" in r.getMessage()
    ][0]
    assert "MINIMAX_API_KEY=unset" in msg


def test_audit_env_list_matches_start_sh(adapter_module):
    """_AUTH_ENV_AUDIT in adapter.py must mirror the for-loop in start.sh.

    start.sh emits the same set of NAME=set/unset lines BEFORE the
    hermes gateway spawns and BEFORE the Python adapter ever runs, so
    an operator can correlate a missing key across the gateway boot.
    If the two lists drift, an env name added in one place but not
    the other becomes invisible at one tier — exactly the
    crash-loop diagnosis gap that bit claude-code 2026-05-02.

    Pin the union by parsing the shell loop and asserting set-equality.
    Selector: the audit for-loop is the unique start.sh for-loop that
    iterates over `var` AND mentions HERMES_API_KEY (other for-loops
    in start.sh iterate over `_` for readiness polling and don't
    contain provider env names).
    """
    template_dir = Path(__file__).resolve().parent.parent
    start_sh = (template_dir / "start.sh").read_text()

    loop_line = next(
        (
            line for line in start_sh.splitlines()
            if "for var in" in line and "HERMES_API_KEY" in line
        ),
        None,
    )
    assert loop_line, "start.sh missing the auth-env audit for-loop"

    # `for var in A B C; do` → ['A', 'B', 'C']
    names_in_shell = (
        loop_line.split("for var in", 1)[1]
        .split(";", 1)[0]
        .split()
    )

    # Filter to identifier-shaped tokens to be robust against future
    # additions of inline shell expansion.
    names_in_shell = [n for n in names_in_shell if re.fullmatch(r"[A-Z_][A-Z0-9_]*", n)]

    assert set(names_in_shell) == set(adapter_module._AUTH_ENV_AUDIT), (
        f"adapter.py _AUTH_ENV_AUDIT ({set(adapter_module._AUTH_ENV_AUDIT)}) "
        f"and start.sh for-loop ({set(names_in_shell)}) disagree on the "
        "audit set — keep them in sync (see the comment in adapter.py "
        "above _AUTH_ENV_AUDIT)."
    )
