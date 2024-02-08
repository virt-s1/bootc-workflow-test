#!/bin/bash
set -euo pipefail

# Prepare running environment
./tools/setup.sh
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
SSH_USER="admin"
SSH_KEY=${TEMPDIR}/id_rsa
ssh-keygen -f "${SSH_KEY}" -N "" -q -t rsa-sha2-256 -b 2048
SSH_KEY_PUB="${SSH_KEY}.pub"
SSH_KEY_PUB_CONTENT="$(cat "$SSH_KEY_PUB")"

INSTALL_CONTAINERFILE=${TEMPDIR}/Containerfile.install
UPGRADE_CONTAINERFILE=${TEMPDIR}/Containerfile.upgrade
QUAY_REPO_TAG="${QUAY_REPO_TAG:-$(tr -dc a-z0-9 < /dev/urandom | head -c 4 ; echo '')}"
INVENTORY_FILE="${TEMPDIR}/inventory"
KS_FILE=${TEMPDIR}/ks.cfg
GUEST_IP="192.168.100.50"
FIRMWARE=${FIRMWARE:-"bios"}
PART_LVM=${PART_LVM:-"false"}

case "$TEST_OS" in
    "rhel-9-4")
        IMAGE_NAME="rhel9-rhel_bootc"
        TIER1_IMAGE_URL="${RHEL_REGISTRY_URL}/${IMAGE_NAME}:rhel-9.4"
        sed "s/REPLACE_ME/${DOWNLOAD_NODE}/g" files/rhel-9-4.template | tee rhel-9-4.repo > /dev/null
        ADD_REPO="COPY rhel-9-4.repo /etc/yum.repos.d/rhel-9-4.repo"
        BOOT_LOCATION="http://${DOWNLOAD_NODE}/rhel-9/nightly/RHEL-9/latest-RHEL-9.4.0/compose/BaseOS/${ARCH}/os/"
        OS_VARIANT="rhel9-unknown"
        BOOT_ARGS="uefi"
        CUT_DIRS=8
        ;;
    "centos-stream-9")
        IMAGE_NAME=${IMAGE_NAME:-"centos-bootc"}
        TIER1_IMAGE_URL="quay.io/centos-bootc/${IMAGE_NAME}:stream9"
        ADD_REPO=""
        CURRENT_COMPOSE_CS9=$(curl -s "https://composes.stream.centos.org/production/" | grep -ioE ">CentOS-Stream-9-.*/<" | tr -d '>/<' | tail -1)
        BOOT_LOCATION="https://composes.stream.centos.org/production/${CURRENT_COMPOSE_CS9}/compose/BaseOS/${ARCH}/os/"
        OS_VARIANT="centos-stream9"
        BOOT_ARGS="uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no"
        CUT_DIRS=6
        ;;
    "fedora-eln")
        IMAGE_NAME="fedora-bootc"
        TIER1_IMAGE_URL="quay.io/centos-bootc/${IMAGE_NAME}:eln"
        ADD_REPO=""
        BOOT_LOCATION="https://odcs.fedoraproject.org/composes/production/latest-Fedora-ELN/compose/BaseOS/${ARCH}/os/"
        OS_VARIANT="fedora-rawhide"
        BOOT_ARGS="uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no"
        CUT_DIRS=7
        ;;
    *)
        redprint "Variable TEST_OS has to be defined"
        exit 1
        ;;
esac

TEST_IMAGE_NAME="${IMAGE_NAME}-os_replace"
TEST_IMAGE_URL="quay.io/redhat_emp1/${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}"

greenprint "Generate auth.json for registry auth"
sed "s/REPLACE_ME/$QUAY_SECRET/g" files/auth.template | tee auth.json > /dev/null

greenprint "Create $TEST_OS installation Containerfile"
tee "$INSTALL_CONTAINERFILE" > /dev/null << EOF
FROM "$TIER1_IMAGE_URL"
$ADD_REPO
RUN dnf -y install python3 && \
    dnf -y clean all
COPY auth.json /etc/ostree/auth.json
EOF

greenprint "Check $TEST_OS installation Containerfile"
cat "$INSTALL_CONTAINERFILE"

greenprint "Login quay.io"
podman login -u "${QUAY_USERNAME}" -p "${QUAY_PASSWORD}" quay.io

greenprint "Build $TEST_OS installation container image"
podman build -t "${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" -f "$INSTALL_CONTAINERFILE" .

greenprint "Push $TEST_OS installation container image"
podman push "${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" "$TEST_IMAGE_URL"

