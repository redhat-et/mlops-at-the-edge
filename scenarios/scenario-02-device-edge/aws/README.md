# Overview

This folder contains scripts to mimic the architectural pattern where FlightCtl is deployed outside the central cluster on a regional cluster or server.

# Prerequisites

A central OpenShift cluster with the OpenShift AI and OpenShift pipelines operators installed. Before running the script authenticate to AWS via the command ```aws login```.

# Instructions

From the ```scenario-02-device-edge``` directory run the deploy script, ```./aws/deploy.sh``` to bring up an EC2 instance with FlightCtl plus an additional two EC2 instances that register with the FlightCtl instance and form a fleet. The MLOps scenario is rolled out across the fleet. Once the script is completed follow the links generated to explore the FlightCtl UI, Grafana dashboards and model chat UI. When finished experimenting run the ```./aws/clean-up.sh``` script to tear down the infrastructure. 