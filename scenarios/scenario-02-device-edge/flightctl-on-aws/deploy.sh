#!/bin/bash

export AWS_REGION=eu-north-1

# Create key pair for accessing the instances
SSH_KEY_NAME=mlops
aws ec2 create-key-pair --key-name $SSH_KEY_NAME --query 'KeyMaterial' --output text > $SSH_KEY_NAME.pem
chmod 400 $SSH_KEY_NAME.pem

INSTANCE_TYPE=t3.xlarge

# Find a suitable subnet in an availability zone that supports instance type
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

# Launch an instance with a fedora image and install Flightctl using user data script
NAME=flightctl-instance
FEDORA_AMI_ID=ami-00591e9b6ab674470

aws ec2 run-instances \
    --image-id $FEDORA_AMI_ID --count 1 \
    --instance-type $INSTANCE_TYPE \
    --key-name $SSH_KEY_NAME \
    --security-group-ids $SG_ID \
    --subnet-id $SUBNET_ID \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3"}}]' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME}}]" \
    --user-data file://init-script.txt
   
# Get instance IP address
FLIGHTCTL_INSTANCE_IP=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${NAME}" "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

echo "Access the instance via the following command: ssh fedora@${FLIGHTCTL_INSTANCE_IP} -i ${SSH_KEY_NAME}.pem -o StrictHostKeyChecking=no"
echo "The Flightctl UI is available at: https://${FLIGHTCTL_INSTANCE_IP}.nip.io"

# Create a Flightctl fleet
flightctl login -k https://${FLIGHTCTL_INSTANCE_IP}.nip.io:3443 -u mlops -p mlops123

while [ $? -ne 0 ]
do
    sleep 30s
    flightctl login -k https://${FLIGHTCTL_INSTANCE_IP}.nip.io:3443 -u mlops -p mlops123
done

AGENT_CONFIG=$(flightctl certificate request --signer=enrollment --expiration=365d --output=embedded)

# AMI id for a custom built RHEL image with the Flightctl agent and Nvidia drivers preinstalled
RHEL_AMI_ID=ami-0b2a92f5e47f01ca2

DEVICES=("flightctl-device-1" "flightctl-device-2")
for device in ${DEVICES[@]}
do
    aws ec2 run-instances \
        --image-id $RHEL_AMI_ID --count 1 \
        --instance-type $INSTANCE_TYPE \
        --key-name $SSH_KEY_NAME \
        --security-group-ids $SG_ID \
        --subnet-id $SUBNET_ID \
        --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":50,"VolumeType":"gp3"}}]' \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${device}}]" \
        --user-data "echo $AGENT_CONFIG > /etc/flightctl/config.yaml"
done

ENROLLMENT_REQUESTS=$(flightctl get enrollmentrequests -o name)
for request in $ENROLLMENT_REQUESTS
do 
    flightctl approve -l project=mlops er/$request
done

flightctl apply -f fleet.yaml