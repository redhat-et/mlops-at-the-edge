#!/bin/bash

INSTANCE_TYPE=g5.2xlarge

# Create key pair for accessing the instance
SSH_KEY=mlops
aws ec2 create-key-pair --key-name $SSH_KEY --query 'KeyMaterial' --output text > mlops.pem
chmod 400 mlops.pem

# Find a Subnet in an Availability Zone that supports G5 hardware
SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=availability-zone,Values=$(aws ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values=$INSTANCE_TYPE --query 'InstanceTypeOfferings[0].Location' --output text)" --query 'Subnets[0].SubnetId' --output text)

# Get the 'default' Security Group for that specific Subnet's VPC
VPC_ID=$(aws ec2 describe-subnets --subnet-ids $SUBNET_ID --query 'Subnets[0].VpcId' --output text)
SG_ID=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC_ID Name=group-name,Values=default --query "SecurityGroups[0].GroupId" --output text)

# Authorize SSH (Port 22) access for your Security Group
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0

# Launch the instance with FlightCtl image
# ami-00175acfe45a0cc9b is a fedora coreos ami so the username is core to log in (contains bootc and podman by default)
# ami-00ffa9d24b0dec790 is a fedora image that must be paid for
# ami-000535c385d690619 free fedora rawhide image (contains podman)
NAME=flightctl-instance
aws ec2 run-instances \
    --image-id ami-000535c385d690619 --count 1 \
    --instance-type $INSTANCE_TYPE \
    --key-name $SSH_KEY \
    --security-group-ids $SG_ID \
    --subnet-id $SUBNET_ID \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3"}}]' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME}}]"
    
# Get instance IP address
INSTANCE_IP=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${NAME}" "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

echo $INSTANCE_IP
exit 0

# ssh in as core and inside the vm run
sudo podman run --rm --privileged -v /dev:/dev -v /var/lib/containers:/var/lib/containers -v /:/target \
             --pid=host --security-opt label=type:unconfined_t \
             quay.io/clwalsh/centos-bootc-flightctl:v1 \
             bootc install to-existing-root --root-ssh-authorized-keys /var/home/core/.ssh/authorized_keys.d/afterburn

sudo reboot

# Remove ec2 from ~/.ssh/known_hosts or dont run with strict host checking (maybe better)