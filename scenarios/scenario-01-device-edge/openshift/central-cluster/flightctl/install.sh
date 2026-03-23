#!/bin/bash

# Ensure that the flightctl CLI is installed and that the client and server versions match
FC_VERSION=1.0.1
HELM_RELEASE_NAME=flightctl
HELM_RELEASE_NAMESPACE=flightctl
helm upgrade --install --version=$FC_VERSION --namespace $HELM_RELEASE_NAMESPACE --create-namespace $HELM_RELEASE_NAME oci://quay.io/flightctl/charts/flightctl

# Create fleet namespace and register it as a flightctl organisation
FLEET_NAMESPACE=fleet
kubectl create namespace $FLEET_NAMESPACE
kubectl label namespace $FLEET_NAMESPACE io.flightctl/instance=$HELM_RELEASE_NAME

# Add permissions to user to access the organisation
USER=$(oc whoami)
oc adm policy add-role-to-user view $USER -n $FLEET_NAMESPACE
oc adm policy add-role-to-user flightctl-admin-$HELM_RELEASE_NAMESPACE $USER -n $FLEET_NAMESPACE