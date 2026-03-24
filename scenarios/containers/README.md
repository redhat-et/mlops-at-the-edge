# Getting Started - GPU Inference Stack

Deployment guide for the three-container GPU inference stack using the pre-built bootc image.

**Status:** ✅ Tested and verified (NVIDIA A10G, RHEL 10 BootC)

---

## Overview

This guide walks through deploying:

1. **modelcar-llama-3.2-1b** - Model sidecar providing Llama 3.2 1B files
2. **vllm-server** - GPU-accelerated inference server (port 8000)
3. **openwebui** - Chat UI frontend (port 8080)

**Architecture:**
```
modelcar (model files)
    ↓ (shared via model-storage volume)
vllm-server (GPU inference) → port 8000
    ↓ (HTTP API on localhost)
openwebui (chat UI) → port 8080
```

---

## Networking and Volume Sharing

### How Containers Communicate

**modelcar → vllm-server (Volume Sharing):**

- modelcar container keeps model files at `/models` inside the container
- Both containers mount the same named volume `model-storage`
- modelcar writes to the volume, vllm-server reads from it
- **No network connection needed** - file sharing via Podman volume

**vllm-server → openwebui (HTTP API):**

- vllm-server uses **bridge network** and exposes port 8000 to host
- openwebui uses **host network** (`--network host`)
- openwebui connects to vLLM via `http://localhost:8000/v1`
- **Why host network for openwebui?** Simplifies localhost connectivity and exposes UI on port 8080

### Volume Mounting Explained

**Podman Named Volumes:**
```bash
# Create named volume (stored in /var/lib/containers/storage/volumes/)
sudo podman volume create model-storage

# Container 1: modelcar writes to volume
sudo podman run --volume model-storage:/models:z ...
# :z = shared SELinux label (multiple containers can access)

# Container 2: vllm-server reads from same volume
sudo podman run --volume model-storage:/models:ro,z ...
# :ro = read-only mount (vLLM doesn't modify models)
# :z = shared SELinux label
```

Both containers see the same files at `/models`, but modelcar can write and vllm-server can only read.

**Important:** Use lowercase `:z` (shared) not uppercase `:Z` (private) when multiple containers share a volume. `:Z` relabels the volume for exclusive access by one container, which would lock out the other.

### Network Diagram

```
┌─────────────────────────────────────────────────────┐
│ Host OS                                             │
│                                                     │
│  ┌──────────────┐        Podman Volume              │
│  │  model-car   │────►  model-storage               │
│  └──────────────┘        (shared files)             │
│                                 │                   │
│                                 ▼                   │
│  ┌──────────────┐        ┌──────────┐               │
│  │ vllm-server  │◄───────┤ /models  │               │
│  │ (bridge net) │        └──────────┘               │
│  └──────┬───────┘                                   │
│         │ port 8000 (exposed)                       │
│         │                                           │
│         ▼                                           │
│  ┌──────────────┐                                   │
│  │  openwebui   │                                   │
│  │ (host net)   │ connects to localhost:8000        │
│  └──────┬───────┘                                   │
│         │ port 8080 (on host network)               │
└─────────┼───────────────────────────────────────────
          │
          ▼
    User Browser: http://<device-ip>:8080
```

---

## Prerequisites

**Hardware requirements:**
- NVIDIA GPU with 4GB+ VRAM (tested on A10G with 24GB)
- 16GB+ RAM
- 50GB+ storage

---

## Step 0: Verify GPU Configuration

After deploying the bootc image to your device, SSH in and verify prerequisites:

### Verify GPU is available

```bash
nvidia-smi
```

**Expected output:**
```
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 590.48.01              Driver Version: 590.48.01      CUDA Version: 13.1     |
+-----------------------------------------+------------------------+----------------------+
| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
|   0  NVIDIA A10G                    Off |   00000000:00:1E.0 Off |                    0 |
+-----------------------------------------------------------------------------------------+
```

### Verify CDI configuration exists

```bash
ls -la /etc/cdi/nvidia.yaml
```

**Expected:** File exists with NVIDIA CDI spec.

**Verify CDI devices:**
```bash
sudo nvidia-ctk cdi list
```

