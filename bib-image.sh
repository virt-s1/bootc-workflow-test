#!/bin/bash
set -exuo pipefail

ARCH=$(uname -m)

# Colorful timestamped output.
function greenprint {
    echo -e "\033[1;32m[$(date -Isecond)] ${1}\033[0m"
}

function redprint {
    echo -e "\033[1;31m[$(date -Isecond)] ${1}\033[0m"
}

TEMPDIR=$(mktemp -d)
trap 'rm -rf -- "$TEMPDIR"' EXIT

# SSH configurations
SSH_KEY=${TEMPDIR}/id_rsa
ssh-keygen -f "${SSH_KEY}" -N "" -q -t rsa-sha2-256 -b 2048
SSH_KEY_PUB="${SSH_KEY}.pub"

INSTALL_CONTAINERFILE=${TEMPDIR}/Containerfile.install
UPGRADE_CONTAINERFILE=${TEMPDIR}/Containerfile.upgrade
QUAY_REPO_TAG="${QUAY_REPO_TAG:-$(tr -dc a-z0-9 < /dev/urandom | head -c 4 ; echo '')}"
INVENTORY_FILE="${TEMPDIR}/inventory"

REPLACE_CLOUD_USER=""
case "$TEST_OS" in
    "rhel-9-4")
        IMAGE_NAME="rhel9-rhel_bootc"
        TIER1_IMAGE_URL="${RHEL_REGISTRY_URL}/${IMAGE_NAME}:rhel-9.4"
        TIER1_IMAGE_URL="${IMAGE_URL-$TIER1_IMAGE_URL}"
        SSH_USER="cloud-user"
        CURRENT_COMPOSE_RHEL94=$(skopeo inspect --tls-verify=false "docker://${TIER1_IMAGE_URL}" | jq -r '.Labels."redhat.compose-id"')
        sed "s/REPLACE_ME/${DOWNLOAD_NODE}/; s/REPLACE_COMPOSE_ID/${CURRENT_COMPOSE_RHEL94}/" files/rhel-9-4.template | tee rhel-9-4.repo > /dev/null
        # sed "s/REPLACE_ME/${DOWNLOAD_NODE}/; s/REPLACE_COMPOSE_ID/latest-RHEL-9.4.0/" files/rhel-9-4.template | tee rhel-9-4.repo > /dev/null
        ADD_REPO="COPY rhel-9-4.repo /etc/yum.repos.d/rhel-9-4.repo"
        if [[ "$PLATFORM" == "aws" ]]; then
            SSH_USER="ec2-user"
            REPLACE_CLOUD_USER='RUN sed -i "s/name: cloud-user/name: ec2-user/g" /etc/cloud/cloud.cfg'
        fi
        greenprint "Prepare cloud-init file"
        tee -a "playbooks/user-data" > /dev/null << EOF
#cloud-config
yum_repos:
  rhel-94-baseos:
    name: rhel-94-baseos
    baseurl: http://${DOWNLOAD_NODE}/rhel-9/nightly/RHEL-9/${CURRENT_COMPOSE_RHEL94}/compose/BaseOS/\$basearch/os/
    enabled: true
    gpgcheck: false
  rhel-94-appstream:
    name: rhel-94-appstream
    baseurl: http://${DOWNLOAD_NODE}/rhel-9/nightly/RHEL-9/${CURRENT_COMPOSE_RHEL94}/compose/AppStream/\$basearch/os/
    enabled: true
    gpgcheck: false
EOF
        TRANSIENT_ROOT="false"
        ;;
    "centos-stream-9")
        IMAGE_NAME=${IMAGE_NAME:-"centos-bootc"}
        TIER1_IMAGE_URL="quay.io/centos-bootc/${IMAGE_NAME}:stream9"
        TIER1_IMAGE_URL="${IMAGE_URL-$TIER1_IMAGE_URL}"
        SSH_USER="cloud-user"
        ADD_REPO=""
        if [[ "$PLATFORM" == "aws" ]]; then
            SSH_USER="ec2-user"
            REPLACE_CLOUD_USER='RUN sed -i "s/name: cloud-user/name: ec2-user/g" /etc/cloud/cloud.cfg'
        fi
        TRANSIENT_ROOT="true"
        ;;
    "fedora-eln")
        IMAGE_NAME="fedora-bootc"
        TIER1_IMAGE_URL="quay.io/centos-bootc/${IMAGE_NAME}:eln"
        TIER1_IMAGE_URL="${IMAGE_URL-$TIER1_IMAGE_URL}"
        SSH_USER="fedora"
        ADD_REPO=""
        TRANSIENT_ROOT="true"
        ;;
    *)
        redprint "Variable TEST_OS has to be defined"
        exit 1
        ;;
esac

TEST_IMAGE_NAME="${IMAGE_NAME}-test"
# bootc-image-builder does not support private image repo,
# use temporary public image repo as workaround
TEST_IMAGE_URL="quay.io/rhel-edge/${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}"

greenprint "Configure container build arch"
case "$ARCH" in
    "x86_64")
        BUILD_PLATFORM="linux/amd64"
        ;;
    "aarch64")
        BUILD_PLATFORM="linux/arm64"
        ;;
    *)
        redprint "Variable ARCH has to be defined"
        exit 1
        ;;
esac


[[ $- =~ x ]] && debug=1 && set +x
sed "s/REPLACE_ME/${QUAY_SECRET}/g" files/auth.template | tee auth.json > /dev/null
[[ $debug == 1 ]] && set -x
greenprint "Create $TEST_OS installation Containerfile"
tee "$INSTALL_CONTAINERFILE" > /dev/null << EOF
FROM "$TIER1_IMAGE_URL"
$ADD_REPO
RUN dnf -y install python3 cloud-init && \
    dnf -y clean all
