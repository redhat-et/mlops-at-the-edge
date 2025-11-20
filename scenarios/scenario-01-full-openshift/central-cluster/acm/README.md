# Advanced Cluster Management (ACM)

This directory contains OLM manifests and ACM configurations for managing edge clusters.

## OLM Manifests

- `namespace.yaml`: Creates the open-cluster-management namespace
- `operatorgroup.yaml`: Defines the OperatorGroup for ACM
- `subscription.yaml`: Subscribes to the Advanced Cluster Management operator

## Installation

Apply the OLM manifests to install ACM:

```bash
# Apply namespace, operatorgroup, and subscription
kubectl apply -k .
```

## Configuration

After installation, configure ACM for:
- Cluster import configurations
- Policy definitions for edge deployments
- Application placement rules
- Multi-cluster observability setup

## Key Policies

- Resource limits for edge clusters
- Security policies (image scanning, pod security)
- Network policies
- Model deployment policies