**Expected:** Should list `nvidia.com/gpu=all` and individual GPU devices.

---

## Manual Deployment 

These steps show how to manually deploy the stack for testing.

### Step 1: Pull Container Images

Pull all three pre-built images from Quay:

```bash
sudo podman pull quay.io/redhat-et/modelcar-llama-3.2-1b:v1.0.0
sudo podman pull quay.io/redhat-et/vllm-server:latest
sudo podman pull quay.io/redhat-et/openwebui:latest
```

**Note:** If images are private, authenticate first:
```bash
echo "YOUR_QUAY_PASSWORD" | sudo podman login quay.io -u "YOUR_QUAY_USERNAME" --password-stdin
```

**Verify images were pulled:**
```bash
sudo podman images | grep redhat-et
```

---

### Step 2: Create Persistent Volumes

```bash
# Create volumes for model files and OpenWebUI data
sudo podman volume create model-storage
sudo podman volume create openwebui-data
```

**Verify volumes were created:**
```bash
sudo podman volume ls
```

**Expected output:**
```
DRIVER      VOLUME NAME
local       model-storage
local       openwebui-data
```

---

### Step 3: Start modelcar (Model Sidecar)

```bash
sudo podman run -d \
  --name model-car \
  --volume model-storage:/models:z \
  quay.io/redhat-et/modelcar-llama-3.2-1b:v1.0.0 \
  sleep infinity
```

**Key flags:**
- `--volume model-storage:/models:z` - Mounts volume with shared SELinux label (lowercase `:z` allows other containers to access)
- `sleep infinity` - Keeps container running to share model files

**Verify container is running:**

```bash
sudo podman ps | grep model-car
```

**Expected:** Container status shows "Up"

**Verify model files are present:**

```bash
sudo podman exec model-car ls -la /models
```

**Expected output:**
```
total 2422676
drwxr-xr-x. 4 root root       4096 Feb 11 14:20 .
-rw-r--r--. 1 root root       7712 Feb 11 14:18 LICENSE.txt
-rw-r--r--. 1 root root        877 Feb 11 14:18 config.json
-rw-r--r--. 1 root root        189 Feb 11 14:18 generation_config.json
-rw-r--r--. 1 root root 2471645608 Feb 11 14:20 model.safetensors
-rw-r--r--. 1 root root        296 Feb 11 14:18 special_tokens_map.json
-rw-r--r--. 1 root root    9085657 Feb 11 14:18 tokenizer.json
-rw-r--r--. 1 root root      54528 Feb 11 14:18 tokenizer_config.json
```

**Key file:** `model.safetensors` should be ~2.5GB

---

### Step 4: Start vllm-server (GPU Inference)

```bash
sudo podman run -d \
  --name vllm-server \
  --volume model-storage:/models:ro,z \
  --publish 8000:8000 \
  --device nvidia.com/gpu=all \
  --shm-size=2g \
  --env LD_LIBRARY_PATH=/usr/lib64 \
  quay.io/redhat-et/vllm-server:latest \
  vllm serve /models
```

**Critical flags explained:**

