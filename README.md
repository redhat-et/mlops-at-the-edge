# About

A comprehensive set of scripts and guides to test MLOps in various scenarios.

## Pipeline Setup Guide

This section covers everything needed to get the CI/CD pipelines running: GitHub Actions for the outer loop and the KFP pipeline on OpenShift AI for the inner loop.

### GitHub Actions Secrets

Configure these in **Settings > Secrets and variables > Actions** on the GitHub repository.

| Secret | Used by | Description |
|--------|---------|-------------|
| `OPENSHIFT_TOKEN` | `trigger-builds`, `model-refresh-build` | OpenShift API token. The workflows use `oc login` to trigger BuildConfigs on the cluster. Get with `oc whoami -t`, or create a service account token in the `mlops-pipelines` namespace. |
| `QUAY_USERNAME` | `update-fleet` | Quay.io username or robot account with push access to the `redhat-et` namespace. Used to push the quadlet OCI image. |
| `QUAY_PASSWORD` | `update-fleet` | Quay.io password or robot token for the above user. |
| `FLIGHTCTL_USER` | `update-fleet` | Username for FlightCtl. Used to `flightctl login` and apply fleet updates. |
| `FLIGHTCTL_PASSWORD` | `update-fleet` | Password for FlightCtl. |

> `GITHUB_TOKEN` is provided automatically by GitHub Actions and does not need to be configured. It is used to commit and push quadlet/fleet tag updates back to the repository.

### OpenShift Secrets (`mlops-pipelines` namespace)

The BuildConfigs that compile container images run on OpenShift and need these secrets. The `builder` service account must be linked to `registry-credentials`, `hf-token`, and `redhat-registry`.

| Secret | Description | How to create |
|--------|-------------|---------------|
| `registry-credentials` | Quay.io push credentials. Used by all three BuildConfigs to push built images to `quay.io/redhat-et`. | `oc create secret docker-registry registry-credentials --docker-server=quay.io --docker-username=<user> --docker-password=<token> -n mlops-pipelines` then `oc secrets link builder registry-credentials -n mlops-pipelines` |
| `hf-token` | Hugging Face API token (key: `HF_TOKEN`). Injected into the modelcar build to download the model (see Hugging Face section below). | `oc create secret generic hf-token --from-literal=HF_TOKEN=hf_YOUR_TOKEN -n mlops-pipelines` then `oc secrets link builder hf-token -n mlops-pipelines` |
| `redhat-registry` | Red Hat registry pull secret. The vLLM server Containerfile uses `registry.redhat.io/rhaiis/vllm-cuda-rhel9:3.0.0` as its base image, which requires authentication. | `oc create secret docker-registry redhat-registry --docker-server=registry.redhat.io --docker-username=<user> --docker-password=<token> -n mlops-pipelines` then `oc secrets link builder redhat-registry --for=pull -n mlops-pipelines` |
| `github-webhook-secret` | Webhook secret referenced by the BuildConfig GitHub triggers. | `oc create secret generic github-webhook-secret --from-literal=WebHookSecretKey=<random-string> -n mlops-pipelines` |

### OpenShift Secrets (`mlops-kfp` namespace)

The KFP inner-loop pipeline uses these secrets to trigger the outer loop via the GitHub Actions API.

| Secret | Description | How to create |
|--------|-------------|---------------|
| `github-pat` | GitHub personal access token (key: `token`). Needs `repo` and `actions:write` scopes on `redhat-et/mlops-at-the-edge`. Used by the `trigger_outer_loop` pipeline step and `trigger-pipeline.sh`. | `oc create secret generic github-pat --from-literal=token=ghp_YOUR_TOKEN -n mlops-kfp` |
| `flightctl-url` | FlightCtl API URL (key: `url`). Passed through to the GitHub Actions `model-refresh-build` workflow as the `flightctl_url` input. | `oc create secret generic flightctl-url --from-literal=url=https://flightctl.example.com:3443 -n mlops-kfp` |

### Hugging Face

The modelcar build downloads `meta-llama/Llama-3.2-1B-Instruct`, which is a gated model. Before the modelcar BuildConfig will succeed, you need to:

1. Create a [Hugging Face](https://huggingface.co) account
2. Accept the Meta Llama license agreement on the [model page](https://huggingface.co/meta-llama/Llama-3.2-1B-Instruct)
3. Create an access token under [Settings > Access Tokens](https://huggingface.co/settings/tokens)
4. Store it in the `hf-token` secret in the `mlops-pipelines` namespace (see above)

### Workflow Inputs

The `model-refresh-build` and `update-fleet` workflows accept a `flightctl_url` input at dispatch time. When triggered by the KFP pipeline, this value comes from the `flightctl-url` secret in `mlops-kfp`. When triggered manually, provide the FlightCtl API URL (e.g. `https://flightctl.example.com:3443`).

### Hardcoded Variables

These values are set directly in the workflow YAML files. Update them if your environment differs:

| Variable | Value | File(s) | Description |
|----------|-------|---------|-------------|
| `QUAY_NAMESPACE` | `redhat-et` | All workflows | Quay.io namespace for container images. |
| `OPENSHIFT_SERVER` | `https://api.ocp-beta-test.nerc.mghpcc.org:6443` | `trigger-builds.yaml`, `model-refresh-build.yaml` | OpenShift API server URL. |

### Workflow Summary

| Workflow | Trigger | What it does |
|----------|---------|--------------|
| **Build Containers and Deploy to Fleet** (`trigger-builds.yaml`) | Push to `main` changing `scenarios/containers/**` | Builds changed container images via OpenShift BuildConfigs, updates quadlet files and fleet.yaml with new SHA tags, pushes the quadlet OCI image to Quay. |
| **Model Refresh Build** (`model-refresh-build.yaml`) | `workflow_dispatch` (manual or from KFP pipeline) | Rebuilds the modelcar image with a given version tag, then calls Update Fleet. Requires `flightctl_url` input. |
| **Update Fleet** (`update-fleet.yaml`) | `workflow_call` or `workflow_dispatch` | Updates quadlet image tags, builds and pushes the quadlet OCI image, commits tag changes, and applies the fleet.yaml to FlightCtl. |
