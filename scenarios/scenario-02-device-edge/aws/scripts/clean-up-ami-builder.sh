#!/bin/bash
set -euo pipefail

# =============================================================================
# Clean up AWS resources from build-ami.sh
#
# Finds and removes the helper instance, EBS volumes, security group,
# and key pair created by build-ami.sh.
#
# Usage:
#   ./clean-up-ami-builder.sh
# =============================================================================

REGION="eu-north-1"
SG_NAME="bootc-builder-sg"

echo "=== Cleaning up bootc-builder AWS resources in ${REGION} ==="
echo ""

# Terminate any running builder instances
INSTANCE_IDS=$(aws ec2 describe-instances \
  --region ${REGION} \
  --filters "Name=tag:Name,Values=bootc-builder-*" "Name=instance-state-name,Values=running,stopped,pending" \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text 2>/dev/null || echo "")

if [ -n "${INSTANCE_IDS}" ] && [ "${INSTANCE_IDS}" != "None" ]; then
  echo "Terminating builder instances: ${INSTANCE_IDS}"
  aws ec2 terminate-instances --region ${REGION} --instance-ids ${INSTANCE_IDS} > /dev/null
  aws ec2 wait instance-terminated --region ${REGION} --instance-ids ${INSTANCE_IDS} 2>/dev/null || true
  echo "  Instances terminated."
else
  echo "  No builder instances found."
fi

# Delete unattached builder volumes
VOLUME_IDS=$(aws ec2 describe-volumes \
  --region ${REGION} \
  --filters "Name=tag:Name,Values=mlops-bootc-*" "Name=status,Values=available" \
  --query 'Volumes[].VolumeId' \
  --output text 2>/dev/null || echo "")

if [ -n "${VOLUME_IDS}" ] && [ "${VOLUME_IDS}" != "None" ]; then
  for VID in ${VOLUME_IDS}; do
    echo "Deleting volume ${VID}..."
    aws ec2 delete-volume --region ${REGION} --volume-id ${VID} > /dev/null 2>&1 || true
  done
  echo "  Volumes deleted."
else
  echo "  No orphaned volumes found."
fi

# Delete security group
SG_ID=$(aws ec2 describe-security-groups \
  --region ${REGION} \
  --group-names ${SG_NAME} \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null || echo "")

if [ -n "${SG_ID}" ] && [ "${SG_ID}" != "None" ]; then
  echo "Deleting security group ${SG_ID}..."
  sleep 5
  aws ec2 delete-security-group --region ${REGION} --group-id ${SG_ID} > /dev/null 2>&1 || true
  echo "  Security group deleted."
else
  echo "  No builder security group found."
fi

# Delete any builder key pairs
KEY_NAMES=$(aws ec2 describe-key-pairs \
  --region ${REGION} \
  --filters "Name=key-name,Values=bootc-builder-key-*" \
  --query 'KeyPairs[].KeyName' \
  --output text 2>/dev/null || echo "")

if [ -n "${KEY_NAMES}" ] && [ "${KEY_NAMES}" != "None" ]; then
  for KN in ${KEY_NAMES}; do
    echo "Deleting key pair ${KN}..."
    aws ec2 delete-key-pair --region ${REGION} --key-name ${KN} > /dev/null 2>&1 || true
    rm -f "/tmp/${KN}.pem"
  done
  echo "  Key pairs deleted."
else
  echo "  No builder key pairs found."
fi

echo ""
echo "=== Cleanup complete ==="
