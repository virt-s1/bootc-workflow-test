#!/bin/bash
set -euox pipefail

TEST_OS=rhel-9-4

# Set up temporary files.
TEMPDIR=$(mktemp -d)
trap 'rm -rf -- "$TEMPDIR"' EXIT

UNIQUE_STRING=$(tr -dc a-z0-9 < /dev/urandom | head -c 4 ; echo '')
IMAGE_URL="http://${DOWNLOAD_NODE}/rhel-9/nightly/RHEL-9/latest-RHEL-9.4.0/compose/BaseOS/${ARCH}/images"

IMAGE_FILE=$(curl -s "${IMAGE_URL}/" | grep -ioE ">rhel-ec2-.*.${ARCH}.raw.xz<" | tr -d '><')
curl -s -O --output-dir "$TEMPDIR" "${IMAGE_URL}/${IMAGE_FILE}"

sudo dnf install -y xz curl wget
xz -d "${TEMPDIR}/${IMAGE_FILE}"

IMAGE_FILENAME=${IMAGE_FILE%.*}

BUCKET_NAME="bootc-${TEST_OS}-${UNIQUE_STRING}"
BUCKET_URL="s3://${BUCKET_NAME}"

# Create Bucket
aws s3 mb "$BUCKET_URL"

# Upload AMI image to bucket
aws s3 cp \
    --quiet \
    "${TEMPDIR}/${IMAGE_FILENAME}" \
    "${BUCKET_URL}/" \
    --acl private

# Create container simple file
CONTAINERS_FILE="${TEMPDIR}/containers.json"

tee "$CONTAINERS_FILE" > /dev/null << EOF
{
  "Description": "$IMAGE_FILENAME",
  "Format": "raw",
  "Url": "${BUCKET_URL}/${IMAGE_FILENAME}"
}
EOF

# Import the image as an EBS snapshot into EC2
IMPORT_TASK_ID=$(
    aws ec2 import-snapshot \
        --output json \
        --description "bootc $TEST_OS ami snapshot" \
        --disk-container file://"${CONTAINERS_FILE}" | \
        jq -r '.ImportTaskId'
)
rm -f "$CONTAINERS_FILE"

# Wait for snapshot import complete
for _ in $(seq 0 180); do
    IMPORT_STATUS=$(
        aws ec2 describe-import-snapshot-tasks \
            --output json \
            --import-task-ids "$IMPORT_TASK_ID" | \
            jq -r '.ImportSnapshotTasks[].SnapshotTaskDetail.Status'
    )

    # Has the snapshot finished?
    if [[ $IMPORT_STATUS != active ]]; then
        break
    fi

    # Wait 10 seconds and try again.
    sleep 10
done

if [[ $IMPORT_STATUS != completed ]]; then
    echo "Something went wrong with the snapshot. 😢"
    exit 1
else
    echo "Snapshot imported successfully."
fi

SNAPSHOT_ID=$(
    aws ec2 describe-import-snapshot-tasks \
        --output json \
        --import-task-ids "$IMPORT_TASK_ID" | \
        jq -r '.ImportSnapshotTasks[].SnapshotTaskDetail.SnapshotId'
)

aws ec2 create-tags \
    --resources "$SNAPSHOT_ID" \
    --tags Key=Name,Value="bootc-${TEST_OS}-${ARCH}" Key=ImageName,Value="$IMAGE_FILENAME"

REGISTERED_AMI_NAME="bootc-${TEST_OS}-${ARCH}"

if [[ "$ARCH" == x86_64 ]]; then
    IMG_ARCH="$ARCH"
elif [[ "$ARCH" == aarch64 ]]; then
    IMG_ARCH=arm64
fi

AMI_ID=$(
    aws ec2 register-image \
        --name "$REGISTERED_AMI_NAME" \
        --root-device-name /dev/xvda \
        --architecture "$IMG_ARCH" \
        --ena-support \
        --sriov-net-support simple \
        --virtualization-type hvm \
        --block-device-mappings DeviceName=/dev/xvda,Ebs=\{SnapshotId="${SNAPSHOT_ID}"\} DeviceName=/dev/xvdf,Ebs=\{VolumeSize=10\} \
        --boot-mode uefi-preferred \
        --output json | \
        jq -r '.ImageId'
)

aws ec2 wait image-available \
    --image-ids "$AMI_ID"
aws ec2 create-tags \
    --resources "$AMI_ID" \
    --tags Key=Name,Value="bootc-${TEST_OS}-${ARCH}" Key=ImageName,Value="$IMAGE_FILENAME"

# Remove bucket content and bucket itself quietly
aws s3 rb "$BUCKET_URL" --force > /dev/null

# Install yq
sudo wget -q https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq && sudo chmod +x /usr/bin/yq

# Get current using AMI
USED_AMI=$(yq -r ".[0].vars.ami.${ARCH}.\"${TEST_OS}\"" playbooks/deploy-aws.yaml)

# Update to use uploaded AMI
yq -i ".[0].vars.ami.${ARCH}.${TEST_OS} = \"$AMI_ID\"" "playbooks/deploy-aws.yaml"

# List all uploaded AMIs
UPLOADED_AMI_LIST=$(
    aws ec2 describe-images \
        --filters "Name=tag:Name,Values=bootc-${TEST_OS}-${ARCH}" \
        --query 'Images[*].ImageId' \
        --output text
)

# Only keep current using and uploaded AMIs
OLD_AMI=$(echo "$UPLOADED_AMI_LIST" | sed "s/${AMI_ID}//;s/${USED_AMI}//;s/[[:blank:]]//g")

# Delete the third AMI
if [[ "$OLD_AMI" != '' ]]; then
    SNAPSHOT_ID=$(
        aws ec2 describe-images \
            --image-ids "$OLD_AMI" \
            --query 'Images[*].BlockDeviceMappings[*].Ebs.SnapshotId' \
            --output text
    )

    aws ec2 deregister-image \
        --image-id "${OLD_AMI}"

    aws ec2 delete-snapshot \
        --snapshot-id "${SNAPSHOT_ID}"
fi
