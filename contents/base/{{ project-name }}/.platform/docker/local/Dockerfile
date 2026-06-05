FROM python:3.12-slim AS builder
WORKDIR /app

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    && rm -rf /var/lib/apt/lists/*

# Install pip and uv
RUN pip install --no-cache-dir uv

# Copy project definition and install dependencies
COPY pyproject.toml ./
RUN uv pip install --system --no-cache -e .

FROM python:3.12-slim
WORKDIR /app

# Install CA certificates for TLS
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN addgroup --system --gid 1001 appgroup && \
    adduser --system --uid 1001 --gid 1001 appuser

# Copy installed packages from builder
COPY --from=builder /usr/local/lib/python3.12 /usr/local/lib/python3.12
COPY --from=builder /usr/local/bin/{{ project-name }} /usr/local/bin/{{ project-name }}

# Copy application source
COPY src/ ./src/

USER appuser

EXPOSE {{ service_port }} {{ management_port }}

ENTRYPOINT ["{{ project-name }}"]
