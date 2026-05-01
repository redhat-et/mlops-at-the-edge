#!/bin/bash
set -euo pipefail

# =============================================================================
# Build MLOps Bootc AMI
#
# Uses an EC2 RHEL 9 helper instance to pull a pre-built bootc image
# from Quay, run bootc-image-builder, and register an AMI.
# Cleans up all helper resources on completion.
#
# Prerequisites:
#   - aws cli (configured with credentials)
#   - Bootc image already pushed to Quay.io
#
# Usage:
#   ./build-ami.sh <image_tag> [region]
#   ./build-ami.sh quay.io/redhat-et/mlops-bootc-rhel10-nvidia:v1.0.20
#   ./build-ami.sh quay.io/redhat-et/mlops-bootc-rhel10-nvidia:v1.0.20 us-east-1
# =============================================================================

IMAGE_TAG="${1:-}"
REGION="${2:-eu-north-1}"

if [ -z "${IMAGE_TAG}" ]; then
  echo "Usage: $0 <image_tag> [region]"
  echo "  e.g. $0 quay.io/redhat-et/mlops-bootc-rhel10-nvidia:v1.0.20"
  echo "  e.g. $0 quay.io/redhat-et/mlops-bootc-rhel10-nvidia:v1.0.20 us-east-1"
  exit 1
fi

# Extract version from tag for naming resources
VERSION="${IMAGE_TAG##*:}"

KEY_NAME="bootc-builder-key-$$"
KEY_FILE="/tmp/${KEY_NAME}.pem"
SG_NAME="bootc-builder-sg"
INSTANCE_TYPE="t3.large"
VOLUME_SIZE_ROOT=50
VOLUME_SIZE_AMI=15
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Building AMI for ${IMAGE_TAG} ==="
echo ""

# -----------------------------------------------------------------------------
# Step 1: Set up AWS resources (key pair, security group)
# -----------------------------------------------------------------------------
echo "--- Step 1: Setting up AWS resources ---"
echo "  Using image: ${IMAGE_TAG}"

# Key pair - always create fresh (cleanup removes it)
echo "  Creating key pair: ${KEY_NAME}"
aws ec2 create-key-pair \
  --region ${REGION} \
  --key-name ${KEY_NAME} \
  --query 'KeyMaterial' \
  --output text > "${KEY_FILE}"
chmod 400 "${KEY_FILE}"

# Security group - create if it doesn't exist
SG_ID=$(aws ec2 describe-security-groups \
  --region ${REGION} \
  --group-names ${SG_NAME} \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null || echo "")

if [ -z "${SG_ID}" ] || [ "${SG_ID}" = "None" ]; then
  echo "  Creating security group: ${SG_NAME}"
  SG_ID=$(aws ec2 create-security-group \
    --region ${REGION} \
    --group-name ${SG_NAME} \
    --description "Temporary SG for bootc image builder" \
    --query 'GroupId' \
    --output text)

  aws ec2 authorize-security-group-ingress \
    --region ${REGION} \
    --group-id ${SG_ID} \
    --protocol tcp \
    --port 22 \
    --cidr 0.0.0.0/0 > /dev/null
else
  echo "  Using existing security group: ${SG_ID}"
fi

echo ""

# -----------------------------------------------------------------------------
# Step 2: Launch RHEL 9 helper instance
# -----------------------------------------------------------------------------
echo "--- Step 2: Launching RHEL 9 helper instance ---"

RHEL9_AMI=$(aws ec2 describe-images \
  --region ${REGION} \
  --owners 309956199498 \
  --filters "Name=name,Values=RHEL-9*_HVM-*-x86_64*" "Name=architecture,Values=x86_64" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text)

if [ -z "${RHEL9_AMI}" ] || [ "${RHEL9_AMI}" = "None" ]; then
  echo "ERROR: Could not find RHEL 9 AMI in ${REGION}"
  exit 1
fi

echo "  RHEL 9 AMI: ${RHEL9_AMI}"

