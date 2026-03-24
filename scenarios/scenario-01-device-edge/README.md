# Scenario 1: Central OpenShift cluster and Device Edge

In this scenario the data science team work in a centralised OpenShift AI cluster to create models, which are then packaged as a ModelCar OCI artifact, to be distributed and run on devices via FlightCtl.

# Prerequisites

A central OpenShift cluster (Configuration provided in ```central-cluster``` )

# Workflow

1. **Device enrollment:**
   - Boot device with bootc image
   - FlightCtl agent auto-enrolls device on first boot
   - Device appears in FlightCtl control plane

2. **Fleet assignment:**
   - Device is assigned to Fleet (e.g. `mlops`)
   - Fleet spec defines desired state (OS version, applications)

3. **Application deployment:**
   - Fleet spec references quadlet OCI artifact
   - FlightCtl agent pulls quadlet
   - FlightCtl Agent starts the quadlets (systemd managed containers)
   - Inference stack runs on each device in the fleet

4. **Trigger MLOps Loop:**
   - Configure Kubeflow Pipelines as per ```central-cluster/kfp-pipeline``` to trigger the MLOps cycle

# Instructions

Navigate to the AWS or OpenShift folder to experiment with MLOps using device edge. The scripts there contain everything to deploy and configure the chosen environment, create images, provision a device and register it with FlightCtl, and test out the sample MLOps workflows.   