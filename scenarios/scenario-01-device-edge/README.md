# Scenario 2: Central OpenShift cluster and Device Edge

In this scenario the data science team work in a centralised OpenShift AI cluster to create models, which are then distributed and run on devices via FlightCtl.

# Prerequisites

A central OpenShift cluster (configuration scripts provided).

# Workflow

1. Data scientists develop models in OpenShift AI
2. Models packaged as ModelCar OCI artifacts and stored in Quay
3. Model and model runtime instructions specified in a podman compose 
4. Podman compose referenced in the FlightCtl fleet template and all applications are rolled out to all registered devices

# Instructions

Navigate to the AWS or OpenShift folder to experiment with MLOps using device edge. The scripts there contain everything to deploy and configure the chosen environment, create images, provision a device and register it with FlightCtl, and test out the sample MLOps workflows.   