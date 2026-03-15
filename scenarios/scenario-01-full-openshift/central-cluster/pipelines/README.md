# OpenShift Pipelines

Tekton pipelines for building MLOps container images and responding to model performance alerts.

## Prerequisites

1. **OpenShift Pipelines operator** installed (see OLM manifests below)
2. **Secrets** created in the `mlops-pipelines` namespace (see Setup)

## OLM Manifests

- `namespace.yaml` / `subscription.yaml`: Install OpenShift Pipelines operator

```bash
kubectl apply -k .
```

## Setup

### 1. Create the pipeline namespace and workspace

```bash
oc apply -f pipeline-workspace-pvc.yaml
```

### 2. Create secrets (not stored in Git)

**Quay.io + registry.redhat.io credentials** (combined into one dockerconfigjson):

```bash
# Create a merged auth config with both registries
oc create secret docker-registry registry-credentials \
  --namespace=mlops-pipelines \
  --docker-server=quay.io \
  --docker-username=<QUAY_ROBOT_USER> \
  --docker-password=<QUAY_ROBOT_TOKEN>

# Patch to add registry.redhat.io auth as well
oc create secret docker-registry redhat-registry \
  --namespace=mlops-pipelines \
  --docker-server=registry.redhat.io \
  --docker-username=<RH_USERNAME> \
  --docker-password=<RH_PASSWORD>

# Link both to the pipeline service account
oc secrets link pipeline registry-credentials --namespace=mlops-pipelines
oc secrets link pipeline redhat-registry --namespace=mlops-pipelines
```

**HuggingFace token** (for modelcar build):

```bash
oc create secret generic hf-token \
  --namespace=mlops-pipelines \
  --from-literal=HF_TOKEN=<YOUR_HF_TOKEN>
```

### 3. Apply pipeline resources

```bash
oc apply -f build-and-push-image-task.yaml
oc apply -f build-mlops-containers.yaml
oc apply -f trigger.yaml
```

## Pipeline: build-mlops-containers

Builds all three container images in parallel after cloning the repo:

```
git-clone --> build-modelcar    --> quay.io/redhat-et/modelcar-llama-3.2-1b:<tag>
          --> build-vllm-server --> quay.io/redhat-et/vllm-server:<tag>
          --> build-openwebui   --> quay.io/redhat-et/openwebui:<tag>
```

### Manual trigger

```bash
tkn pipeline start build-mlops-containers \
  --param git-revision=main \
  --param image-tag=v1.0.0 \
  --workspace name=shared-workspace,claimName=pipeline-workspace \
  --workspace name=registry-credentials,secret=registry-credentials \
  --namespace=mlops-pipelines
```

### Webhook trigger

Expose the EventListener and configure a GitHub webhook:

```bash
# Get the EventListener route (created automatically by OpenShift Pipelines)
oc get route -n mlops-pipelines

# Configure GitHub webhook:
#   URL: https://<route>/
#   Content type: application/json
#   Events: Push events
```

## Pipeline: model-refresh (stretch goal)

Alert-triggered pipeline that rebuilds the modelcar when vLLM performance degrades.

```bash
# Apply stretch goal resources
oc apply -f model-refresh-pipeline.yaml
oc apply -f alert-trigger.yaml
oc apply -f prometheus-rules.yaml
```

### Simulate an alert trigger

```bash
curl -X POST http://el-model-refresh.mlops-pipelines.svc:8080 \
  -H "Content-Type: application/json" \
  -d '{
    "alerts": [{
      "status": "firing",
      "labels": {
        "alertname": "VLLMHighLatency",
        "severity": "warning"
      }
    }]
  }'
```

### Prometheus alert rules

Three rules defined in `prometheus-rules.yaml`:
- **VLLMHighLatency**: p95 token latency > 500ms for 10min
- **VLLMHighErrorRate**: error rate > 5% for 5min
- **VLLMHighCacheUsage**: GPU KV cache > 90% for 15min

In production, AlertManager would POST to the `el-model-refresh` EventListener to trigger the pipeline automatically.

## Files

| File | Description |
|------|-------------|
| `namespace.yaml` | openshift-operators namespace |
| `subscription.yaml` | OpenShift Pipelines operator subscription |
| `pipeline-workspace-pvc.yaml` | PVC + namespace for pipeline workspace |
| `build-and-push-image-task.yaml` | Reusable buildah build+push Task |
| `build-mlops-containers.yaml` | Main pipeline: build all 3 images |
| `trigger.yaml` | GitHub webhook EventListener + TriggerTemplate |
| `model-refresh-pipeline.yaml` | Alert-triggered model rebuild pipeline |
| `alert-trigger.yaml` | AlertManager webhook EventListener |
| `prometheus-rules.yaml` | PrometheusRule for vLLM metrics alerts |

