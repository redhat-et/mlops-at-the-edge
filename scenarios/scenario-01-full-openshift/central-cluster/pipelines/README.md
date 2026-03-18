# CI/CD Pipelines for MLOps Container Builds

Automated build and deployment pipeline for the three MLOps container images (modelcar, vllm-server, openwebui). A push to `main` that modifies container source files triggers the full chain: build, push to Quay, update quadlet definitions, update fleet manifest.

## Architecture

```
Push to main (scenarios/containers/**)
         │
         ▼
GitHub Actions: detect-changes
  ├── Which containers changed? (paths-filter)
  └── Get commit SHA for image tagging
         │
         ▼
GitHub Actions → OpenShift (parallel builds)
  ├── build-modelcar     ──► quay.io/redhat-et/modelcar-llama-3.2-1b:<sha>
  ├── build-vllm-server  ──► quay.io/redhat-et/vllm-server:<sha>
  └── build-openwebui    ──► quay.io/redhat-et/openwebui:<sha>
         │
         ▼ (only runs if at least one build succeeded)
GitHub Actions: deploy-to-fleet
  ├── Update Image= tags in quadlet .container files
  ├── Build mlops-quadlet OCI image ──► quay.io/redhat-et/mlops-quadlet:<sha>
  ├── Update fleet.yaml with new quadlet image tag
  └── Commit and push changes back to repo
         │
         ▼
FlightCtl picks up fleet.yaml change → rolls out to edge devices
```

Only changed containers are built. Unchanged containers are skipped.

## How It Works

### Pipeline 1: Container Builds (OpenShift BuildConfigs)

Each container image has a corresponding BuildConfig on the OpenShift cluster (`mlops-pipelines` namespace). The GitHub Actions workflow:

1. Patches the BuildConfig output tag to the commit SHA
2. Starts the build with `oc start-build`
3. OpenShift clones the repo, builds the Dockerfile/Containerfile, pushes to Quay

The BuildConfigs use Git source, so they can also be triggered independently.

### Pipeline 2: Deploy to Fleet

After builds complete, the workflow:

1. Updates `Image=` lines in the quadlet `.container` files with the new SHA tags
2. Builds a scratch OCI image containing all quadlet files
3. Pushes the quadlet OCI image to Quay
4. Updates `fleet.yaml` to reference the new quadlet image
5. Commits and pushes changes back to the repo

FlightCtl watches the fleet manifest and automatically rolls out changes to enrolled devices.

## Files

| File | Purpose |
|------|---------|
| `.github/workflows/trigger-builds.yaml` | GitHub Actions workflow (full pipeline) |
| `buildconfigs.yaml` | OpenShift BuildConfig definitions (3 images) |
| `build-and-push-image-task.yaml` | Tekton Task: wraps `oc start-build` |
| `build-mlops-containers.yaml` | Tekton Pipeline: orchestrates all 3 builds |
| `git-clone-task.yaml` | Tekton Task: clones git repo into workspace |
| `pipeline-workspace-pvc.yaml` | Namespace and PVC for Tekton pipeline |
| `kustomization.yaml` | Kustomize resource list |
| `trigger.yaml` | Tekton Triggers (requires Triggers CRDs) |
| `alert-trigger.yaml` | AlertManager webhook EventListener (stretch) |
| `model-refresh-pipeline.yaml` | Alert-triggered model refresh (stretch) |
| `prometheus-rules.yaml` | PrometheusRules for vLLM metrics (stretch) |

## Prerequisites

### OpenShift Cluster

The following must exist in the `mlops-pipelines` namespace:

**Secrets:**
- `hf-token` — HuggingFace API token (key: `HF_TOKEN`). Required for modelcar build (gated model).
- `registry-credentials` — Quay.io robot account credentials (`kubernetes.io/dockerconfigjson`). Used by BuildConfigs to push images.
- `redhat-registry` — Red Hat registry service account (`kubernetes.io/dockerconfigjson`). Used by vllm-server BuildConfig to pull from `registry.redhat.io`.

