#!/bin/bash

FLEET_NAMESPACE=fleet

kubectl delete secret flightctl-cloud-init -n $FLEET_NAMESPACE
kubectl delete vm -n $FLEET_NAMESPACE --all