#!/bin/bash

aws ec2 delete-key-pair --key-name flightctl-instance
sudo rm flightctl-instance.pem

aws ec2 terminate-instances --instance-ids $(aws ec2 describe-instances --filters "Name=tag:Name,Values=flightctl-instance" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].InstanceId" --output text)