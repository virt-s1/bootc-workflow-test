#!/bin/bash
set -exuo pipefail

source tools/shared_lib.sh
dump_runner
image_inspect

TEMPDIR=$(mktemp -d)
trap 'rm -rf -- "$TEMPDIR"' EXIT

# SSH configurations
SSH_KEY=${TEMPDIR}/id_rsa
ssh-keygen -f "${SSH_KEY}" -N "" -q -t rsa-sha2-256 -b 2048
SSH_KEY_PUB="${SSH_KEY}.pub"

if [[ ${TIER1_IMAGE_URL} =~ bootc-image-builder ]]; then
    BIB_IMAGE_URL=$TIER1_IMAGE_URL
    TIER1_IMAGE_URL=${RHEL_REGISTRY_URL}/rhel9-rhel_bootc:rhel-${VERSION}
else
    BIB_IMAGE_URL="${BIB_IMAGE_URL:-quay.io/centos-bootc/bootc-image-builder:latest}"
fi
LAYERED_IMAGE="${LAYERED_IMAGE-cloud-init}"
LAYERED_DIR="examples/$LAYERED_IMAGE"
INSTALL_CONTAINERFILE="$LAYERED_DIR/Containerfile"
UPGRADE_CONTAINERFILE=${TEMPDIR}/Containerfile.upgrade
QUAY_REPO_TAG="${QUAY_REPO_TAG:-$(tr -dc a-z0-9 < /dev/urandom | head -c 4 ; echo '')}"
INVENTORY_FILE="${TEMPDIR}/inventory"

REPLACE_CLOUD_USER=""

greenprint "Login quay.io"
sudo podman login -u "${QUAY_USERNAME}" -p "${QUAY_PASSWORD}" quay.io

case "$REDHAT_ID" in
    "rhel")
        # work with old TEST_OS variable value rhel-9-x
        TEST_OS=$(echo "${REDHAT_ID}-${REDHAT_VERSION_ID}" | sed 's/\./-/')
        SSH_USER="cloud-user"
        sed "s/REPLACE_ME/${DOWNLOAD_NODE}/; s/REPLACE_COMPOSE_ID/${CURRENT_COMPOSE_ID}/" files/rhel-9-y.template | tee "${LAYERED_DIR}"/rhel-9-y.repo > /dev/null
        ADD_REPO="COPY rhel-9-y.repo /etc/yum.repos.d/rhel-9-y.repo"
        ADD_RHC="RUN dnf install -y rhc"
        if [[ "$PLATFORM" == "aws" ]]; then
            SSH_USER="ec2-user"
            REPLACE_CLOUD_USER='RUN sed -i "s/name: cloud-user/name: ec2-user/g" /etc/cloud/cloud.cfg'
        fi
        greenprint "Prepare cloud-init file"
        tee -a "playbooks/user-data" > /dev/null << EOF
#cloud-config
yum_repos:
  rhel-9y-baseos:
    name: rhel-9y-baseos
    baseurl: http://${DOWNLOAD_NODE}/rhel-9/composes/RHEL-9/${CURRENT_COMPOSE_ID}/compose/BaseOS/\$basearch/os/
    enabled: true
    gpgcheck: false
  rhel-9y-appstream:
    name: rhel-9y-appstream
    baseurl: http://${DOWNLOAD_NODE}/rhel-9/composes/RHEL-9/${CURRENT_COMPOSE_ID}/compose/AppStream/\$basearch/os/
    enabled: true
    gpgcheck: false
EOF
        GUEST_ID_DC70="rhel9_64Guest"
        ;;
    "centos")
        # work with old TEST_OS variable value centos-stream-9
        TEST_OS=$(echo "${REDHAT_ID}-${REDHAT_VERSION_ID}" | sed 's/-/-stream-/')
        SSH_USER="cloud-user"
        ADD_REPO=""
        ADD_RHC=""
        if [[ "$PLATFORM" == "aws" ]]; then
            SSH_USER="ec2-user"
            REPLACE_CLOUD_USER='RUN sed -i "s/name: cloud-user/name: ec2-user/g" /etc/cloud/cloud.cfg'
        fi
        GUEST_ID_DC70="centos9_64Guest"
        ;;
    "fedora")
        SSH_USER="fedora"
        ADD_REPO=""
        ADD_RHC=""
        ;;
    *)
        redprint "Variable TIER1_IMAGE_URL is not supported"
        exit 1
        ;;
