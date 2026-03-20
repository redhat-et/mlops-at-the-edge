#!/bin/bash

export AWS_REGION=$1
if [ -z "$AWS_REGION" ]
then
    echo "Provide the name of the AWS region where the MLOps scenario was deployed to run the clean up script"
    exit 1
fi

aws ec2 delete-key-pair --key-name mlops --region $AWS_REGION
rm -f aws/mlops.pem

EC2_INSTANCE_NAMES=("flightctl-instance" "flightctl-device-1" "flightctl-device-2")

for instance_name in "${EC2_INSTANCE_NAMES[@]}"
do
    INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=${instance_name}" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].InstanceId" --output text) 
    aws ec2 terminate-instances --instance-ids $INSTANCE_ID
    aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID
done

aws ec2 delete-security-group --group-name flightctl-sg --region $AWS_REGION
aws ec2 delete-security-group --group-name mlops-fleet-sg --region $AWS_REGION