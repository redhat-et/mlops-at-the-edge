# Overview

This folder contains scripts to mimic the architectural pattern where FlightCtl is deployed outside the central cluster on a regional cluster or server.

# Prerequisites

A central OpenShift cluster with the OpenShift AI and OpenShift pipelines operators installed.

# Instructions

Run the ```deploy.sh``` script to bring up an EC2 instance with FlightCtl and 2 additional EC2 instances that register with the FlightCtl instance and form a fleet. When finished experimenting run the ```clean-up.sh``` script to tear down the infrastructure. 