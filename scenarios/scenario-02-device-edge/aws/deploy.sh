#!/bin/bash

export AWS_REGION=eu-north-1

# Create key pair for accessing the instances (shwalsh- prefix to avoid conflicts)
SSH_KEY_NAME=shwalsh-mlops
aws ec2 create-key-pair --key-name $SSH_KEY_NAME --query 'KeyMaterial' --output text > $SSH_KEY_NAME.pem
chmod 400 $SSH_KEY_NAME.pem

INSTANCE_TYPE=t3.xlarge

# Find a suitable subnet in an availability zone that supports instance type
SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=availability-zone,Values=$(aws ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values=$INSTANCE_TYPE --query 'InstanceTypeOfferings[0].Location' --output text)" --query 'Subnets[0].SubnetId' --output text)

# Get VPC ID for the subnet
VPC_ID=$(aws ec2 describe-subnets --subnet-ids $SUBNET_ID --query 'Subnets[0].VpcId' --output text)

# Create a security group for the flightctl instance (shwalsh- prefix)
SG_NAME=shwalsh-flightctl-sg
aws ec2 create-security-group --group-name $SG_NAME --description "Security group for shwalsh Flightctl instance" --vpc-id $VPC_ID
SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values=$SG_NAME --query "SecurityGroups[0].GroupId" --output text)

# Enable SSH access
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0 2>/dev/null || true
# Allow access to Flightctl API
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 3443 --cidr 0.0.0.0/0 2>/dev/null || true
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 7443 --cidr 0.0.0.0/0 2>/dev/null || true
# Open access to Flightctl PAM Issuer endpoint for authentication
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 8444 --cidr 0.0.0.0/0 2>/dev/null || true
# Expose Flightctl UI
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 443 --cidr 0.0.0.0/0 2>/dev/null || true

# Shaun- Create separate security group for MLOps fleet devices (vLLM + OpenWebUI) with shwalsh- prefix
FLEET_SG_NAME=shwalsh-mlops-fleet-sg
aws ec2 create-security-group --group-name $FLEET_SG_NAME --description "Security group for shwalsh MLOps fleet devices running vLLM and OpenWebUI" --vpc-id $VPC_ID
FLEET_SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values=$FLEET_SG_NAME --query "SecurityGroups[0].GroupId" --output text)

# Shaun- Fleet security group rules: SSH access + MLOps container ports
aws ec2 authorize-security-group-ingress --group-id $FLEET_SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0 2>/dev/null || true    # SSH
aws ec2 authorize-security-group-ingress --group-id $FLEET_SG_ID --protocol tcp --port 8000 --cidr 0.0.0.0/0 2>/dev/null || true  # vLLM API
aws ec2 authorize-security-group-ingress --group-id $FLEET_SG_ID --protocol tcp --port 8080 --cidr 0.0.0.0/0 2>/dev/null || true  # OpenWebUI

# Launch an instance with a fedora image and install Flightctl using user data script (shwalsh- prefix)
NAME=shwalsh-flightctl-instance
FEDORA_AMI_ID=ami-00591e9b6ab674470

# Shaun- Capture instance ID from run-instances command to ensure we get it before querying for IP
FLIGHTCTL_INSTANCE_ID=$(aws ec2 run-instances \
    --image-id $FEDORA_AMI_ID --count 1 \
    --instance-type $INSTANCE_TYPE \
    --key-name $SSH_KEY_NAME \
    --security-group-ids $SG_ID \
    --subnet-id $SUBNET_ID \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3"}}]' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME}}]" \
    --user-data file://init-script.txt \
    --query 'Instances[0].InstanceId' --output text)

# Shaun- Wait for instance to be running before fetching IP to avoid getting empty/None IP
echo "Waiting for FlightCtl instance ${FLIGHTCTL_INSTANCE_ID} to be running..."
aws ec2 wait instance-running --instance-ids $FLIGHTCTL_INSTANCE_ID --region $AWS_REGION

