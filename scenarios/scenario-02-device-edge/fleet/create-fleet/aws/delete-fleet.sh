#!/bin/bash

aws ec2 delete-key-pair --key-name mlops
sudo rm mlops.pem