**Service Accounts:**
- `pipeline` — has `edit` role, secrets linked for builds
- `builder` — has `redhat-registry` linked for pull and mount
- `build-trigger` — minimal permissions for GitHub Actions (patch BuildConfigs, start builds, watch build status)

**Create secrets:**
```bash
# HuggingFace token
oc create secret generic hf-token --from-literal=HF_TOKEN=<your-token> -n mlops-pipelines

# Quay robot account
oc create secret generic registry-credentials \
  --from-file=.dockerconfigjson=<path-to-auth.json> \
  --type=kubernetes.io/dockerconfigjson -n mlops-pipelines

# Red Hat registry
oc create secret generic redhat-registry \
  --from-file=.dockerconfigjson=<path-to-auth.json> \
  --type=kubernetes.io/dockerconfigjson -n mlops-pipelines

# Link secrets
oc secrets link pipeline registry-credentials --for=pull,mount -n mlops-pipelines
oc secrets link builder redhat-registry --for=pull,mount -n mlops-pipelines
```

### GitHub Repository Secrets

| Secret | Value |
|--------|-------|
| `OPENSHIFT_TOKEN` | Token for `build-trigger` SA (minimal permissions) |
| `QUAY_USERNAME` | Quay robot account username |
| `QUAY_PASSWORD` | Quay robot account password |

Generate the OpenShift token:
```bash
oc create token build-trigger -n mlops-pipelines --duration=8760h
```

### Apply Pipeline Resources

```bash
oc apply -k scenarios/scenario-01-full-openshift/central-cluster/pipelines/
```

## Manual Pipeline Run (Tekton)

The Tekton pipeline can be run independently of GitHub Actions:

```bash
tkn pipeline start build-mlops-containers \
  --serviceaccount=pipeline \
  --workspace name=shared-workspace,claimName=pipeline-workspace \
  --use-param-defaults \
  --showlog
```

Or from the OpenShift console: Pipelines → build-mlops-containers → Start.

## Security

- **build-trigger SA** has minimal RBAC: can only `get`/`patch` BuildConfigs, `create` build instantiations, and `get`/`list`/`watch` builds. Cannot access secrets, pods, or any other resources.
- **Secrets** are stored as GitHub encrypted secrets, masked in logs.
- **Quay credentials** use a robot account scoped to the `redhat-et` org.
- **No cluster-admin access** is required for any part of the pipeline.

## Container Images

| Image | Source | Base |
|-------|--------|------|
| `quay.io/redhat-et/modelcar-llama-3.2-1b` | `scenarios/containers/modelcar/Containerfile` | UBI9 Micro (runtime) |
| `quay.io/redhat-et/vllm-server` | `scenarios/containers/vllm-server/Dockerfile` | `registry.redhat.io/rhaiis/vllm-cuda-rhel9:3.0.0` |
| `quay.io/redhat-et/openwebui` | `scenarios/containers/openwebui/Dockerfile` | `ghcr.io/open-webui/open-webui:main` |
| `quay.io/redhat-et/mlops-quadlet` | `scenarios/quadlet/containerfiles/Containerfile.quadlet` | scratch |

## Stretch Goal: Alert-Triggered Model Refresh

PrometheusRules monitor vLLM metrics on edge devices. When alerts fire (high latency, error rate, cache pressure), an AlertManager webhook can trigger a model refresh pipeline that rebuilds the modelcar with an updated model version.

**Alert rules** (defined in `prometheus-rules.yaml`):
- **VLLMHighLatency**: p95 token latency > 500ms for 10min
- **VLLMHighErrorRate**: error rate > 5% for 5min
- **VLLMHighCacheUsage**: GPU KV cache > 90% for 15min

This requires Tekton Triggers CRDs, which are not currently available on the shared cluster (Pipelines operator upgrade is stuck). The resources are ready to apply when Triggers become available.