# Get instance IP address
FLIGHTCTL_INSTANCE_IP=$(aws ec2 describe-instances \
    --instance-ids $FLIGHTCTL_INSTANCE_ID \
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

echo "FlightCtl instance IP: ${FLIGHTCTL_INSTANCE_IP}"

# Create a Flightctl fleet
# Shaun- Added quotes around FlightCtl URL to prevent shell parsing issues
echo "Attempting to login to FlightCtl at: https://${FLIGHTCTL_INSTANCE_IP}.nip.io:3443"
flightctl login -k "https://${FLIGHTCTL_INSTANCE_IP}.nip.io:3443" -u mlops -p mlops123

while [ $? -ne 0 ]
do
    echo "Login failed, retrying in 30 seconds..."
    sleep 30s
    flightctl login -k "https://${FLIGHTCTL_INSTANCE_IP}.nip.io:3443" -u mlops -p mlops123
done

echo "Successfully logged into FlightCtl"

AGENT_CONFIG=$(flightctl certificate request --signer=enrollment --expiration=365d --output=embedded)

# Shaun- Updated to use custom bootc AMI (mlops-bootc-rhel10-nvidia v1.0.8) with FlightCtl agent, NVIDIA drivers 590+, and CUDA 13.1
# AMI id for a custom built RHEL image with the Flightctl agent and Nvidia drivers preinstalled
RHEL_AMI_ID=ami-03801f728fb544522
# Shaun- Changed from t3.xlarge to g5.xlarge for GPU support (NVIDIA A10G 24GB)
GPU_INSTANCE_TYPE=g5.xlarge

# Shaun- Find GPU-compatible subnet (g5.xlarge only available in eu-north-1b, eu-north-1c)
GPU_SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=availability-zone,Values=$(aws ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values=$GPU_INSTANCE_TYPE --region $AWS_REGION --query 'InstanceTypeOfferings[0].Location' --output text)" --query 'Subnets[0].SubnetId' --output text)

echo "Launching fleet devices with AMI: ${RHEL_AMI_ID} and instance type: ${GPU_INSTANCE_TYPE}"
echo "Using GPU-compatible subnet: ${GPU_SUBNET_ID}"

DEVICES=("shwalsh-flightctl-device-1" "shwalsh-flightctl-device-2")
for device in ${DEVICES[@]}
do
    # Shaun- user-data injection: Changed from  echo to  cloud-init script with heredoc
    # This ensures FlightCtl enrollment config is written to /etc/flightctl/config.yaml and agent restarts
    # Create user-data script for this device
    cat > /tmp/fleet-user-data.txt <<EOF
#!/bin/bash
cat > /etc/flightctl/config.yaml <<'CONFIGEOF'
${AGENT_CONFIG}
CONFIGEOF
systemctl restart flightctl-agent.service
EOF

    # Shaun- Fleet devices use shwalsh-mlops-fleet-sg and GPU-compatible subnet
    aws ec2 run-instances \
        --image-id $RHEL_AMI_ID --count 1 \
        --instance-type $GPU_INSTANCE_TYPE \
        --key-name $SSH_KEY_NAME \
        --security-group-ids $FLEET_SG_ID \
        --subnet-id $GPU_SUBNET_ID \
        --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":50,"VolumeType":"gp3"}}]' \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${device}}]" \
        --user-data file:///tmp/fleet-user-data.txt
    echo "Launched ${device}"
done

rm -f /tmp/fleet-user-data.txt

# Shaun- Wait for devices to boot and send enrollment requests (typically 2-3 minutes)
echo ""
echo "Waiting for devices to boot and send enrollment requests..."
echo "This may take 2-3 minutes..."
EXPECTED_DEVICES=2
RETRY_COUNT=0
MAX_RETRIES=30  # 30 retries * 10 seconds = 5 minutes max

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    ENROLLMENT_COUNT=$(flightctl get enrollmentrequests -o name 2>/dev/null | wc -l)
    echo "  - Found ${ENROLLMENT_COUNT}/${EXPECTED_DEVICES} enrollment requests (attempt $((RETRY_COUNT+1))/${MAX_RETRIES})"

    if [ "$ENROLLMENT_COUNT" -ge "$EXPECTED_DEVICES" ]; then
        echo "✓ All enrollment requests received!"
        break
    fi

    sleep 10
    RETRY_COUNT=$((RETRY_COUNT+1))
done

if [ "$ENROLLMENT_COUNT" -lt "$EXPECTED_DEVICES" ]; then
    echo "⚠ Warning: Only found ${ENROLLMENT_COUNT}/${EXPECTED_DEVICES} enrollment requests after 5 minutes"
    echo "Proceeding with available requests..."
fi

# Approve all enrollment requests with project=mlops label
echo ""
echo "Approving enrollment requests..."
ENROLLMENT_REQUESTS=$(flightctl get enrollmentrequests -o name)
for request in $ENROLLMENT_REQUESTS
do
    echo "  - Approving ${request} with label project=mlops"
    flightctl approve -l project=mlops er/$request
done

# Wait for devices to be enrolled and appear in device list
echo ""
echo "Waiting for devices to complete enrollment..."
sleep 10

# Apply fleet configuration to enrolled devices
echo ""
echo "Applying fleet configuration..."
flightctl apply -f fleet.yaml
echo "✓ Fleet configuration applied"

# Wait a moment for fleet to be processed
sleep 5

# Shaun- Deployment summary and access information
echo ""
echo "=========================================="
echo "FlightCtl Deployment Complete"
echo "=========================================="
echo ""
echo "FlightCtl Control Plane:"
echo "  - SSH: ssh fedora@${FLIGHTCTL_INSTANCE_IP} -i ${SSH_KEY_NAME}.pem -o StrictHostKeyChecking=no"
echo "  - UI: https://${FLIGHTCTL_INSTANCE_IP}.nip.io (username: mlops, password: mlops123)"
echo ""
echo "Fleet Devices:"
echo "  - 2 x g5.xlarge instances with AMI ${RHEL_AMI_ID}"
echo "  - RHEL 10 + NVIDIA drivers 590.48.01 + CUDA 13.1 + FlightCtl agent"
echo "  - Deploying 3-container MLOps stack: model-car + vLLM + OpenWebUI"
echo ""
echo "To check fleet status:"
echo "  flightctl get devices -o wide"
echo ""
echo "To get device public IPs for accessing services:"
echo "  flightctl console device/<device-name> -- curl -s http://169.254.169.254/latest/meta-data/public-ipv4"
echo ""
echo "Once deployed, services will be available at:"
echo "  - OpenWebUI: http://<device-public-ip>:8080"
echo "  - vLLM API: http://<device-public-ip>:8000/health"
echo ""
echo "=========================================="