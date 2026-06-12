# shimon-vault/app/Dockerfile

# ─────────────────────────────────────────────────────────────────
# ShimonVault — FastAPI App Dockerfile
# Multi-platform build: supports linux/amd64 AND linux/arm64
# NEVER build with plain "docker build" — always use buildx
#
# Correct build command:
#   docker buildx build \
#     --platform linux/amd64,linux/arm64 \
#     -t mindmug/shimonvault-app:latest \
#     --push .
# ─────────────────────────────────────────────────────────────────

# Stage 1 — Builder
# $BUILDPLATFORM = the machine you are building ON (your Mac ARM64)
# This stage only installs Python deps — no native code that would
# produce the wrong arch binary.
FROM --platform=linux/amd64 python:3.12-slim AS builder

WORKDIR /build

# Install build tools needed by psycopg2-binary
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libpq-dev \
  && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --upgrade pip \
 && pip install --prefix=/install --no-cache-dir -r requirements.txt


# Stage 2 — Runtime
# $TARGETPLATFORM = the platform we are building FOR (linux/amd64 on AWS)
FROM --platform=$TARGETPLATFORM python:3.12-slim AS runtime

# Copy installed packages from builder
COPY --from=builder /install /usr/local

WORKDIR /app

# Create non-root user — security hardening
RUN useradd --create-home --shell /bin/bash appuser

# Copy application code
COPY . .

# Fix ownership so non-root user can read the code
RUN chown -R appuser:appuser /app

USER appuser

EXPOSE 8000

# Uvicorn starts the FastAPI app
# --host 0.0.0.0 so the container is reachable from outside
# --workers 1 because t3.micro has 2 vCPU — 1 worker is safe
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]