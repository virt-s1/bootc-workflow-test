#!/bin/bash
set -euox pipefail

# Get latest CS9 AMI ID
LATEST_CS9_X86_64_AMI_ID=$(curl -s https://www.centos.org/download/aws-images/ | grep -A3 "CentOS Stream 9" | grep -A2 "us-west-2" | grep -A1 "x86_64" | grep -v "x86_64" | grep -ioE ">ami-.*<" | tr -d '><')
LATEST_CS9_AARCH64_AMI_ID=$(curl -s https://www.centos.org/download/aws-images/ | grep -A3 "CentOS Stream 9" | grep -A2 "us-west-2" | grep -A1 "aarch64" | grep -v "aarch64" | grep -ioE ">ami-.*<" | tr -d '><')

# Save AMI ID to ssm parameter
aws ssm put-parameter \
    --name "bootc-centos-stream-9-x86_64" \
    --type "String" \
    --data-type "aws:ec2:image" \
    --value "$LATEST_CS9_X86_64_AMI_ID" \
    --overwrite

aws ssm put-parameter \
    --name "bootc-centos-stream-9-aarch64" \
    --type "String" \
    --data-type "aws:ec2:image" \
    --value "$LATEST_CS9_AARCH64_AMI_ID" \
    --overwrite
