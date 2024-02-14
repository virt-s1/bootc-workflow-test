#!/bin/bash
set -euox pipefail

# Get latest CS9 AMI ID
LATEST_CS9_X86_64_AMI_ID=$(curl -s https://www.centos.org/download/aws-images/ | grep -A3 "CentOS Stream 9" | grep -A2 "us-east-1" | grep -A1 "x86_64" | grep -v "x86_64" | grep -ioE ">ami-.*<" | tr -d '><')
LATEST_CS9_AARCH64_AMI_ID=$(curl -s https://www.centos.org/download/aws-images/ | grep -A3 "CentOS Stream 9" | grep -A2 "us-east-1" | grep -A1 "aarch64" | grep -v "aarch64" | grep -ioE ">ami-.*<" | tr -d '><')

# Get current CS9 AMI ID
CURRENT_CS9_X86_64_AMI_ID=$(yq -r ".[0].vars.ami.x86_64.\"centos-stream-9\"" playbooks/deploy-aws.yaml)
CURRENT_CS9_AARC64_AMI_ID=$(yq -r ".[0].vars.ami.aarch64.\"centos-stream-9\"" playbooks/deploy-aws.yaml)

# Update CS9 x86_64 AMI ID
if [[ "$LATEST_CS9_X86_64_AMI_ID" != "$CURRENT_CS9_X86_64_AMI_ID" ]]; then
    sed -i "s/centos-stream-9: ${CURRENT_CS9_X86_64_AMI_ID}/centos-stream-9: ${LATEST_CS9_X86_64_AMI_ID}/" playbooks/deploy-aws.yaml
fi

# Update CS9 aarch64 AMI ID
if [[ "$LATEST_CS9_AARCH64_AMI_ID" != "$CURRENT_CS9_AARC64_AMI_ID" ]]; then
    sed -i "s/centos-stream-9: ${CURRENT_CS9_AARC64_AMI_ID}/centos-stream-9: ${LATEST_CS9_AARCH64_AMI_ID}/" playbooks/deploy-aws.yaml
fi
