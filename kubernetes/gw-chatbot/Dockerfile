FROM python:3.11-slim

WORKDIR /app

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# NOTE: no pan-aisecurity SDK here – that is deliberate.
# In AI Gateway Intercept mode the Prisma AIRS guardrail runs inside the
# Portkey gateway, so the application carries no scanning code at all.

# Application code
COPY . .

# Writable document store for uploads (also the MCP server's root).
# The K8s deployment mounts an emptyDir over /app/documents, which would hide
# anything baked in here – so the seed corpus lives in a second directory and
# a postStart hook copies it across. Running the image plain (docker run) works
# too: DOCUMENTS_DIR already holds the seed files.
ENV DOCUMENTS_DIR=/app/documents
RUN mkdir -p /app/documents /app/seed-documents \
    && cp -r /app/documents/. /app/seed-documents/ 2>/dev/null || true

# Do not run as root
RUN useradd -m appuser && chown -R appuser /app
USER appuser

EXPOSE 8080

CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--timeout", "180", "--graceful-timeout", "180", "app:app"]