INSTANCE_ID=$(aws ec2 run-instances \
  --region ${REGION} \
  --image-id ${RHEL9_AMI} \
  --instance-type ${INSTANCE_TYPE} \
  --key-name ${KEY_NAME} \
  --security-group-ids ${SG_ID} \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${VOLUME_SIZE_ROOT},\"VolumeType\":\"gp3\"}}]" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=bootc-builder-${VERSION}}]" \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "  Instance ID: ${INSTANCE_ID}"
echo "  Waiting for instance to be running..."

aws ec2 wait instance-running --region ${REGION} --instance-ids ${INSTANCE_ID}

PUBLIC_IP=$(aws ec2 describe-instances \
  --region ${REGION} \
  --instance-ids ${INSTANCE_ID} \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo "  Instance ready at: ${PUBLIC_IP}"

# Wait for SSH to be available
echo "  Waiting for SSH to be ready..."
for i in $(seq 1 30); do
  if ssh -i "${KEY_FILE}" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ec2-user@${PUBLIC_IP} "echo ready" > /dev/null 2>&1; then
    break
  fi
  sleep 10
done

echo ""

# -----------------------------------------------------------------------------
# Step 3: Build disk.raw on EC2 instance
# -----------------------------------------------------------------------------
echo "--- Step 3: Building disk.raw on EC2 ---"

ssh -i "${KEY_FILE}" -o StrictHostKeyChecking=no ec2-user@${PUBLIC_IP} << REMOTE
set -euo pipefail

echo "Creating output directory..."
mkdir -p output

echo "Pulling bootc-image-builder..."
sudo podman pull quay.io/centos-bootc/bootc-image-builder:latest

echo "Pulling bootc image..."
sudo podman pull ${IMAGE_TAG}

echo "Building disk.raw (this takes 15-20 minutes)..."
sudo podman run --rm --privileged \
  --pull=newer \
  --security-opt label=type:unconfined_t \
  -v ./output:/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type raw \
  ${IMAGE_TAG}

echo "disk.raw created:"
ls -lh output/image/disk.raw
REMOTE

echo ""

# -----------------------------------------------------------------------------
# Step 4: Create EBS volume, copy disk.raw, create snapshot
# -----------------------------------------------------------------------------
echo "--- Step 4: Creating EBS volume and copying disk.raw ---"

AZ=$(aws ec2 describe-instances \
  --region ${REGION} \
  --instance-ids ${INSTANCE_ID} \
  --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' \
  --output text)

VOLUME_ID=$(aws ec2 create-volume \
  --region ${REGION} \
  --availability-zone ${AZ} \
  --size ${VOLUME_SIZE_AMI} \
  --volume-type gp3 \
  --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=mlops-bootc-${VERSION}}]" \
  --query 'VolumeId' \
  --output text)

echo "  Volume ID: ${VOLUME_ID}"
echo "  Waiting for volume to be available..."

aws ec2 wait volume-available --region ${REGION} --volume-ids ${VOLUME_ID}

echo "  Attaching volume to instance..."
aws ec2 attach-volume \
  --region ${REGION} \
  --volume-id ${VOLUME_ID} \
  --instance-id ${INSTANCE_ID} \
  --device /dev/sdf > /dev/null

aws ec2 wait volume-in-use --region ${REGION} --volume-ids ${VOLUME_ID}

echo "  Waiting for EBS device to appear..."
VOLUME_SERIAL="${VOLUME_ID//-/}"
EBS_DEVICE=""
for i in $(seq 1 12); do
  EBS_DEVICE=$(ssh -i "${KEY_FILE}" -o StrictHostKeyChecking=no ec2-user@${PUBLIC_IP} \
    "lsblk -dno NAME,SERIAL 2>/dev/null | grep '${VOLUME_SERIAL}' | awk '{print \"/dev/\" \$1}'" 2>/dev/null || true)
  if [ -n "${EBS_DEVICE}" ]; then
    break
  fi
  echo "    Attempt ${i}/12 - device not yet visible, waiting 5s..."
  sleep 5
done

if [ -z "${EBS_DEVICE}" ]; then
  echo "  DEBUG: lsblk output on instance:"
  ssh -i "${KEY_FILE}" -o StrictHostKeyChecking=no ec2-user@${PUBLIC_IP} "lsblk -dno NAME,SERIAL,SIZE"
  echo "  Looking for serial: ${VOLUME_SERIAL}"
  echo "ERROR: Could not find EBS device for volume ${VOLUME_ID}"
  exit 1
fi

echo "  EBS device: ${EBS_DEVICE}"
echo "  Copying disk.raw to EBS volume (this takes a few minutes)..."
ssh -i "${KEY_FILE}" -o StrictHostKeyChecking=no ec2-user@${PUBLIC_IP} \
  "sudo dd if=output/image/disk.raw of=${EBS_DEVICE} bs=4M status=progress && sync"

echo "  Detaching volume..."
aws ec2 detach-volume --region ${REGION} --volume-id ${VOLUME_ID} > /dev/null
aws ec2 wait volume-available --region ${REGION} --volume-ids ${VOLUME_ID}

echo ""

# -----------------------------------------------------------------------------
# Step 5: Create snapshot
# -----------------------------------------------------------------------------
echo "--- Step 5: Creating snapshot ---"

SNAPSHOT_ID=$(aws ec2 create-snapshot \
  --region ${REGION} \
  --volume-id ${VOLUME_ID} \
  --description "MLOps bootc RHEL 10 NVIDIA ${VERSION}" \
  --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=mlops-bootc-rhel10-nvidia-${VERSION}}]" \
  --query 'SnapshotId' \
  --output text)

