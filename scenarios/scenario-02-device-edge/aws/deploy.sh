#!/bin/bash

# Set AWS_REGION and RHEL_AMI_ID from user input
export AWS_REGION=$1
if [ -z "$AWS_REGION" ]
then
    echo "Missing AWS region where the AMI is hosted"
    exit 1
fi

export RHEL_AMI_ID=$2
if [ -z "$RHEL_AMI_ID" ]
then
    echo "Missing AMI ID of a RHEL image with the Flightctl agent and Nvidia drivers configured"
    echo "This image can be prepared using the build-ami.sh script"
    exit 1
fi

# Create key pair for accessing the instances
SSH_KEY_NAME=mlops
SSH_KEY_FILE=aws/$SSH_KEY_NAME.pem
aws ec2 create-key-pair --key-name $SSH_KEY_NAME --query 'KeyMaterial' --output text > $SSH_KEY_FILE
chmod 400 $SSH_KEY_FILE

INSTANCE_TYPE=t3.xlarge

# Find a suitable subnet in an availability zone that supports instance type
SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=availability-zone,Values=$(aws ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values=$INSTANCE_TYPE --query 'InstanceTypeOfferings[0].Location' --output text)" --query 'Subnets[0].SubnetId' --output text)

# Get VPC ID for the subnet
VPC_ID=$(aws ec2 describe-subnets --subnet-ids $SUBNET_ID --query 'Subnets[0].VpcId' --output text)

# Create a security group for the flightctl instance
SG_NAME=flightctl-sg
aws ec2 create-security-group --group-name $SG_NAME --description "Security group for Flightctl instance" --vpc-id $VPC_ID
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
# Allow access to Flightctl Telemetry Gateway
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 4317 --cidr 0.0.0.0/0 2>/dev/null || true
# Expose Grafana dashboard
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 3000 --cidr 0.0.0.0/0 2>/dev/null || true

# Create separate security group for MLOps fleet devices (vLLM + OpenWebUI) 
FLEET_SG_NAME=mlops-fleet-sg
aws ec2 create-security-group --group-name $FLEET_SG_NAME --description "Security group for MLOps fleet devices running vLLM and OpenWebUI" --vpc-id $VPC_ID
FLEET_SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values=$FLEET_SG_NAME --query "SecurityGroups[0].GroupId" --output text)

# Fleet security group rules: SSH access + MLOps container ports
aws ec2 authorize-security-group-ingress --group-id $FLEET_SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0 2>/dev/null || true    # SSH
aws ec2 authorize-security-group-ingress --group-id $FLEET_SG_ID --protocol tcp --port 8000 --cidr 0.0.0.0/0 2>/dev/null || true  # vLLM API
aws ec2 authorize-security-group-ingress --group-id $FLEET_SG_ID --protocol tcp --port 8080 --cidr 0.0.0.0/0 2>/dev/null || true  # OpenWebUI
aws ec2 authorize-security-group-ingress --group-id $FLEET_SG_ID --protocol tcp --port 9090 --cidr 0.0.0.0/0 2>/dev/null || true  # Prometheus
aws ec2 authorize-security-group-ingress --group-id $FLEET_SG_ID --protocol tcp --port 9100 --cidr 0.0.0.0/0 2>/dev/null || true  # Node Exporter

# Launch an instance with a fedora image and install Flightctl using user data script
NAME=flightctl-instance
FEDORA_AMI_ID=ami-00591e9b6ab674470
FLIGHTCTL_INSTANCE_USERNAME=fedora

# Capture instance ID from run-instances command to ensure we get it before querying for IP
FLIGHTCTL_INSTANCE_ID=$(aws ec2 run-instances \
    --image-id $FEDORA_AMI_ID --count 1 \
    --instance-type $INSTANCE_TYPE \
    --key-name $SSH_KEY_NAME \
    --security-group-ids $SG_ID \
    --subnet-id $SUBNET_ID \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3"}}]' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME}}]" \
    --user-data file://aws/init-script.txt \
    --query 'Instances[0].InstanceId' --output text)

