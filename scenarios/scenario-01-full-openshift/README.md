# Scenario 1: High Scale Full OpenShift

This scenario implements the "High Scale with mid-large hardware footprint - Option A" architectural pattern, designed for environments with central teams responsible for platform, applications, and AI models.

## Architecture Overview

### Central Hub (Cloud/Datacenter)
- **OpenShift AI**: Model development, training, and model registry
- **OpenShift Pipelines**: CI/CD for model packaging and container builds
- **Red Hat Advanced Cluster Management (ACM)**: Multi-cluster policy enforcement and GitOps management
- **Red Hat Quay**: Container and model registry (OCI artifacts)

### Edge Sites
- **Single Node OpenShift (SNO)**: Lightweight OpenShift clusters deployed as VMs
- **OpenShift GitOps (ArgoCD)**: Automated application deployment
- **KServe**: Model serving platform for deploying and managing AI models at the edge

### Deployment Flow
1. Data scientists develop models in OpenShift AI
2. Models packaged as ModelCar OCI artifacts and stored in Quay
3. KServe InferenceService definitions created referencing models from registry
4. GitOps (ArgoCD) deploys KServe InferenceServices to edge SNO clusters
5. KServe manages model serving, scaling, and versioning at the edge
6. ACM enforces policies and manages multi-cluster operations

## Organizational Pattern Fit

**Best for**: Delegation of Authority model
- Multiple teams can deploy independently
- GitOps enables self-service deployment
- ACM provides policy enforcement and isolation
- Teams push artifacts to production through automated workflows

## Directory Structure

```
scenario-01-full-openshift/
├── README.md                 # This file
├── central-cluster/          # Central hub configurations
│   ├── openshift-ai/        # OpenShift AI configurations
│   ├── pipelines/           # OpenShift Pipelines definitions
│   ├── acm/                 # ACM policies and cluster configs
│   └── kustomization.yaml   # Kustomize base
├── edge-clusters/           # Edge SNO configurations
│   ├── gitops/              # ArgoCD application definitions
│   ├── kserve/              # KServe InferenceService definitions
│   └── kustomization.yaml   # Kustomize overlays per site
└── scripts/                 # Automation scripts
    ├── setup-central.sh     # Setup central cluster components
    ├── deploy-model.sh      # Deploy model to edge clusters
    └── update-model.sh      # Update model version
```

## Prerequisites

- OpenShift cluster (central hub) - assumed to exist or use provided manifests
- OpenShift AI installed and configured
- KServe installed on edge SNO clusters (part of OpenShift AI)
- ACM installed and configured
- OpenShift GitOps (ArgoCD) operator installed
- Quay registry accessible
- VMs for edge SNO clusters (created via tools/vm-setup/)

## Setup Instructions

### 1. Central Cluster Setup

The central cluster is assumed to be deployed in the cloud. This directory contains manifests to configure:
- OpenShift AI model registry access
- OpenShift Pipelines for model packaging
- ACM policies for edge cluster management
- GitOps repositories configuration

```bash
# Apply central cluster configurations
kubectl apply -k central-cluster/
```

### 2. Edge Cluster Provisioning

Create SNO VMs using the provisioning scripts:

```bash
# Create SNO VM
../../tools/vm-setup/create-sno-vm.sh edge-site-01
```

### 3. Register Edge Clusters with ACM

```bash
# Register SNO cluster with ACM
oc apply -f central-cluster/acm/cluster-import.yaml
```

### 4. Configure GitOps for Edge Deployment

```bash
# Create GitOps application for edge cluster
oc apply -f edge-clusters/gitops/edge-site-01-app.yaml
```

### 5. Verify KServe Installation

```bash
# Verify KServe is installed on edge cluster
oc get pods -n knative-serving
oc get pods -n kserve
```

## Testing Workflow

### 1. Develop Model in OpenShift AI
- Use OpenShift AI to train/fine-tune a model
- Export model as ONNX or other format
- Package as ModelCar OCI artifact

### 2. Package Model as ModelCar
```bash
# Package model as OCI artifact
./scripts/package-model.sh model-name:v1.0
```

### 3. Deploy KServe InferenceService to Edge
```bash
# Deploy KServe InferenceService referencing model
./scripts/deploy-model.sh edge-site-01 model-name:v1.0
```

This creates a KServe InferenceService that:
- References the model from the Quay registry
- Configures model serving with appropriate resources
- Exposes the model via HTTP/gRPC endpoints
- Handles model versioning and canary deployments

### 4. Update Model Version
```bash
# Update to new model version without changing app
./scripts/update-model.sh edge-site-01 model-name:v2.0
```

## Key Features

- **KServe model serving**: Industry-standard model serving platform with auto-scaling, canary deployments, and A/B testing
- **GitOps-based deployment**: All deployments managed through Git
- **Multi-cluster management**: ACM provides unified view and policy enforcement
- **Model versioning**: KServe supports model versioning and traffic splitting
- **Policy enforcement**: ACM ensures compliance across all edge clusters
- **Observability**: KServe exposes metrics that flow back to central cluster for monitoring

## Next Steps

- [ ] Create OpenShift AI model development workflow
- [ ] Implement ModelCar packaging pipeline
- [ ] Set up GitOps application definitions
- [ ] Configure ACM policies
- [ ] Deploy observability stack
- [ ] Test model version updates
- [ ] Test application version updates

## Related Scenarios

- **Scenario 2**: For resource-constrained devices without Kubernetes
- **MicroShift variant**: Coming soon for lightweight Kubernetes needs

