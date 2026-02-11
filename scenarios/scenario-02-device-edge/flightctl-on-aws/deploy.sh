#!/bin/bash

INSTANCE_TYPE=g5.2xlarge

# Create key pair for accessing the instance
SSH_KEY_NAME=flightctl-instance
aws ec2 create-key-pair --key-name $SSH_KEY_NAME --query 'KeyMaterial' --output text > $SSH_KEY_NAME.pem
chmod 400 $SSH_KEY_NAME.pem

# Find a Subnet in an Availability Zone that supports G5 hardware
SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=availability-zone,Values=$(aws ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values=$INSTANCE_TYPE --query 'InstanceTypeOfferings[0].Location' --output text)" --query 'Subnets[0].SubnetId' --output text)

# Get the 'default' Security Group for that specific Subnet's VPC
VPC_ID=$(aws ec2 describe-subnets --subnet-ids $SUBNET_ID --query 'Subnets[0].VpcId' --output text)
SG_ID=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC_ID Name=group-name,Values=default --query "SecurityGroups[0].GroupId" --output text)

# Enable SSH access
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0 2>/dev/null || true
# Allow access to Flightctl API
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 3443 --cidr 0.0.0.0/0 2>/dev/null || true
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 7443 --cidr 0.0.0.0/0 2>/dev/null || true
# Open access to Flightctl PAM Issuer endpoint for authentication
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 8444 --cidr 0.0.0.0/0 2>/dev/null || true
# Expose Flightctl UI
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 4443 --cidr 0.0.0.0/0 2>/dev/null || true

# Launch the instance with fedora image
NAME=flightctl-instance
AMI_ID=ami-00129a512f37e8fc6

aws ec2 run-instances \
    --image-id $AMI_ID --count 1 \
    --instance-type $INSTANCE_TYPE \
    --key-name $SSH_KEY_NAME \
    --security-group-ids $SG_ID \
    --subnet-id $SUBNET_ID \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3"}}]' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME}}]" \
    --user-data file://init-script.txt
   
# Get instance IP address
INSTANCE_IP=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${NAME}" "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

echo "Access the instance via the following command: ssh fedora@${INSTANCE_IP} -i ${SSH_KEY_NAME}.pem -o StrictHostKeyChecking=no"
echo "The Flightctl UI is available at: https://${INSTANCE_IP}.nip.io"