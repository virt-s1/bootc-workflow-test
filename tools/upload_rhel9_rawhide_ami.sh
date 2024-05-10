#!/bin/bash
set -euox pipefail

# Set up temporary files.
TEMPDIR=$(mktemp -d)
trap 'rm -rf -- "$TEMPDIR"' EXIT

UNIQUE_STRING=$(tr -dc a-z0-9 < /dev/urandom | head -c 4 ; echo '')
case "$TEST_OS" in
    rhel-9-4)
        IMAGE_URL="http://${DOWNLOAD_NODE}/rhel-9/nightly/updates/RHEL-9/latest-RHEL-9.4.0/compose/BaseOS/${ARCH}/images"
        IMAGE_FILE=$(curl -s "${IMAGE_URL}/" | grep -ioE ">rhel-ec2-.*.${ARCH}.raw.xz<" | tr -d '><')
    ;;
    rhel-9-5)
        IMAGE_URL="http://${DOWNLOAD_NODE}/rhel-9/nightly/RHEL-9/latest-RHEL-9.5.0/compose/BaseOS/${ARCH}/images"
        IMAGE_FILE=$(curl -s "${IMAGE_URL}/" | grep -ioE ">rhel-ec2-.*.${ARCH}.raw.xz<" | tr -d '><')
    ;;
    fedora-41)
        IMAGE_URL="https://dl.fedoraproject.org/pub/fedora/linux/development/rawhide/Cloud/${ARCH}/images"
        IMAGE_FILE=$(curl -s "${IMAGE_URL}/" | grep -ioE ">Fedora-Cloud-Base-AmazonEC2.*.raw.xz<" | tr -d '><')
    ;;
esac

curl -s -O --output-dir "$TEMPDIR" "${IMAGE_URL}/${IMAGE_FILE}"

sudo dnf install -y xz curl wget jq
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

REGISTERED_AMI_NAME="bootc-${TEST_OS}-${ARCH}-$(date +'%y%m%d')"

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

# Save AMI ID to ssm parameter
aws ssm put-parameter \
    --name "bootc-${TEST_OS}-${ARCH}" \
    --type "String" \
    --data-type "aws:ec2:image" \
    --value "$AMI_ID" \
    --overwrite