1. **`--volume model-storage:/models:ro,z`**
   - Shares model files from model-car container
   - `:ro` = read-only (vLLM doesn't modify models)
   - `:z` = shared SELinux label (matches model-car's volume mount)

2. **`--device nvidia.com/gpu=all`**
   - GPU passthrough via CDI (Container Device Interface)
   - Gives container access to ALL GPUs (use `=0` for specific GPU)
   - Requires CDI configuration at `/etc/cdi/nvidia.yaml`
   - Requires `container_use_devices` SELinux boolean (set in bootc image)

3. **`--shm-size=2g`**
   - Increases shared memory from default 64MB to 2GB
   - **CRITICAL:** vLLM uses shared memory for tensor parallelism
   - Without this: "Bus error (core dumped)" on startup

4. **`--security-opt=label=disable`**
   - Disables SELinux confinement for this container
   - Required for GPU access with CDI unless `container_use_devices` SELinux boolean is set on the host
   - The bootc image (v1.0.9+) sets this boolean, so this flag can be omitted in FlightCtl deployments

5. **`--env LD_LIBRARY_PATH=/usr/lib64`**
   - **CRITICAL WORKAROUND:** vLLM container bundles CUDA 12.4, but host has CUDA 13.1
   - Forces vLLM to use host's CUDA libraries instead of bundled version
   - Without this: "CUDA driver version is insufficient" error (Error 803)

**Note:** No `--security-opt=label=disable` needed. The bootc image sets the `container_use_devices` SELinux boolean, which allows GPU device access while keeping SELinux fully enforced.

**Optional: Runtime Configuration via Environment Variables**

The vLLM server supports runtime configuration through environment variables:

```bash
# Example: Change port and model location
sudo podman run -d \
  --name vllm-server \
  --volume model-storage:/models:ro,z \
  --publish 9000:9000 \
  --device nvidia.com/gpu=all \
  --shm-size=2g \
  --env LD_LIBRARY_PATH=/usr/lib64 \
  --env VLLM_PORT=9000 \
  --env VLLM_HOST=0.0.0.0 \
  --env MODEL_PATH=/models \
  quay.io/redhat-et/vllm-server:latest \
  vllm serve /models --port 9000
```

**Note:** The image entrypoint is unset, so you must pass the full `vllm serve` command. Override flags like `--port`, `--model`, `--served-model-name` directly. Remember to update `--publish` to match if you change the port.

**Monitor startup (takes 60-90 seconds):**

```bash
sudo podman logs -f vllm-server
```

**Expected:** Logs show model loading into GPU memory. Wait for "Application startup complete" message.

**Press Ctrl+C to exit log view.**

**Verify vLLM is running:**

```bash
# Check container status
sudo podman ps | grep vllm-server
```

**Expected:** Container status shows "Up"

**Test the API:**

```bash
# Health check
curl http://localhost:8000/health
```

**Expected:** 200 OK (no body)

```bash
# List available models
curl http://localhost:8000/v1/models
```

**Expected:** JSON response with model "/models" listed

**Test inference:**

```bash
curl http://localhost:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "/models",
    "prompt": "Hello! Who are you?",
    "max_tokens": 50,
    "temperature": 0.7
  }'
```

**Expected:** JSON response with generated text in `choices[0].text`

---

### Step 5: Start openwebui (Chat UI)

```bash
sudo podman run -d \
  --name openwebui \
  --volume openwebui-data:/app/backend/data:Z \
  --network host \
  --env OPENAI_API_BASE_URL=http://localhost:8000/v1 \
  quay.io/redhat-et/openwebui:latest
```

**Critical flags explained:**

1. **`--network host`**
   - **CRITICAL:** Container uses host's network namespace directly
   - OpenWebUI runs on port 8080 (no port mapping needed)
   - Allows OpenWebUI to connect to vLLM on `localhost:8000`
   - **Note:** With `--network host`, port mappings like `-p 3000:8080` are ignored

2. **`--env OPENAI_API_BASE_URL=http://localhost:8000/v1`**
   - Configures OpenWebUI to connect to vLLM API
   - Uses `localhost` because of `--network host`

**Verify OpenWebUI is running:**

```bash
# Check container status
sudo podman ps | grep openwebui
```

**Expected:** Container status shows "Up"

**Test health endpoint:**

```bash
curl http://localhost:8080/health
```

**Expected:** `{"status":true}` (may take 10-20 seconds after container starts)

**Note:** If the health endpoint doesn't respond immediately, wait 10-20 seconds for OpenWebUI to finish starting up, then try again.

---

### Step 6: Access the Web UI

Open your browser to:
```
http://<your-device-ip>:8080
```

Replace `<your-device-ip>` with your device's IP address.

**First-time setup:**

1. **Create admin account**
   - No email verification required
   - Choose a strong password

2. **Navigate to chat interface**
   - Should redirect after account creation

3. **Select model**
   - Model "/models" should appear in dropdown
   - If not visible, click the model selector

4. **Test inference**
   - Send a test message: "Hello! Who are you?"
   - Response should appear in ~2 seconds

5. **Verify GPU is being used**
   - In SSH session, run: `nvidia-smi`
   - Should show GPU memory usage (~2-4GB) and utilization (10-30%)