COPY auth.json /etc/ostree/auth.json
$REPLACE_CLOUD_USER
EOF

greenprint "Check $TEST_OS installation Containerfile"
cat "$INSTALL_CONTAINERFILE"

greenprint "Login quay.io"
podman login -u "${QUAY_USERNAME}" -p "${QUAY_PASSWORD}" quay.io

greenprint "Build $TEST_OS installation container image"
podman build --platform "$BUILD_PLATFORM" -t "${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" -f "$INSTALL_CONTAINERFILE" .

greenprint "Push $TEST_OS installation container image"
podman push "${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" "$TEST_IMAGE_URL"

greenprint "Prepare inventory file"
tee -a "$INVENTORY_FILE" > /dev/null << EOF
[cloud]
localhost

[guest]

[cloud:vars]
ansible_connection=local

[guest:vars]
ansible_user="$SSH_USER"
ansible_private_key_file="$SSH_KEY"
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

[all:vars]
ansible_python_interpreter=/usr/bin/python3
EOF

greenprint "Prepare ansible.cfg"
export ANSIBLE_CONFIG="${PWD}/playbooks/ansible.cfg"

case "$IMAGE_TYPE" in
    "ami")
        greenprint "Build $TEST_OS $IMAGE_TYPE image"
        AMI_NAME="bootc-bib-${TEST_OS}-${ARCH}-${QUAY_REPO_TAG}"
        AWS_BUCKET_NAME="bootc-bib-images"
        sudo podman run \
            --rm \
            -it \
            --privileged \
            --pull=newer \
            --security-opt label=type:unconfined_t \
            --env AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
            --env AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
            quay.io/centos-bootc/bootc-image-builder:latest \
            --type ami \
            --target-arch "$ARCH" \
            --aws-ami-name "$AMI_NAME" \
            --aws-bucket "$AWS_BUCKET_NAME" \
            --aws-region "$AWS_REGION" \
            "$TEST_IMAGE_URL"

        greenprint "Get uploaded AMI ID and snapshot ID"
        AMI_ID=$(
            aws ec2 describe-images \
                --filters "Name=name,Values=${AMI_NAME}" \
                --query 'Images[*].ImageId' \
                --output text
        )

        greenprint "Deploy $IMAGE_TYPE instance"
        ansible-playbook -v \
            -i "$INVENTORY_FILE" \
            -e ssh_key_pub="$SSH_KEY_PUB" \
            -e inventory_file="$INVENTORY_FILE" \
            -e ami_id="$AMI_ID" \
            "playbooks/deploy-aws.yaml"
        ;;
    "qcow2")
        greenprint "Build $TEST_OS $IMAGE_TYPE image"
        mkdir output
        sudo podman run \
            --rm \
            -it \
            --privileged \
            --pull=newer \
            --security-opt label=type:unconfined_t \
            -v "$(pwd)/output":/output \
            quay.io/centos-bootc/bootc-image-builder:latest \
            --type qcow2 \
            --target-arch "$ARCH" \
            "$TEST_IMAGE_URL"

        sudo mv output/qcow2/disk.qcow2 /var/lib/libvirt/images && sudo rm -rf output

        greenprint "Deploy $IMAGE_TYPE instance"
        ansible-playbook -v \
            -i "$INVENTORY_FILE" \
            -e ssh_key_pub="$SSH_KEY_PUB" \
            -e inventory_file="$INVENTORY_FILE" \
            -e bib="true" \
            "playbooks/deploy-libvirt.yaml"
        ;;
    *)
        redprint "Variable IMAGE_TYPE has to be defined"
        exit 1
        ;;
esac

greenprint "Run ostree checking test on $PLATFORM instance"
ansible-playbook -v \
    -i "$INVENTORY_FILE" \
    -e bootc_image="$TEST_IMAGE_URL" \
    -e transient_root="$TRANSIENT_ROOT" \
    playbooks/check-system.yaml

greenprint "Create upgrade Containerfile"
tee "$UPGRADE_CONTAINERFILE" > /dev/null << EOF
FROM "$TEST_IMAGE_URL"
RUN dnf -y install wget && \
    dnf -y clean all
EOF

greenprint "Build $TEST_OS upgrade container image"
podman build --platform "$BUILD_PLATFORM" -t "${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" -f "$UPGRADE_CONTAINERFILE" .
greenprint "Push $TEST_OS upgrade container image"
podman push "${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" "$TEST_IMAGE_URL"

greenprint "Upgrade $TEST_OS system"
ansible-playbook -v \
    -i "$INVENTORY_FILE" \
    playbooks/upgrade.yaml

greenprint "Run ostree checking test after upgrade on $PLATFORM instance"
ansible-playbook -v \
    -i "$INVENTORY_FILE" \
    -e bootc_image="$TEST_IMAGE_URL" \
    -e transient_root="$TRANSIENT_ROOT" \
    -e upgrade="true" \
    playbooks/check-system.yaml

greenprint "Terminate $PLATFORM instance and deregister AMI"
ansible-playbook -v \
    -i "$INVENTORY_FILE" \
    -e platform="$PLATFORM" \
    playbooks/remove.yaml

greenprint "Clean up"
rm -rf auth.json rhel-9-4.repo
unset ANSIBLE_CONFIG

greenprint "🎉 All tests passed."
exit 0
