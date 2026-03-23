#!/bin/bash

# Get latest release
export RELEASE=$(curl https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt)
# Deploy the KubeVirt operator
kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${RELEASE}/kubevirt-operator.yaml
# Add SCC to allow to run on OpenShift
oc adm policy add-scc-to-user privileged -n kubevirt -z kubevirt-operator
# Create the KubeVirt CR (instance deployment request) which triggers the actual installation
kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${RELEASE}/kubevirt-cr.yaml
# Wait until all KubeVirt components are up
kubectl -n kubevirt wait kv kubevirt --for condition=Available --timeout=180s