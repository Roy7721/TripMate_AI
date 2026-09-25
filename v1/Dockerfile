# TripMate AI - v1 (hand-written tools)
#
# Build from the REPO ROOT (pyproject.toml and uv.lock are shared by all versions):
#   docker build -f v1/Dockerfile -t tripmate-v1 .
#
# Run (secrets come from .env at run time and are never baked into the image):
#   docker run --rm -p 8000:8000 --env-file .env tripmate-v1
#
# Then open http://localhost:8000

FROM python:3.14-slim

# uv (pinned to the same minor version as build-system in pyproject.toml)
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

# Application code (v1 is self-contained: app, backend, tools, static, templates)
COPY v1/ ./v1/

# Do not run as root
RUN useradd --create-home --uid 1000 app && chown -R app:app /app
USER app

# The code uses script-style imports (from backend import ...), so run from inside v1/
WORKDIR /app/v1

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=4)"

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