greenprint "💾 Create vm qcow2 files for virt install"
LIBVIRT_UEFI_IMAGE_PATH="/var/lib/libvirt/images/bootc-${TEST_OS}-${FIRMWARE}.qcow2"
sudo qemu-img create -f qcow2 "$LIBVIRT_UEFI_IMAGE_PATH" 20G

greenprint "📑 Generate kickstart file"
tee "$KS_FILE" > /dev/null << STOPHERE
text
network --bootproto=dhcp --device=link --activate --onboot=on

rootpw --lock --iscrypted locked
user --name=${SSH_USER} --groups=wheel --iscrypted
sshkey --username=${SSH_USER} "$SSH_KEY_PUB_CONTENT"

ostreecontainer --url $TEST_IMAGE_URL --no-signature-verification

poweroff

%pre
#!/bin/sh
curl -kLO https://${CERT_URL}/certs/2022-IT-Root-CA.pem --output-dir /etc/pki/ca-trust/source/anchors
update-ca-trust
cat > /etc/ostree/auth.json <<EOF
{
  "auths": {
    "quay.io": {
      "auth": "$QUAY_SECRET"
    }
  }
}
EOF
%end

%post --log=/var/log/anaconda/post-install.log --erroronfail
# no sudo password for user admin
echo -e 'admin\tALL=(ALL)\tNOPASSWD: ALL' >> /etc/sudoers
%end

zerombr
clearpart --all --initlabel --disklabel=gpt
STOPHERE

greenprint "Configure console log file"
VIRT_LOG="/tmp/${TEST_OS}-${FIRMWARE}-console.log"
sudo rm -f "$VIRT_LOG"
touch "$VIRT_LOG"
sudo chown qemu:qemu "$VIRT_LOG"

# Test BIOS scenario
if [[ "$FIRMWARE" == bios ]]; then

    if [[ "$PART_LVM" == "true" ]]; then
        greenprint "LVM partition setup"
        tee -a "$KS_FILE" > /dev/null << EOF
part biosboot --size=1 --fstype=biosboot
part /boot --size=1000 --fstype=ext4 --label=boot
part pv.01 --grow
volgroup bootc pv.01
logvol / --vgname=bootc --fstype=xfs --size=10000 --name=root
EOF
    else
        greenprint "Partition setup"
        echo "autopart --nohome --noswap --type=plain --fstype=xfs" >> "$KS_FILE"
    fi

    greenprint "Download boot.iso"
    curl -O "${BOOT_LOCATION}images/boot.iso"
    sudo mv boot.iso /var/lib/libvirt/images
    LOCAL_BOOT_LOCATION="/var/lib/libvirt/images/boot.iso"

    greenprint "Install $TEST_OS via anaconda on BIOS VM"
    sudo virt-install --initrd-inject="$KS_FILE" \
                      --extra-args="inst.ks=file:/ks.cfg console=ttyS0,115200" \
                      --name="bootc-${TEST_OS}-${FIRMWARE}"\
                      --disk path="$LIBVIRT_UEFI_IMAGE_PATH",format=qcow2 \
                      --ram 3072 \
                      --vcpus 2 \
                      --network network=integration,mac=34:49:22:B0:83:30 \
                      --os-variant "$OS_VARIANT" \
                      --location "$LOCAL_BOOT_LOCATION" \
                      --console pipe,source.path="$VIRT_LOG" \
                      --nographics \
                      --noautoconsole \
                      --wait=-1 \
                      --noreboot
# Test UEFI scenario
else
    if [[ "$PART_LVM" == "true" ]]; then
        greenprint "LVM partition setup"
        tee -a "$KS_FILE" > /dev/null << EOF
part /boot/efi --size=100 --fstype=efi
part /boot --size=1000 --fstype=ext4 --label=boot
part pv.01 --grow
volgroup bootc pv.01
logvol / --vgname=bootc --fstype=xfs --size=10000 --name=root
EOF
    else
        greenprint "Partition setup"
        echo "autopart --nohome --noswap --type=plain --fstype=xfs" >> "$KS_FILE"
    fi

    greenprint "📥 Install httpd and configure HTTP boot server"
    sudo dnf install -y httpd
    sudo systemctl enable --now httpd.service

    HTTPD_PATH="/var/www/html"
    GRUB_CFG="${HTTPD_PATH}/httpboot/EFI/BOOT/grub.cfg"

    sudo rm -rf "${HTTPD_PATH}/httpboot"
    sudo mkdir -p "${HTTPD_PATH}/httpboot"

    greenprint "📥 Download HTTP boot required files"
    REQUIRED_FOLDERS=( "EFI" "images" )
    for i in "${REQUIRED_FOLDERS[@]}"
    do
        sudo wget -q --inet4-only -r --no-parent -e robots=off -nH --cut-dirs="$CUT_DIRS" --reject "index.html*" --reject "boot.iso" "${BOOT_LOCATION}${i}/" -P "${HTTPD_PATH}/httpboot/"
    done

    greenprint "📝 Update grub.cfg to work with HTTP boot"
    sudo tee -a "${GRUB_CFG}" > /dev/null << EOF
