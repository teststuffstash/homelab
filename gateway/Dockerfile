# agent-gateway — the LLM egress gateway island (homelab gateway/, ADR-139 P2).
# Built by .github/workflows/gateway-image.yaml on master pushes of gateway/**; the deploy pins
# ghcr.io/teststuffstash/agent-gateway:<calver-gsha>. Non-root (uid 1000), uv-synced, frozen lock.
FROM python:3.15-slim AS build
COPY --from=ghcr.io/astral-sh/uv:0.13.1 /uv /usr/local/bin/uv
ENV UV_LINK_MODE=copy UV_COMPILE_BYTECODE=1 UV_PYTHON_DOWNLOADS=never UV_PROJECT_ENVIRONMENT=/app/.venv
WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project
COPY src ./src
RUN uv sync --frozen --no-dev

FROM python:3.15-slim
RUN useradd --uid 1000 --user-group --no-create-home gateway && mkdir -p /data /etc/agent-gateway \
    && chown gateway:gateway /data
COPY --from=build /app /app
ENV PATH=/app/.venv/bin:$PATH \
    PYTHONUNBUFFERED=1 \
    GATEWAY_POLICY=/etc/agent-gateway/policy.json \
    GATEWAY_DB=/data/gateway.db
USER 1000
WORKDIR /app
EXPOSE 8080
CMD ["python", "-m", "agent_gateway"]
