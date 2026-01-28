#!/bin/bash

export FLIGHTCTL_CONTAINERDISK_IMAGE=$1
if [ -z "$FLIGHTCTL_CONTAINERDISK_IMAGE" ]
then
    echo "Missing location of containerdisk image with flightctl agent"
    exit 1
fi

FC_NAMESPACE=flightctl
FC_API_URL="https://"$(kubectl get route flightctl-api-route -n $FC_NAMESPACE -o=jsonpath='{.spec.host}')

# Create K8s secret to use as cloud-init source in KubeVirt VM 
# Secret has flightctl enrollment details for late binding of enrollment endpoint and certificates 
flightctl login $FC_API_URL -k --token=$(oc whoami -t)
export ENCODED_AGENTCONFIG=$(flightctl certificate request --signer=enrollment --expiration=365d --output=embedded | base64 -w0) 
envsubst < cloud-init.template > cloud-init

export FLEET_NAMESPACE=fleet
kubectl create secret generic flightctl-cloud-init --from-file=userdata=cloud-init -n $FLEET_NAMESPACE
envsubst < flightctrl-device-virtualmachineinstancetype.yaml | kubectl apply -f -

# Create devices
DEVICES=("flightctl-device-1" "flightctl-device-2")
for device in ${DEVICES[@]}
do
    export DEVICE_NAME=$device
    # TODO enable GPU passthrough
    envsubst < vm.yaml | kubectl apply -f -
    kubectl wait vm $device --for condition=Ready -n $FLEET_NAMESPACE --timeout=180s
done

# Wait for the vm to boot and for the flightctl agent to issue an enrollment request
sleep 1m

# Establish fleet
ENROLLMENT_REQUESTS=$(flightctl get enrollmentrequests -o name)
for request in $ENROLLMENT_REQUESTS
do 
    flightctl approve -l project=mlops er/$request
done

flightctl apply -f fleet.yaml