menuentry 'Install Red Hat Enterprise Linux for Bootc' --class fedora --class gnu-linux --class gnu --class os {
        linuxefi /httpboot/images/pxeboot/vmlinuz inst.stage2=http://192.168.100.1/httpboot inst.ks=http://192.168.100.1/ks.cfg inst.text console=ttyS0,115200
        initrdefi /httpboot/images/pxeboot/initrd.img
}
EOF
    sudo sed -i 's/default="1"/default="3"/' "${GRUB_CFG}"
    sudo sed -i 's/timeout=60/timeout=10/' "${GRUB_CFG}"

    sudo mv "$KS_FILE" "$HTTPD_PATH"

    greenprint "👿 Running restorecon on /var/www/html"
    sudo restorecon -Rv /var/www/html/

    greenprint "Install $TEST_OS via anaconda on UEFI VM"
    sudo virt-install --name="bootc-${TEST_OS}-${FIRMWARE}"\
                      --disk path="$LIBVIRT_UEFI_IMAGE_PATH",format=qcow2 \
                      --ram 3072 \
                      --vcpus 2 \
                      --network network=integration,mac=34:49:22:B0:83:30 \
                      --boot "$BOOT_ARGS" \
                      --pxe \
                      --os-variant "$OS_VARIANT" \
                      --console pipe,source.path="$VIRT_LOG" \
                      --nographics \
                      --noautoconsole \
                      --wait=-1 \
                      --noreboot
fi

# Start VM.
greenprint "Start VM"
sudo virsh start "bootc-${TEST_OS}-${FIRMWARE}"

greenprint "Wait until VM's IP"
while ! sudo virsh domifaddr "bootc-${TEST_OS}-${FIRMWARE}" | grep ipv4 > /dev/null;
do
    sleep 5
    echo "Booting..."
done

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
    RESULT=$(wait_for_ssh_up "$GUEST_IP")
    if [[ $RESULT == 1 ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done

greenprint "Prepare inventory file"
tee -a "$INVENTORY_FILE" > /dev/null << EOF
[guest]
$GUEST_IP

[guest:vars]
ansible_user="$SSH_USER"
ansible_private_key_file="$SSH_KEY"
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

[all:vars]
ansible_python_interpreter=/usr/bin/python3
EOF

greenprint "Prepare ansible.cfg"
export ANSIBLE_CONFIG="${PWD}/playbooks/ansible.cfg"

greenprint "Run ostree checking test"
ansible-playbook -v \
    -i "$INVENTORY_FILE" \
    -e bootc_image="$TEST_IMAGE_URL" \
    playbooks/check-system.yaml

greenprint "Create upgrade Containerfile"
tee "$UPGRADE_CONTAINERFILE" > /dev/null << EOF
FROM "$TEST_IMAGE_URL"
RUN dnf -y install wget && \
    dnf -y clean all
EOF

greenprint "Build $TEST_OS upgrade container image"
podman build -t "${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" -f "$UPGRADE_CONTAINERFILE" .
greenprint "Push $TEST_OS upgrade container image"
podman push "${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" "$TEST_IMAGE_URL"

greenprint "Upgrade $TEST_OS system"
ansible-playbook -v \
    -i "$INVENTORY_FILE" \
    playbooks/upgrade.yaml

greenprint "Run ostree checking test after upgrade"
ansible-playbook -v \
    -i "$INVENTORY_FILE" \
    -e bootc_image="$TEST_IMAGE_URL" \
    -e upgrade="true" \
    playbooks/check-system.yaml

greenprint "Clean up"
rm -rf auth.json rhel-9-4.repo
unset ANSIBLE_CONFIG
sudo virsh destroy "bootc-${TEST_OS}-${FIRMWARE}"
if [[ "$FIRMWARE" == bios ]]; then
    sudo virsh undefine "bootc-${TEST_OS}-${FIRMWARE}"
    sudo rm -f "$LOCAL_BOOT_LOCATION"
else
    sudo virsh undefine "bootc-${TEST_OS}-${FIRMWARE}" --nvram
    sudo rm -rf "${HTTPD_PATH}/httpboot"
    sudo rm -f "${HTTPD_PATH}/ks.cfg"
fi
sudo virsh vol-delete --pool images "bootc-${TEST_OS}-${FIRMWARE}.qcow2"

greenprint "🎉 All tests passed."
exit 0
