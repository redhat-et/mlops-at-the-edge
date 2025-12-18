#!/bin/bash

# Build bootc container image with flightctl agent
OCI_REGISTRY=quay.io
OCI_IMAGE_REPO=$OCI_REGISTRY/clwalsh/centos-bootc-flightctl
OCI_IMAGE_TAG=v1

sudo podman build -t $OCI_IMAGE_REPO:$OCI_IMAGE_TAG .

# Create qcow2
mkdir -p output
sudo podman run --rm -it --privileged --pull=newer \
    --security-opt label=type:unconfined_t \
    -v "${PWD}/output":/output \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    quay.io/centos-bootc/bootc-image-builder:latest \
    --type qcow2 \
    ${OCI_IMAGE_REPO}:${OCI_IMAGE_TAG}

# Build containerdisk OCI image for KubeVirt
sudo chown -R $(whoami):$(whoami) "${PWD}/output"

OCI_DISK_IMAGE_REPO=${OCI_IMAGE_REPO}/diskimage-qcow2

sudo podman build -t ${OCI_DISK_IMAGE_REPO}:${OCI_IMAGE_TAG} -f Containerfile.qcow2-image .

sudo podman push ${OCI_DISK_IMAGE_REPO}:${OCI_IMAGE_TAG}

# Create K8s secret to use as cloud-init source in KubeVirt VM 
# Secret has flightctl enrollment details for late binding of enrollment endpoint and certificates 
FC_NAMESPACE=flightctl
FC_API_URL="https://"$(kubectl get route flightctl-api-route -n $FC_NAMESPACE -o=jsonpath='{.spec.host}')
FC_PASS=$(kubectl get secret/keycloak-demouser-secret -n $FC_NAMESPACE -o=jsonpath='{.data.password}' | base64 -d)

flightctl login $FC_API_URL -u demouser -p $FC_PASS --insecure-skip-tls-verify
flightctl certificate request --signer=enrollment --expiration=365d --output=embedded > agentconfig.yaml
kubectl create secret generic flightctl-cloudinit --from-file=agentconfig.yaml

# Create VM
# TODO enable GPU passthrough
kubectl apply -f vm.yaml