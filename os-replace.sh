#!/bin/bash
set -exuo pipefail

# Colorful timestamped output.
function greenprint {
    echo -e "\033[1;32m[$(date -Isecond)] ${1}\033[0m"
}

function redprint {
    echo -e "\033[1;31m[$(date -Isecond)] ${1}\033[0m"
}

function retry {
    n=0
    until [ "$n" -ge 3 ]
    do
       "$@" && break
       n=$((n+1))
       sleep 10
    done
}

TEMPDIR=$(mktemp -d)
trap 'rm -rf -- "$TEMPDIR"' EXIT

# SSH configurations
SSH_KEY=${TEMPDIR}/id_rsa
ssh-keygen -f "${SSH_KEY}" -N "" -q -t rsa-sha2-256 -b 2048
SSH_KEY_PUB="${SSH_KEY}.pub"

LAYERED_IMAGE="${LAYERED_IMAGE-cloud-init}"
LAYERED_DIR="examples/$LAYERED_IMAGE"
INSTALL_CONTAINERFILE="$LAYERED_DIR/Containerfile"
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
        sed "s/REPLACE_ME/${DOWNLOAD_NODE}/; s/REPLACE_COMPOSE_ID/${CURRENT_COMPOSE_RHEL94}/" files/rhel-9-4.template | tee "${LAYERED_DIR}"/rhel-9-4.repo > /dev/null
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
        ;;
    "fedora-eln")
        IMAGE_NAME="fedora-bootc"
        TIER1_IMAGE_URL="quay.io/centos-bootc/${IMAGE_NAME}:eln"
        TIER1_IMAGE_URL="${IMAGE_URL-$TIER1_IMAGE_URL}"
        SSH_USER="fedora"
        ADD_REPO=""
        ;;
    *)
        redprint "Variable TEST_OS has to be defined"
        exit 1
        ;;
esac

if [[ ${AIR_GAPPED-} -eq 1 ]];then
    if [[ ${PLATFORM} == "libvirt" ]]; then
        AIR_GAPPED_DIR="$TEMPDIR"/virtiofs
        mkdir "$AIR_GAPPED_DIR"
    else
        AIR_GAPPED=0
    fi
else
    AIR_GAPPED=0
    AIR_GAPPED_DIR=""
fi

VERSION_ID=$(skopeo inspect --tls-verify=false "docker://${TIER1_IMAGE_URL}" | jq -r '.Labels."redhat.version-id"')
TEST_IMAGE_NAME="${IMAGE_NAME}-os_replace"
TEST_IMAGE_URL="quay.io/redhat_emp1/${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}"

[[ $- =~ x ]] && debug=1 && set +x
sed "s/REPLACE_ME/${QUAY_SECRET}/g" files/auth.template | tee "${LAYERED_DIR}"/auth.json > /dev/null
[[ $debug == 1 ]] && set -x
greenprint "Create $TEST_OS installation Containerfile"
sed -i "s|^FROM.*|FROM $TIER1_IMAGE_URL\n$ADD_REPO|" "$INSTALL_CONTAINERFILE"
USER_CONFIG=""
if [[ "$PLATFORM" == "libvirt" ]] && [[ "$LAYERED_IMAGE" != "cloud-init" ]] && [[ "$LAYERED_IMAGE" != "useradd-ssh" ]]; then
   SSH_USER="root"
   SSH_KEY_PUB_CONTENT=$(cat "${SSH_KEY_PUB}")
   USER_CONFIG="RUN mkdir -p /usr/etc-system/ && echo 'AuthorizedKeysFile /usr/etc-system/%u.keys' >> /etc/ssh/sshd_config.d/30-auth-system.conf && \
       echo \"$SSH_KEY_PUB_CONTENT\" > /usr/etc-system/root.keys && chmod 0600 /usr/etc-system/root.keys"
   REPLACE_CLOUD_USER=""
elif [[ "$PLATFORM" == "aws" ]] && [[ "$LAYERED_IMAGE" != "cloud-init" ]]; then
   USER_CONFIG="RUN dnf -y install cloud-init && \
       ln -s ../cloud-init.target /usr/lib/systemd/system/default.target.wants"
elif [[ "$LAYERED_IMAGE" == "useradd-ssh" ]]; then
   sed -i "s|exampleuser|$SSH_USER|g" "$INSTALL_CONTAINERFILE"