# Wait for instance to be running before fetching IP to avoid getting empty/None IP
aws ec2 wait instance-running --instance-ids $FLIGHTCTL_INSTANCE_ID --region $AWS_REGION

# Get instance IP address
FLIGHTCTL_INSTANCE_IP=$(aws ec2 describe-instances \
    --instance-ids $FLIGHTCTL_INSTANCE_ID \
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

# Wait for cloud init to complete
sleep 90s 
ssh ${FLIGHTCTL_INSTANCE_USERNAME}@${FLIGHTCTL_INSTANCE_IP} -i $SSH_KEY_FILE -o StrictHostKeyChecking=no cloud-init status --wait

echo "FlightCtl instance (${FLIGHTCTL_INSTANCE_ID}) configured and running at the IP address ${FLIGHTCTL_INSTANCE_IP}"

# Create a Flightctl fleet
echo "Attempting to login to FlightCtl at: https://${FLIGHTCTL_INSTANCE_IP}.nip.io:3443"
flightctl login -k "https://${FLIGHTCTL_INSTANCE_IP}.nip.io:3443" -u mlops -p mlops123

while [ $? -ne 0 ]
do
    echo "Login failed, retrying in 30 seconds..."
    sleep 30s
    flightctl login -k "https://${FLIGHTCTL_INSTANCE_IP}.nip.io:3443" -u mlops -p mlops123
done

echo "Successfully logged into FlightCtl"

ENROLLMENT_SERVICE_CONFIG=$(flightctl certificate request --signer=enrollment --expiration=365d --output=embedded)

# Use g5.xlarge for GPU support (NVIDIA A10G 24GB)
GPU_INSTANCE_TYPE=g5.xlarge

# Find GPU-compatible subnet
GPU_SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=availability-zone,Values=$(aws ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values=$GPU_INSTANCE_TYPE --region $AWS_REGION --query 'InstanceTypeOfferings[0].Location' --output text)" --query 'Subnets[0].SubnetId' --output text)

echo "Launching fleet devices with AMI: ${RHEL_AMI_ID} and instance type: ${GPU_INSTANCE_TYPE}"
echo "Using GPU-compatible subnet: ${GPU_SUBNET_ID}"

FLEET_INSTANCE_NAMES=("flightctl-device-1" "flightctl-device-2")

for instance_name in ${FLEET_INSTANCE_NAMES[@]}
do
    cat > /tmp/fleet-user-data.txt <<EOF
#!/bin/bash
cat > /etc/flightctl/config.yaml <<'CONFIGEOF'
${ENROLLMENT_SERVICE_CONFIG}
CONFIGEOF
echo "${FLIGHTCTL_INSTANCE_IP} flightctl-telemetry-gateway" | tee -a /etc/hosts
EOF

    aws ec2 run-instances \
        --image-id $RHEL_AMI_ID --count 1 \
        --instance-type $GPU_INSTANCE_TYPE \
        --key-name $SSH_KEY_NAME \
        --security-group-ids $FLEET_SG_ID \
        --subnet-id $GPU_SUBNET_ID \
        --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":50,"VolumeType":"gp3"}}]' \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${instance_name}}]" \
        --user-data file:///tmp/fleet-user-data.txt
    echo "Launched ${instance_name}"
done

rm -f /tmp/fleet-user-data.txt

# Wait for devices to boot and send enrollment requests (typically 2-3 minutes)
echo ""
echo "Waiting for devices to boot and send enrollment requests..."
echo "This may take 2-3 minutes..."
NUM_EXPECTED_DEVICES=${#FLEET_INSTANCE_NAMES[@]}
RETRY_COUNT=0
MAX_RETRIES=50

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    ENROLLMENT_COUNT=$(flightctl get enrollmentrequests -o name 2>/dev/null | wc -l)
    echo "  - Found ${ENROLLMENT_COUNT}/${NUM_EXPECTED_DEVICES} enrollment requests (attempt $((RETRY_COUNT+1))/${MAX_RETRIES})"

    if [ "$ENROLLMENT_COUNT" -ge "$NUM_EXPECTED_DEVICES" ]; then
        echo "✓ All enrollment requests received!"
        break
    fi

    sleep 10
    RETRY_COUNT=$((RETRY_COUNT+1))
done

if [ "$ENROLLMENT_COUNT" -lt "$NUM_EXPECTED_DEVICES" ]; then
    echo ":warning: Warning: Only found ${ENROLLMENT_COUNT}/${NUM_EXPECTED_DEVICES} enrollment requests after 5 minutes"
    echo "Proceeding with available requests..."
fi

# Approve all enrollment requests with project=mlops label
MLOPS_LABEL="project=mlops"
echo ""
echo "Approving enrollment requests..."
ENROLLMENT_REQUESTS=$(flightctl get enrollmentrequests -o name)
for request in $ENROLLMENT_REQUESTS
do
    echo "  - Approving ${request} with label ${MLOPS_LABEL}"
    flightctl approve -l $MLOPS_LABEL er/$request
done

# Wait for devices to be enrolled and appear in device list
echo ""
echo "Waiting for devices to complete enrollment..."
sleep 30

# Create an alias for each device
echo ""
echo "Adding alias to devices..."
DEVICES=$(flightctl get devices -o name -l $MLOPS_LABEL)
for device in $DEVICES
do
    DEVICE_SPEC_FILE=$device.yaml
    flightctl get device $device -o yaml > $DEVICE_SPEC_FILE
    HOSTNAME=$(yq '.status.systemInfo.hostname' < $DEVICE_SPEC_FILE) yq -i '.metadata.labels.alias = strenv(HOSTNAME)' $DEVICE_SPEC_FILE
    flightctl apply -f $DEVICE_SPEC_FILE 
    rm $DEVICE_SPEC_FILE
done

# Apply fleet configuration to enrolled devices
echo ""
echo "Applying fleet configuration..."
flightctl apply -f flightctl/git-config-provider.yaml
flightctl apply -f flightctl/fleet.yaml
echo "✓ Fleet configuration applied"

# Wait until the fleet spec has been applied to all devices
while [ $(flightctl get devices -l=$MLOPS_LABEL --summary-only | grep -cE "(UpToDate|Healthy).*\s+$NUM_EXPECTED_DEVICES$") -ne 2 ]; do
    echo "Waiting for fleet spec to be rolled out across all ${NUM_EXPECTED_DEVICES} devices..."
    sleep 30s
done

# Deployment summary and access information
echo ""
echo "=========================================="
echo "FlightCtl Deployment Complete"
echo "=========================================="
echo ""
echo "FlightCtl Control Plane:"
echo "  - SSH: ssh ${FLIGHTCTL_INSTANCE_USERNAME}@${FLIGHTCTL_INSTANCE_IP} -i $SSH_KEY_FILE -o StrictHostKeyChecking=no"
echo "  - UI: https://${FLIGHTCTL_INSTANCE_IP}.nip.io (username: mlops, password: mlops123)"
echo "  - CLI: flightctl login https://${FLIGHTCTL_INSTANCE_IP}.nip.io:3443 -u mlops -p mlops123"
echo ""
echo "Fleet Devices:"
echo "  - 2 x g5.xlarge instances with AMI ${RHEL_AMI_ID}"
echo "  - RHEL 10 + NVIDIA drivers 590.48.01 + CUDA 13.1 + FlightCtl agent"
echo "  - Deploying 2-container MLOps stack: vLLM (with modelcar image volume) + OpenWebUI"
echo "  - Deploying Observability stack: Prometheus"
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
echo "FlightCtl fleet metrics including application metrics are available on the Grafana dashboard at:"
echo "  - UI: https://${FLIGHTCTL_INSTANCE_IP}.nip.io:3000 (username: admin, password: admin)"
echo "=========================================="