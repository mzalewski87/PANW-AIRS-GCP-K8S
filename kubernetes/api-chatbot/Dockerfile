FROM python:3.11-slim

WORKDIR /app

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# AIRS SDK (pan-aisecurity) – optional install.
# Requires an active Palo Alto AIRS subscription.
# If unavailable, the application starts in demo mode (no AIRS scanning).
# Docs: https://pan.dev/prisma-airs/api/airuntimesecurity/pythonsdk/
RUN pip install --no-cache-dir pan-aisecurity 2>/dev/null || \
    echo "⚠️  pan-aisecurity SDK not available – AIRS scanning disabled (demo mode)"

# Application code
COPY . .

# Do not run as root
RUN useradd -m appuser && chown -R appuser /app
USER appuser

EXPOSE 8080

CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "4", "--timeout", "120", "--graceful-timeout", "120", "app:app"]