esac

TEST_IMAGE_NAME="bootc-workflow-test"
TEST_IMAGE_URL="quay.io/redhat_emp1/${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}"
LOCAL_IMAGE_URL="localhost/${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}"

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


greenprint "Create ${TEST_OS} installation Containerfile"
sed -i "s|^FROM.*|FROM $TIER1_IMAGE_URL\n$ADD_REPO\n$ADD_RHC|" "$INSTALL_CONTAINERFILE"
tee -a "$INSTALL_CONTAINERFILE" > /dev/null << EOF
RUN dnf -y clean all
$REPLACE_CLOUD_USER
EOF

if [[ "$IMAGE_TYPE" == "vmdk" ]]; then
    greenprint "Install cloud-init for vmdk image"
    sed -i "s/open-vm-tools/cloud-init open-vm-tools/" "$INSTALL_CONTAINERFILE"
fi

greenprint "Check $TEST_OS installation Containerfile"
cat "$INSTALL_CONTAINERFILE"

greenprint "Build $TEST_OS installation container image"
sudo podman build --platform "$BUILD_PLATFORM" --tls-verify=false --retry=5 --retry-delay=10 -t "${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" "$LAYERED_DIR"

[[ $- =~ x ]] && debug=1 && set +x
sed "s/REPLACE_ME/${QUAY_SECRET}/g" files/auth.template | tee auth.json > /dev/null
[[ $debug == 1 ]] && set -x
sudo podman build --platform "$BUILD_PLATFORM" --tls-verify=false --retry=5 --retry-delay=10 --from "localhost/${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" --secret id=creds,src=./auth.json -t "${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" examples/container-auth

greenprint "Push $TEST_OS installation container image"
sudo podman push --tls-verify=false --quiet "${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" "$TEST_IMAGE_URL"

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
        AWS_BUCKET_NAME="bootc-bib-images-test"
        sudo podman run \
            --rm \
            -it \
            --privileged \
            --pull=newer \
            --tls-verify=false \
            --security-opt label=type:unconfined_t \
            -v /var/lib/containers/storage:/var/lib/containers/storage \
            --env AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
            --env AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
            "$BIB_IMAGE_URL" \
            --type ami \
            --target-arch "$ARCH" \
            --aws-ami-name "$AMI_NAME" \
            --aws-bucket "$AWS_BUCKET_NAME" \
            --aws-region "$AWS_REGION" \
            --local \
            "$LOCAL_IMAGE_URL"

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
            -e test_os="$TEST_OS" \
            -e ssh_key_pub="$SSH_KEY_PUB" \
            -e inventory_file="$INVENTORY_FILE" \
            -e ami_id="$AMI_ID" \
            "playbooks/deploy-aws.yaml"
        ;;
    "qcow2"|"raw")
        greenprint "Build $TEST_OS $IMAGE_TYPE image"
        mkdir -p output
        sudo podman run \
            --rm \
            -it \
            --privileged \
            --pull=newer \
            --tls-verify=false \
            --security-opt label=type:unconfined_t \
            -v "$(pwd)/output":/output \
            -v /var/lib/containers/storage:/var/lib/containers/storage \
            "$BIB_IMAGE_URL" \
            --type "$IMAGE_TYPE" \
            --target-arch "$ARCH" \
            --chown "$(id -u "$(whoami)"):$(id -g "$(whoami)")" \
            --local \
            "$LOCAL_IMAGE_URL"

        if [[ "$IMAGE_TYPE" == "raw" ]]; then
            qemu-img convert -f raw output/image/disk.raw -O qcow2 output/image/disk.qcow2
            sudo mv output/image/disk.qcow2 /var/lib/libvirt/images && sudo rm -rf output
        else
            sudo mv output/qcow2/disk.qcow2 /var/lib/libvirt/images && sudo rm -rf output
        fi

        greenprint "Deploy $IMAGE_TYPE instance"
        ansible-playbook -v \
            -i "$INVENTORY_FILE" \
            -e test_os="$TEST_OS" \
            -e ssh_key_pub="$SSH_KEY_PUB" \
            -e ssh_user="$SSH_USER" \
            -e inventory_file="$INVENTORY_FILE" \
            -e bib="true" \
            "playbooks/deploy-libvirt.yaml"
        ;;
    "vmdk")
        mkdir -p output

        greenprint "Build $TEST_OS $IMAGE_TYPE image"
        sudo podman run \
            --rm \
            -it \
            --privileged \
            --pull=newer \
            --tls-verify=false \
            --security-opt label=type:unconfined_t \
            -v "$(pwd)/output":/output \
            -v /var/lib/containers/storage:/var/lib/containers/storage \
            "$BIB_IMAGE_URL" \
            --type vmdk \
            --target-arch "$ARCH" \
            --local \
            "$LOCAL_IMAGE_URL"

        greenprint "Deploy $IMAGE_TYPE instance"
        DATACENTER_70="Datacenter7.0"
        DATASTORE_70="datastore-80"
        DATACENTER_70_POOL="/Datacenter7.0/host/Automation/Resources"
        FIRMWARE_LIST=( \
            "bios" \
            "efi" \
        )
        RND_LINE=$((RANDOM % 2))
        FIRMWARE="${FIRMWARE_LIST[$RND_LINE]}"
        greenprint "📋 Random run firmware: $FIRMWARE"
        VMDK_FILENAME="${TEST_OS}-${ARCH}-${QUAY_REPO_TAG}"
        VSPHERE_VM_NAME="bib-${FIRMWARE}-${VMDK_FILENAME}-v70"

        greenprint "📋 Rename vmdk file name"
        sudo mv output/vmdk/disk.vmdk "output/vmdk/${VMDK_FILENAME}.vmdk"
        sudo chmod 644 "output/vmdk/${VMDK_FILENAME}.vmdk"
        sudo chown "$(whoami)" "output/vmdk/${VMDK_FILENAME}.vmdk"

        greenprint "📋 Uploading vmdk image to vsphere datacenter 7.0"
        govc import.vmdk \
            -dc="${DATACENTER_70}" \
            -ds="${DATASTORE_70}" \
            -pool="${DATACENTER_70_POOL}" \
            "output/vmdk/${VMDK_FILENAME}.vmdk" > /dev/null
        sudo rm -rf output

        greenprint "📋 Generate user-data and meta-data"
        envsubst > metadata.yaml <<EOF
