# OpenShift AI Configuration

This directory contains OLM manifests and configurations for OpenShift AI in the central cluster.

## OLM Manifests

- `namespace.yaml`: Creates the redhat-ods-operator namespace
- `operatorgroup.yaml`: Defines the OperatorGroup for OpenShift AI
- `subscription.yaml`: Subscribes to the Red Hat OpenShift Data Science (RHOAI) operator

## Components

- Model registry access configuration
- Data science project templates
- Model serving configurations
- Model catalog definitions

## Installation

Apply the OLM manifests to install OpenShift AI:

```bash
# Apply namespace, operatorgroup, and subscription
kubectl apply -k .
```

## Usage

After installation, these manifests configure:
- Access to model registry for edge deployments
- Model export pipelines
- Model versioning policies

