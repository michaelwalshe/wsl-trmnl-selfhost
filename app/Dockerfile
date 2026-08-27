FROM python:3.12-slim
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/
WORKDIR /app

# Dependencies first, as their own layer: this only re-runs when
# pyproject.toml/uv.lock change, not on every app code edit.
COPY pyproject.toml uv.lock ./
RUN uv sync --locked --no-install-project --no-dev

# authorize_google.py is a one-off, interactive local setup script (see the
# README) -- it's never run inside the container, so it isn't copied in.
COPY main.py gcal.py weather.py env.py ./
RUN uv sync --locked --no-dev

ENV PATH="/app/.venv/bin:$PATH"
EXPOSE 8090
CMD ["gunicorn", "--bind", "0.0.0.0:8090", "--workers", "2", "main:app"]
