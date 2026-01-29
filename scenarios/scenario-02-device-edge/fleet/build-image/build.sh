#!/bin/bash

OCI_REGISTRY=$1
USERNAME_OR_ORG=$2
IMAGE_TYPE=$3

if [ -z "$OCI_REGISTRY" ]
then
    echo "Missing name of OCI registry (docker.io, quay.io)"
    exit 1
fi

if [ -z "$USERNAME_OR_ORG" ]
then
    echo "Missing username or organisation for ${OCI_REGISTRY} account"
    exit 1
fi

if [ -z "$IMAGE_TYPE" ]
then 
    echo "Image type to build is not provided, ami or qcow2 are supported"
    exit 1
fi

if [ -d output ]
then 
    echo "Output directory already exists with an image to boot the fleet"
    exit 1
fi

# Build bootc container image with flightctl agent
OCI_REFERENCE=$OCI_REGISTRY/$USERNAME_OR_ORG
FLIGHTCTL_IMAGE_REPO_NAME=centos-bootc-flightctl
OCI_IMAGE_TAG=v1

FLIGHTCTL_IMAGE=$OCI_REFERENCE/$FLIGHTCTL_IMAGE_REPO_NAME:$OCI_IMAGE_TAG
sudo docker build -t $FLIGHTCTL_IMAGE .
if [ $? -ne 0 ]
then 
    echo "Failed to build bootc image with flightctl agent"
    exit 1
fi

sudo docker push $FLIGHTCTL_IMAGE

# Create image
mkdir -p output
sudo podman pull $FLIGHTCTL_IMAGE
sudo podman run --rm -it --privileged --pull=newer \
    --security-opt label=type:unconfined_t \
    -v "${PWD}/config.toml":/config.toml:ro \
    -v "${PWD}/output":/output \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    quay.io/centos-bootc/bootc-image-builder:latest \
    --type $IMAGE_TYPE \
    $FLIGHTCTL_IMAGE

# Build containerdisk OCI image for KubeVirt
if [ "$IMAGE_TYPE" = "qcow2" ]
then

    CONTAINERDISK_IMAGE=$OCI_REFERENCE/diskimage-qcow2:$OCI_IMAGE_TAG

    sudo chown -R $(whoami):$(whoami) "${PWD}/output"
    sudo docker build -t $CONTAINERDISK_IMAGE -f Dockerfile.qcow2-image .
    sudo docker push $CONTAINERDISK_IMAGE
fi