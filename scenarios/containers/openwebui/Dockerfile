# OpenWebUI Container - Configured for vLLM Integration
# Extends official OpenWebUI image with vLLM-specific configuration
# Built via OpenShift BuildConfig pipeline (webhook trigger)

FROM ghcr.io/open-webui/open-webui:main

# Metadata
LABEL name="openwebui" \
      version="1.0.1" \
      description="OpenWebUI chat interface configured for vLLM backend" \
      maintainer="Red Hat Emerging Technologies" \
      io.openshift.tags="ai,llm,ui,chat,web"

# OpenWebUI runs on port 8080 internally
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD curl -f http://localhost:8080/health || exit 1

# Default environment variables for vLLM connection
# These can be overridden at runtime
ENV OPENAI_API_BASE_URL=http://vllm-server:8000/v1 \
    OPENAI_API_KEY="" \
    WEBUI_NAME="MLOps Edge AI Chat" \
    ENABLE_SIGNUP=true

# Data directory for persistent storage
VOLUME /app/backend/data

# Default command (inherited from base image)
# CMD ["bash", "start.sh"]