instance-id: bib-${QUAY_REPO_TAG}
local-hostname: bib-${TEST_OS}
EOF
        cat metadata.yaml

        envsubst > userdata.yaml <<EOF
#cloud-config
users:
  - default
  - name: $SSH_USER
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo, wheel
    lock_passwd: true
    ssh_authorized_keys:
      - $(cat "$SSH_KEY_PUB")
EOF
        cat userdata.yaml

        METADATA=$(gzip -c9 <metadata.yaml | { base64 -w0 2>/dev/null || base64; })
        USERDATA=$(gzip -c9 <userdata.yaml | { base64 -w0 2>/dev/null || base64; })

        greenprint "📋 Create vm in vsphere datacenter 7.0"
        govc vm.create \
            -dc="$DATACENTER_70" \
            -ds="$DATASTORE_70" \
            -pool="$DATACENTER_70_POOL" \
            -net="VM Network" \
            -net.adapter=vmxnet3 \
            -disk.controller=pvscsi \
            -on=false \
            -c=2 \
            -m=4096 \
            -g="$GUEST_ID_DC70" \
            -firmware="$FIRMWARE" \
            "$VSPHERE_VM_NAME"

        govc vm.change \
            -dc="$DATACENTER_70" \
            -vm="$VSPHERE_VM_NAME" \
            -e guestinfo.metadata="$METADATA" \
            -e guestinfo.metadata.encoding="gzip+base64" \
            -e guestinfo.userdata="$USERDATA" \
            -e guestinfo.userdata.encoding="gzip+base64" \

        govc vm.disk.attach \
            -dc="$DATACENTER_70" \
            -ds="$DATASTORE_70" \
            -vm="$VSPHERE_VM_NAME" \
            -link=false \
            -disk="${VMDK_FILENAME}/${VMDK_FILENAME}.vmdk"

        govc vm.power \
            -on \
            -dc="$DATACENTER_70" \
            "$VSPHERE_VM_NAME"

        GUEST_ADDRESS=$(govc vm.ip -v4 -dc="$DATACENTER_70" -wait=10m "$VSPHERE_VM_NAME")
        greenprint "🛃 VM IP address is: $GUEST_ADDRESS"
        sed -i "/\[guest\]/a $GUEST_ADDRESS" "$INVENTORY_FILE"

        wait_for_ssh_up () {
            SSH_OPTIONS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
            SSH_STATUS=$(sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" ${SSH_USER}@"${1}" '/bin/bash -c "echo -n READY"')
            if [[ $SSH_STATUS == READY ]]; then
                echo 1
            else
                echo 0
            fi
        }

        greenprint "🛃 Checking for SSH is ready to go"
        for _ in $(seq 0 30); do
            RESULT=$(wait_for_ssh_up "$GUEST_ADDRESS")
            if [[ $RESULT == 1 ]]; then
                echo "SSH is ready now! 🥳"
                break
            fi
            sleep 10
        done

        greenprint "Clean up userdata.yaml and metadata.yaml"
        rm -f userdata.yaml metadata.yaml
        ;;
    "to-disk")
        greenprint "💾 Create disk.raw"
        sudo truncate -s 10G disk.raw

        greenprint "bootc install to disk.raw"
        sudo podman run \
            --rm \
            --privileged \
            --pid=host \
            --security-opt label=type:unconfined_t \
            -v /var/lib/containers:/var/lib/containers \
            -v /dev:/dev \
            -v .:/output \
            "$TEST_IMAGE_URL" \
            bootc install to-disk --generic-image --via-loopback /output/disk.raw

        sudo qemu-img convert -f raw ./disk.raw -O qcow2 "/var/lib/libvirt/images/disk.qcow2"

        greenprint "Deploy $IMAGE_TYPE instance"
        ansible-playbook -v \
            -i "$INVENTORY_FILE" \
            -e test_os="$TEST_OS" \
            -e ssh_key_pub="$SSH_KEY_PUB" \
            -e ssh_user="$SSH_USER" \
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
    -e test_os="$TEST_OS" \
    -e bootc_image="$TEST_IMAGE_URL" \
    -e layered_image="$LAYERED_IMAGE" \
    -e image_label_version_id="$REDHAT_VERSION_ID" \
    playbooks/check-system.yaml

