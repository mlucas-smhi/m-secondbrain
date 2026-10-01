# syntax=docker/dockerfile:1
# Native upstream MCP: no facade, tool rewriting, or extraction patch.
FROM python:3.12-slim-bookworm@sha256:392307d22300de8b5986851a12d9176dfc0fc073e65bf6523ebd7dcbeb23564e AS graphiti
ARG GRAPHITI_REVISION=3c427640abf909f12f71f963fce15eb514a3c493
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir uv==0.8.22
WORKDIR /opt/graphiti
RUN git init . && git remote add origin https://github.com/getzep/graphiti.git \
    && git fetch --depth 1 origin "$GRAPHITI_REVISION" \
    && git checkout --detach FETCH_HEAD \
    && test "$(git rev-parse HEAD)" = "$GRAPHITI_REVISION"
WORKDIR /opt/graphiti/mcp_server
# Use upstream's committed lock, rather than resolving latest dependencies.
# No optional local-model/GPU dependencies.
RUN UV_PYTHON_DOWNLOADS=never uv sync --frozen --no-dev --python /usr/local/bin/python3.12 \
    && useradd --uid 10001 --create-home graphiti
COPY ontology.json compile_ontology.py /opt/ea-ontology/
# Native custom-model registration; no graphiti-core/queue/tool rewrites.
RUN .venv/bin/python /opt/ea-ontology/compile_ontology.py --install /opt/graphiti/mcp_server
ENV PATH="/opt/graphiti/mcp_server/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    GRAPHITI_TELEMETRY_ENABLED=false \
    SEMAPHORE_LIMIT=2 \
    BROWSER=0
LABEL org.opencontainers.image.revision=$GRAPHITI_REVISION
USER 10001
EXPOSE 8000
CMD ["python", "main.py", "--config", "config/ea-config.json"]

FROM caddy:2.10-alpine@sha256:4c6e91c6ed0e2fa03efd5b44747b625fec79bc9cd06ac5235a779726618e530d AS gateway
COPY Caddyfile /etc/caddy/Caddyfile
