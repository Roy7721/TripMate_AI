# TripMate AI - v3 (supervisor agent, input guardrail, human-in-the-loop approval)
# Same MCP tools as v2: Tavily, AviationStack, custom weather server.
#
# Build from the REPO ROOT (pyproject.toml and uv.lock are shared by all versions):
#   docker build -f v3/Dockerfile -t tripmate-v3 .
#
# Run (secrets come from .env at run time and are never baked into the image):
#   docker run --rm -p 8000:8000 --env-file .env tripmate-v3
#
# Then open http://localhost:8000
#
# Notes:
#  - The AviationStack MCP server is started with `uvx aviationstack-mcp`, so uv/uvx
#    must stay in the image and the container needs internet access. The first flight
#    request downloads that package (slower once), later requests reuse the cache.
#  - The weather MCP server (custom_mcp_server.py) is started with the venv's Python.
#  - The human-approval step pauses the graph and saves its state in PostgreSQL (the
#    LangGraph checkpointer), not in the container's memory.

FROM python:3.14-slim

# uv + uvx (pinned to the same minor version as build-system in pyproject.toml)
COPY --from=ghcr.io/astral-sh/uv:0.12 /uv /uvx /bin/

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    PATH="/app/.venv/bin:$PATH"

WORKDIR /app

# Dependencies first, so this layer is cached until pyproject.toml / uv.lock change.
# --no-install-project: only third-party packages are needed, not the tripmate_ai stub.
COPY pyproject.toml uv.lock README.md .python-version ./
RUN uv sync --frozen --no-dev --no-install-project

# Application code (v3 is self-contained: app, backend, mcp_client, weather server, static, templates)
COPY v3/ ./v3/

# Do not run as root. The home directory is where uvx keeps its package cache.
RUN useradd --create-home --uid 1000 app && chown -R app:app /app
USER app

# Pre-install the AviationStack MCP server. Without this, the first flight request in a
# fresh container spends 15-25s resolving and downloading 40 packages from PyPI before
# any flight lookup starts - out of the 240s Azure Container Apps allows per request.
# Installed as `app` so it lands in /home/app, where uvx looks. Verified: uvx then
# starts it with --offline, so a PyPI outage cannot break a live request.
RUN uv tool install aviationstack-mcp==1.8.1

# The code uses script-style imports (from backend import ...), so run from inside v3/
WORKDIR /app/v3

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=4)"

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
