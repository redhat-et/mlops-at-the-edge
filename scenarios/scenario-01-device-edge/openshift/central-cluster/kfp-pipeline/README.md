# KFP Inner Loop Pipeline

Kubeflow Pipelines (KFP) pipeline that closes the MLOps feedback loop. When edge device metrics indicate model degradation, this pipeline simulates retraining and triggers the outer loop to rebuild and redeploy.

## Full Feedback Loop

```
Edge devices (vLLM metrics via OTel)
        |
        v
  [manual trigger for demo]
        |
        v
KFP Pipeline (RHOAI - this directory)
  1. log_alert         - record what triggered the run
  2. simulate_retraining - fake training loop (5 epochs, ~25s)
  3. register_model    - mock registration with version tag
  4. trigger_outer_loop - POST to GitHub Actions workflow_dispatch
        |
        v
GitHub Actions (model-refresh-build.yaml)
  1. Rebuild modelcar on OpenShift with new version tag
  2. Update quadlet .container files
  3. Build + push quadlet OCI image
  4. Update fleet.yaml
  5. Commit and push
        |
        v
FlightCtl rolls out to edge devices
```

## Files

| File | Purpose |
|------|---------|
| `pipeline.py` | KFP v2 pipeline definition (Python) |
| `pipeline.yaml` | Compiled pipeline (upload to RHOAI) |
| `dspa.yaml` | DataSciencePipelinesApplication CR + namespace |
| `trigger-pipeline.sh` | Script to create a pipeline run from CLI |

## Prerequisites

1. **RHOAI operator** installed on the OpenShift cluster
2. **oc** CLI logged in to the cluster
3. **GitHub PAT** with `repo` and `actions:write` scopes

## Setup

### 1. Deploy the Data Science Pipelines Application

```bash
oc apply -f dspa.yaml
```

Wait for pods to be ready:

```bash
oc get pods -n mlops-kfp -w
```

You should see `ds-pipeline-dspa-*`, `mariadb-dspa-*`, and `minio-dspa-*` pods running.

### 2. Upload the Pipeline

Option A - RHOAI Dashboard:
- Navigate to Data Science Pipelines > Import Pipeline
- Upload `pipeline.yaml`

Option B - CLI:
```bash
DSPA_ROUTE=$(oc get route -n mlops-kfp -l app=ds-pipeline-dspa -o jsonpath='{.items[0].spec.host}')
kfp pipeline upload -p mlops-inner-loop pipeline.yaml --endpoint "https://${DSPA_ROUTE}"
```

### 3. Create GitHub PAT Secret

```bash
oc create secret generic github-pat \
  --from-literal=token=ghp_YOUR_TOKEN_HERE \
  -n mlops-kfp
```

The PAT needs `repo` and `actions:write` permissions on `redhat-et/mlops-at-the-edge`.

## Running the Pipeline

### Option A: RHOAI Dashboard (recommended for demos)

1. Open RHOAI Dashboard > Data Science Pipelines > mlops-inner-loop
2. Create Run
3. Fill in parameters:
   - `alert_name`: `VLLMHighLatency` (or any descriptive name)
   - `severity`: `warning` or `critical`
   - `device_id`: `edge-001` (or the actual device name)
   - `github_token`: paste your GitHub PAT
4. Start

### Option B: CLI Script

```bash
chmod +x trigger-pipeline.sh
./trigger-pipeline.sh VLLMHighLatency warning edge-001
```

The script reads the GitHub PAT from the `github-pat` secret automatically.

## Pipeline Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `alert_name` | `VLLMHighLatency` | Name of the alert that triggered the run |
| `severity` | `warning` | Alert severity level |
| `device_id` | `unknown` | Edge device identifier |
| `github_token` | (empty) | GitHub PAT for triggering the outer loop |

## What Each Step Does

### 1. log_alert
Logs the alert context (name, severity, device ID). Passes context to the next step.

### 2. simulate_retraining
Runs a fake training loop: 5 epochs, 5 seconds each, with decreasing loss and increasing accuracy. Generates a version tag like `v1.0.20260318` based on the current date.

### 3. register_model
Prints a mock model registration log (name, version, artifact URI). In a real pipeline, this would call the Model Registry API.

### 4. trigger_outer_loop
POSTs to the GitHub Actions API to trigger the `model-refresh-build.yaml` workflow with the generated model version. This kicks off the outer loop: rebuild modelcar, update quadlets, update fleet.yaml, push to edge.

## Recompiling the Pipeline

If you modify `pipeline.py`:

```bash
pip install kfp
python3 pipeline.py
# Produces pipeline.yaml
```

## Cluster Requirements

- KFP pods need outbound HTTPS to `api.github.com`
- DSPA requires PVCs (check available StorageClasses)
- The `mlops-kfp` namespace needs the `opendatahub.io/dashboard: 'true'` label to show as a Data Science Project
