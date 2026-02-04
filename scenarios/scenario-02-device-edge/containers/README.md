# MLOps Containers - Scenario 02 (Device Edge)

Three-container stack for deploying Llama 3.2 1B model inference at the edge.

## Container Overview

### 1. modelcar
**Purpose:** Sidecar container that provides model files via shared volume

**Contains:** Llama 3.2 1B Instruct model files (~2-3GB)

**Build:**
```bash
cd modelcar
export HF_TOKEN=hf_your_token_here
python model-downloader.py
podman build -t quay.io/redhat-et/modelcar-llama-3.2-1b:dev .
```

**Runtime:** Runs `sleep infinity`, exposes `/models` directory

---

### 2. vllm-server
**Purpose:** GPU-accelerated inference server

**Requires:** NVIDIA GPU with CDI support, model files from modelcar

**Build:**
```bash
cd vllm-server
podman build -t quay.io/redhat-et/vllm-server:latest .
```

**API:** OpenAI-compatible API on port 8000

---

### 3. openwebui
**Purpose:** Chat UI frontend for interacting with the model

**Requires:** vLLM server running on localhost:8000

**Build:**
```bash
cd openwebui
podman build -t quay.io/redhat-et/openwebui:latest .
```

**UI:** Web interface on port 8080

---

## How They Work Together

```
modelcar (model files)
    ↓ (model-storage volume)
vllm-server (GPU inference) → port 8000
    ↓ (HTTP API)
openwebui (chat UI) → port 8080
    ↓ (openwebui-data volume for persistence)
```

### Volumes

**model-storage:**

- Shared between modelcar and vllm-server
- Contains model files (~2-3GB)
- Read-only mount for vllm-server

**openwebui-data:**

- Used by openwebui container
- Stores user accounts, chat history, settings
- Persists across container restarts

### Data Flow

1. **modelcar** runs and shares `/models` directory via `model-storage` volume
2. **vllm-server** mounts the same volume (read-only), loads model into GPU memory, serves API
3. **openwebui** connects to vLLM API, provides web UI, stores data in `openwebui-data` volume

---
