# ═══════════════════════════════════════════════════════════════════
#  Dockerfile – AI Chatbot (Vertex AI Gemini + Flask)
#  Prisma AIRS Network Intercept demo
# ═══════════════════════════════════════════════════════════════════

FROM python:3.11-slim

# Metadata
LABEL maintainer="AIRS Webinar Demo"
LABEL description="AI Chatbot protected by Prisma AIRS Network Intercept"
LABEL version="1.0"

# Do not run as root
RUN groupadd -r chatbot && useradd -r -g chatbot -u 1000 chatbot

# Working directory
WORKDIR /app

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Application code
COPY app.py .
COPY templates/ ./templates/
COPY i18n/ ./i18n/

# Optional static assets (may be empty)
RUN mkdir -p ./static
COPY static/ ./static/

# Permissions
RUN chown -R chatbot:chatbot /app

# Switch to unprivileged user
USER chatbot

# App port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# Run the app via gunicorn (production WSGI server)
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--timeout", "120", "--access-logfile", "-", "app:app"]
