# vLLM Server Container - Red Hat AI Inference Server Based
# Extends official Red Hat vLLM CUDA image with model car integration

FROM registry.redhat.io/rhaiis/vllm-cuda-rhel9:3.0.0

# Metadata
LABEL name="vllm-server" \
      version="1.0.0" \
      description="vLLM inference server configured for model car integration" \
      maintainer="Red Hat Emerging Technologies" \
      io.openshift.tags="ai,llm,vllm,inference,gpu"

# Run as non-root user (Red Hat standard)
USER 1001

# Expose vLLM API port
EXPOSE 8000

# Health check endpoint
HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=60s \
  CMD curl -f http://localhost:8000/health || exit 1

# Default environment variables (can be overridden at runtime)
ENV MODEL_PATH=/models \
    VLLM_PORT=8000 \
    VLLM_HOST=0.0.0.0

# Default: start the inference server
CMD ["vllm", "serve", "/models", \
     "--host", "0.0.0.0", \
     "--port", "8000", \
     "--dtype", "bfloat16", \
     "--max-model-len", "16384"]
