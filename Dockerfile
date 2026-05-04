# Pin by digest, not tag — avoids surprise base-bumps. Pairs with the
# Trivy gate in molecule-ci/.github/workflows/publish-template-image.yml
# (PR #35): pin avoids unexpected upgrade, Trivy catches if the pinned
# digest accumulates fixable HIGH/CRITICAL vulns over time. Bump
# deliberately by re-resolving:
#   docker pull --platform linux/amd64 python:3.11-slim
#   docker inspect --format='{{index .RepoDigests 0}}' python:3.11-slim
# Last resolved: 2026-05-03 (RFC #388 PR-2b).
FROM python:3.11-slim@sha256:6d85378d88a19cd4d76079817532d62232be95757cb45945a99fec8e8084b9c2

# ─────────────────────────────────────────────────────────────────────
# CACHE-FRIENDLY LAYER ORDER — read before adding new layers.
#
# Layers are ordered slowest-and-most-stable → fastest-and-most-changing.
# When `cache-from: type=gha` hits, Docker reuses the cached output of a
# layer iff (a) its command text is identical AND (b) every prior layer
# was also a cache hit. Any earlier layer that changes invalidates ALL
# subsequent layers.
#
# The expensive layers are:
#   1. apt-get install (build-essential + Node-tarball xz extractor)
#   2. pip install -r requirements.txt
#   3. curl|bash hermes-agent installer (downloads Node 22 ~140 MB +
#      builds hermes-agent from source, ~2-4 min by itself)
#   4. pip install hermes fork + platform plugin from git
#
# These ~rarely change (only on Dockerfile edits / requirements bumps /
# fork-ref bumps) so they belong UP TOP. The cheap, high-churn `COPY *.py`
# layers belong AT THE BOTTOM. Putting the hermes installer below the
# COPYs caused every adapter.py / executor.py / scripts/ change to bust
# its cache → 5-12 min publish-image runs (vs 1-3 min for sibling
# templates). Don't move the COPYs back above the hermes install.
# ─────────────────────────────────────────────────────────────────────

