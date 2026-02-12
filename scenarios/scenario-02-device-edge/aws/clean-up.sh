#!/bin/bash

export AWS_REGION=eu-north-1

aws ec2 delete-key-pair --key-name mlops
sudo rm mlops.pem

aws ec2 delete-security-group --group-name flightctl-sg

EC2_INSTANCE_NAMES=("flightctl-instance""flightctl-device-1" "flightctl-device-2")

for instance_name in "${EC2_INSTANCE_NAMES[@]}"
do
    aws ec2 terminate-instances --instance-ids $(aws ec2 describe-instances --filters "Name=tag:Name,Values=${instance_name}" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].InstanceId" --output text)
done