greenprint "Create upgrade Containerfile"
tee "$UPGRADE_CONTAINERFILE" > /dev/null << EOF
FROM "$TEST_IMAGE_URL"
RUN dnf -y install wget && \
    dnf -y clean all
EOF

greenprint "Build $TEST_OS upgrade container image"
sudo podman build --platform "$BUILD_PLATFORM" --tls-verify=false --retry=5 --retry-delay=10 -t "${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" -f "$UPGRADE_CONTAINERFILE" .
greenprint "Push $TEST_OS upgrade container image"
sudo podman push --tls-verify=false --quiet "${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" "$TEST_IMAGE_URL"

greenprint "Upgrade $TEST_OS system"
ansible-playbook -v \
    -i "$INVENTORY_FILE" \
    -e bootc_image="$TEST_IMAGE_URL" \
    playbooks/upgrade.yaml

greenprint "Run ostree checking test after upgrade on $PLATFORM instance"
ansible-playbook -v \
    -i "$INVENTORY_FILE" \
    -e test_os="$TEST_OS" \
    -e bootc_image="$TEST_IMAGE_URL" \
    -e image_label_version_id="$REDHAT_VERSION_ID" \
    -e upgrade="true" \
    playbooks/check-system.yaml

greenprint "Rollback $TEST_OS system"
ansible-playbook -v \
    -i "$INVENTORY_FILE" \
    playbooks/rollback.yaml

if [[ "$IMAGE_TYPE" == vmdk ]]; then
    greenprint "Delete $VSPHERE_VM_NAME from vsphere"
    govc vm.destroy -dc="${DATACENTER_70}" "${VSPHERE_VM_NAME}"
else
    greenprint "Terminate $PLATFORM instance and deregister AMI"
    ansible-playbook -v \
        -i "$INVENTORY_FILE" \
        -e platform="$PLATFORM" \
        playbooks/remove.yaml
fi

greenprint "Clean up"
rm -rf auth.json "${LAYERED_DIR}/rhel-9-y.repo"
unset ANSIBLE_CONFIG

greenprint "🎉 All tests passed."
exit 0