fi
tee -a "$INSTALL_CONTAINERFILE" > /dev/null << EOF
RUN dnf -y clean all
COPY auth.json /etc/ostree/auth.json
$USER_CONFIG
$REPLACE_CLOUD_USER
EOF

greenprint "Check $TEST_OS installation Containerfile"
cat "$INSTALL_CONTAINERFILE"

greenprint "Login quay.io"
podman login -u "${QUAY_USERNAME}" -p "${QUAY_PASSWORD}" quay.io

retry podman pull "$TIER1_IMAGE_URL"

greenprint "Build $TEST_OS installation container image"
if [[ "$LAYERED_IMAGE" == "useradd-ssh" ]]; then
    retry podman build --build-arg "sshpubkey=$(cat "${SSH_KEY_PUB}")" -t "${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" "$LAYERED_DIR"
else
    retry podman build -t "${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" "$LAYERED_DIR"
fi

greenprint "Push $TEST_OS installation container image"
retry podman push "${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" "$TEST_IMAGE_URL"

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

greenprint "Deploy $PLATFORM instance"
ansible-playbook -v \
    -i "$INVENTORY_FILE" \
    -e ssh_key_pub="$SSH_KEY_PUB" \
    -e inventory_file="$INVENTORY_FILE" \
    -e air_gapped_dir="$AIR_GAPPED_DIR" \
    -e layered_image="$LAYERED_IMAGE" \
    "playbooks/deploy-${PLATFORM}.yaml"

greenprint "Install $TEST_OS bootc system"
ansible-playbook -v \
    -i "$INVENTORY_FILE" \
    -e test_image_url="$TEST_IMAGE_URL" \
    playbooks/install.yaml

if [[ "$PLATFORM" == "libvirt" ]] && [[ "$LAYERED_IMAGE" == "qemu-guest-agent" ]]; then
    virsh guestinfo bootc-"$TEST_OS"
fi

greenprint "Run ostree checking test on $PLATFORM instance"
ansible-playbook -v \
    -i "$INVENTORY_FILE" \
    -e bootc_image="$TEST_IMAGE_URL" \
    -e layered_image="$LAYERED_IMAGE" \
    -e image_label_version_id="$VERSION_ID" \
    playbooks/check-system.yaml

greenprint "Create upgrade Containerfile"
tee "$UPGRADE_CONTAINERFILE" > /dev/null << EOF
FROM "$TEST_IMAGE_URL"
RUN dnf -y install wget && \
    dnf -y clean all
EOF

greenprint "Build $TEST_OS upgrade container image"
retry podman build -t "${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" -f "$UPGRADE_CONTAINERFILE" .
greenprint "Push $TEST_OS upgrade container image"
retry podman push "${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" "$TEST_IMAGE_URL"

if [[ ${AIR_GAPPED-} -eq 1 ]]; then
    retry skopeo copy docker://"$TEST_IMAGE_URL" dir://"$AIR_GAPPED_DIR"
    BOOTC_IMAGE="/mnt"
else
    BOOTC_IMAGE="$TEST_IMAGE_URL"
fi

greenprint "Upgrade $TEST_OS system"
ansible-playbook -v \
    -i "$INVENTORY_FILE" \
    -e air_gapped_dir="$AIR_GAPPED_DIR" \
    playbooks/upgrade.yaml

greenprint "Run ostree checking test after upgrade on $PLATFORM instance"
ansible-playbook -v \
    -i "$INVENTORY_FILE" \
    -e bootc_image="$BOOTC_IMAGE" \
    -e image_label_version_id="$VERSION_ID" \
    -e upgrade="true" \
    playbooks/check-system.yaml

greenprint "Rollback $TEST_OS system"
ansible-playbook -v \
    -i "$INVENTORY_FILE" \
    -e air_gapped_dir="$AIR_GAPPED_DIR" \
    playbooks/rollback.yaml

greenprint "Remove $PLATFORM instance"
ansible-playbook -v \
    -i "$INVENTORY_FILE" \
    -e platform="$PLATFORM" \
    playbooks/remove.yaml

greenprint "Clean up"
rm -rf auth.json rhel-9-4.repo
unset ANSIBLE_CONFIG

greenprint "🎉 All tests passed."
exit 0