echo "  Snapshot ID: ${SNAPSHOT_ID}"
echo "  Waiting for snapshot to complete..."

for i in $(seq 1 60); do
  STATE=$(aws ec2 describe-snapshots \
    --region ${REGION} \
    --snapshot-ids ${SNAPSHOT_ID} \
    --query 'Snapshots[0].State' \
    --output text)
  if [ "${STATE}" = "completed" ]; then
    echo "  Snapshot completed."
    break
  fi
  PROGRESS=$(aws ec2 describe-snapshots \
    --region ${REGION} \
    --snapshot-ids ${SNAPSHOT_ID} \
    --query 'Snapshots[0].Progress' \
    --output text)
  echo "  Snapshot state: ${STATE} (${PROGRESS})"
  sleep 15
done

echo ""

# -----------------------------------------------------------------------------
# Step 6: Register AMI
# -----------------------------------------------------------------------------
echo "--- Step 6: Registering AMI ---"

AMI_ID=$(aws ec2 register-image \
  --region ${REGION} \
  --name "mlops-bootc-rhel10-nvidia-${VERSION}" \
  --description "RHEL 10 bootc with FlightCtl agent, NVIDIA drivers, Podman, OTel Collector ${VERSION}" \
  --architecture x86_64 \
  --root-device-name /dev/sda1 \
  --block-device-mappings "DeviceName=/dev/sda1,Ebs={SnapshotId=${SNAPSHOT_ID},VolumeSize=${VOLUME_SIZE_AMI},VolumeType=gp3,DeleteOnTermination=true}" \
  --ena-support \
  --virtualization-type hvm \
  --boot-mode uefi-preferred \
  --query 'ImageId' \
  --output text)

echo "  AMI registered: ${AMI_ID}"
echo ""

echo ""
echo "============================================"
echo "  AMI created successfully!"
echo "  AMI ID:  ${AMI_ID}"
echo "  Region:  ${REGION}"
echo "  Version: ${VERSION}"
echo "============================================"
echo ""
echo "Update deploy.sh with:"
echo "  AMI_ID=\"${AMI_ID}\""

# Cleanup helper resources
echo ""
echo "--- Cleaning up builder resources ---"
"${SCRIPT_DIR}/clean-up-ami-builder.sh" "${REGION}"
