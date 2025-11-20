# OpenShift Pipelines

This directory contains OLM manifests and OpenShift Pipelines (Tekton) definitions.

## OLM Manifests

- `namespace.yaml`: Ensures openshift-operators namespace exists
- `operatorgroup.yaml`: Defines the OperatorGroup for OpenShift Pipelines
- `subscription.yaml`: Subscribes to the OpenShift Pipelines operator

## Installation

Apply the OLM manifests to install OpenShift Pipelines:

```bash
# Apply namespace, operatorgroup, and subscription
kubectl apply -k .
```

## Pipeline Definitions

After installation, you can create Tekton pipelines for:
- Model packaging as ModelCar OCI artifacts
- Container image builds
- Model optimization (quantization, pruning)
- Automated testing

Example pipeline files:
- `model-package-pipeline.yaml`: Packages models as OCI artifacts
- `app-build-pipeline.yaml`: Builds application containers with model references
- `model-optimize-pipeline.yaml`: Optimizes models for edge deployment