# System deps:
#   curl         — hermes installer + loopback health probe in start.sh
#   ca-certificates — TLS for all the outbound installs
#   git          — hermes installer clones the repo; also used by agent tools
#   gosu         — drop privileges in start.sh (single-process friendly)
#   xz-utils     — hermes installer extracts a Node 22 tarball (.tar.xz)
#   build-essential — some python deps in hermes `.[all]` extra compile from src
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates git gosu xz-utils build-essential \
    && rm -rf /var/lib/apt/lists/*

# Non-root agent user. hermes-agent writes its state into ~/.hermes so
# mounting /home/agent as a persistent volume keeps skills + memory
# across workspace restarts.
RUN useradd -u 1000 -m -s /bin/bash agent

# --- Install molecule_runtime (bridge + A2A server) ---
# RUNTIME_VERSION is forwarded from molecule-ci's reusable publish
# workflow as a docker build-arg. Cascade-triggered builds set it to
# the exact runtime version PyPI just published. Including it as an
# ARG changes the cache key for the pip install layer below — without
# this, identical Dockerfile + identical requirements.txt would let
# docker reuse the cached layer with the previous version baked in
# (the cache trap that bit us 5x on 2026-04-27).
ARG RUNTIME_VERSION=

WORKDIR /app
# Bump pip + setuptools + wheel BEFORE installing project deps — the
# python:3.11-slim base ships old transitives (jaraco.context, wheel,
# setuptools) Trivy flags as fixable HIGH CVEs. Bumping here resolves
# them at the metadata layer; subsequent pip installs use the upgraded
# resolvers. molecule-ci#38 Phase-1.
RUN pip install --no-cache-dir --upgrade pip setuptools wheel

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && \
    if [ -n "${RUNTIME_VERSION}" ]; then \
      pip install --no-cache-dir --upgrade "molecule-ai-workspace-runtime==${RUNTIME_VERSION}"; \
    fi

# --- Install the real Nous Research hermes-agent as the agent user ---
# This MUST stay above the COPY *.py layers below (see cache-order
# rationale at the top of the file). The installer text is fixed —
# changing the upstream main branch will not invalidate the layer
# unless you also touch the RUN command itself.
#
# The installer lives under the agent's home (~/.hermes, symlinks the
# `hermes` entrypoint into ~/.local/bin/). Running as root would place
# it in /root and break discovery.
#   --skip-setup → no interactive wizard (curl|bash is non-tty anyway
#                  but the installer treats this as "run anyway" by
#                  default; passing it explicitly avoids surprises).
USER agent
WORKDIR /home/agent
RUN curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh \
      | bash -s -- --skip-setup
# hermes installer symlinks ~/.hermes/hermes-agent/venv/bin/hermes into
# ~/.local/bin/hermes, so ~/.local/bin is the only PATH entry we need.
ENV PATH="/home/agent/.local/bin:${PATH}"

# --- Molecule A2A platform plugin (post-demo: native push parity) ---
# Two refs are installed into the same venv that the upstream installer
# created above:
#
#   1. A pinned hermes-agent fork carrying the proposed
#      `register_platform_adapter` patch series (NousResearch/hermes-agent
#      PR #18775). Installed --force-reinstall over the upstream wheel so
#      `hermes_cli/plugins.py` exposes PluginContext.register_platform_adapter
#      and `gateway/run.py` honors plugin_platforms. Same deps as upstream
#      (the patch is pure-Python additions), so no resolver impact.
#   2. The Molecule A2A platform plugin itself, auto-discovered via
#      hermes's `hermes_agent.plugins` entry-point group.
#
# Until upstream PR #18775 merges, the fork is the only place the patch
# exists. Once merged + released, the fork install can be dropped and the
# plugin will load against the official wheel unchanged.
ARG HERMES_FORK_REF=feat/platform-adapter-plugins
ARG HERMES_PLATFORM_MOLECULE_A2A_REF=main
# The hermes installer uses uv to create the venv and doesn't seed pip
# into it. Bootstrap pip first via ensurepip, then install both wheels.
RUN /home/agent/.hermes/hermes-agent/venv/bin/python3 -m ensurepip --upgrade && \
    /home/agent/.hermes/hermes-agent/venv/bin/python3 -m pip install --no-cache-dir --force-reinstall \
      "git+https://github.com/HongmingWang-Rabbit/hermes-agent.git@${HERMES_FORK_REF}#egg=hermes-agent" && \
    /home/agent/.hermes/hermes-agent/venv/bin/python3 -m pip install --no-cache-dir \
      "git+https://github.com/Molecule-AI/hermes-platform-molecule-a2a.git@${HERMES_PLATFORM_MOLECULE_A2A_REF}#egg=hermes-platform-molecule-a2a"

# ─────────────────────────────────────────────────────────────────────
# Fast-changing layers — keep at the bottom.
# Edits to adapter.py / executor.py / scripts/ / start.sh only invalidate
# from here down (~5-10 s of work) instead of busting the hermes installer.
# ─────────────────────────────────────────────────────────────────────
USER root
WORKDIR /app
COPY adapter.py .
COPY __init__.py .
COPY executor.py .
COPY scripts/ /app/scripts/
COPY start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

ENV ADAPTER_MODULE=adapter \
    HERMES_API_BASE=http://127.0.0.1:8642/v1 \
    API_SERVER_ENABLED=true \
    API_SERVER_HOST=127.0.0.1 \
    API_SERVER_PORT=8642 \
    MOLECULE_A2A_PLATFORM_ENABLED=true \
    MOLECULE_A2A_PLATFORM_HOST=127.0.0.1 \
    MOLECULE_A2A_PLATFORM_PORT=8645 \
    MOLECULE_A2A_CALLBACK_HOST=127.0.0.1 \
    MOLECULE_A2A_CALLBACK_PORT=8646

# start.sh boots `hermes gateway` in the background, waits for :8642
# readiness, then exec's molecule-runtime on :8000.
ENTRYPOINT ["/usr/local/bin/start.sh"]
