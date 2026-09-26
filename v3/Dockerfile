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
#    must stay in the image. The package is pre-installed at build time, so the first
#    flight request does not download anything and works even if PyPI is unreachable.
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

# Create the user BEFORE anything is written into /app. uv then writes files that
# already belong to `app`, so no `chown -R` is needed afterwards. The old chown
# rewrote all 15,075 venv files into a second 377MB layer that carried no new
# content - bytes pushed to Docker Hub and pulled by Azure on every cold start.
RUN useradd --create-home --uid 1000 app \
 && mkdir -p /app \
 && chown app:app /app

WORKDIR /app
USER app

# Dependencies first, so this layer is cached until pyproject.toml / uv.lock change.
# --no-install-project: only third-party packages are needed, not the tripmate_ai stub.
# --no-cache: uv otherwise leaves a 266MB download cache inside the image that nothing
# reads at run time. Docker's own layer cache still skips this whole step while the
# lock file is unchanged, so ordinary rebuilds are unaffected.
COPY --chown=app:app pyproject.toml uv.lock README.md .python-version ./
RUN uv sync --frozen --no-dev --no-install-project --no-cache

# Application code (v3 is self-contained: app, backend, mcp_client, weather server, static, templates)
COPY --chown=app:app v3/ ./v3/

# Pre-install the AviationStack MCP server. Without this, the first flight request in a
# fresh container spends 15-25s resolving and downloading 40 packages from PyPI before
# any flight lookup starts - out of the 240s Azure Container Apps allows per request.
# Verified: uvx then starts it with --offline, so a PyPI outage cannot break a request.
# --no-cache drops a further 51MB of download cache from /home/app/.cache.
RUN uv tool install --no-cache aviationstack-mcp==1.8.1

# The code uses script-style imports (from backend import ...), so run from inside v3/
WORKDIR /app/v3

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=4)"

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
