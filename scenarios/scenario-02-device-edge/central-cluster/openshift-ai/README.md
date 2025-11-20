# OpenShift AI Configuration

This directory contains OLM manifests and configurations for OpenShift AI in the central cluster.

## OLM Manifests

- `namespace.yaml`: Creates the redhat-ods-operator namespace
- `operatorgroup.yaml`: Defines the OperatorGroup for OpenShift AI
- `subscription.yaml`: Subscribes to the Red Hat OpenShift Data Science (RHOAI) operator

## Installation

Apply the OLM manifests to install OpenShift AI:

```bash
# Apply namespace, operatorgroup, and subscription
kubectl apply -k .
```

## Components

- Model registry access configuration
- Model export for FlightCtl integration
- Model catalog synchronization with FlightCtl

## Integration with FlightCtl

Models developed in OpenShift AI need to be accessible to FlightCtl for deployment to edge devices. This may involve:
- Registry mirroring
- Catalog synchronization
- Model format conversion

