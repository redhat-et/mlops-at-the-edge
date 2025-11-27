#!/bin/bash

FC_VERSION=0.10.0
FC_NAMESPACE=flightctl
helm upgrade --install --version=$FC_VERSION --namespace $FC_NAMESPACE --create-namespace flightctl oci://quay.io/flightctl/charts/flightctl