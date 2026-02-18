#!/bin/bash

export AWS_REGION=eu-north-1

echo "Starting cleanup of FlightCtl deployment..."
echo ""

# Delete SSH key pair (shwalsh- prefix)
echo "Deleting SSH key pair..."
aws ec2 delete-key-pair --key-name shwalsh-mlops --region $AWS_REGION
rm -f shwalsh-mlops.pem

# Terminate all instances (shwalsh- prefix)
EC2_INSTANCE_NAMES=("shwalsh-flightctl-instance" "shwalsh-flightctl-device-1" "shwalsh-flightctl-device-2")
INSTANCE_IDS=()

echo "Terminating EC2 instances..."
for instance_name in "${EC2_INSTANCE_NAMES[@]}"
do
    INSTANCE_ID=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=${instance_name}" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
        --query "Reservations[0].Instances[0].InstanceId" \
        --output text \
        --region $AWS_REGION)

    if [ "$INSTANCE_ID" != "None" ] && [ -n "$INSTANCE_ID" ]; then
        echo "  - Terminating ${instance_name} (${INSTANCE_ID})"
        aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $AWS_REGION > /dev/null
        INSTANCE_IDS+=($INSTANCE_ID)
    else
        echo "  - ${instance_name} not found or already terminated"
    fi
done

# Wait for instances to fully terminate before deleting security groups
if [ ${#INSTANCE_IDS[@]} -gt 0 ]; then
    echo ""
    echo "Waiting for instances to terminate..."
    aws ec2 wait instance-terminated --instance-ids ${INSTANCE_IDS[@]} --region $AWS_REGION
    echo "✓ All instances terminated"
fi

# Shaun- Delete both security groups (FlightCtl control plane + MLOps fleet devices) with shwalsh- prefix
echo ""
echo "Deleting security groups..."
aws ec2 delete-security-group --group-name shwalsh-mlops-fleet-sg --region $AWS_REGION 2>/dev/null && echo "  - Deleted shwalsh-mlops-fleet-sg" || echo "  - shwalsh-mlops-fleet-sg not found"
aws ec2 delete-security-group --group-name shwalsh-flightctl-sg --region $AWS_REGION 2>/dev/null && echo "  - Deleted shwalsh-flightctl-sg" || echo "  - shwalsh-flightctl-sg not found"

echo ""
echo "Cleanup complete!"