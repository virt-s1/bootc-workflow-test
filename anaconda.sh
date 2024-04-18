#!/bin/bash
set -exuo pipefail

podman login -u "${QUAY_USERNAME}" -p "${QUAY_PASSWORD}" quay.io

source tools/shared_lib.sh
dump_runner

greenprint "Start firewalld"
sudo systemctl enable --now firewalld

greenprint "🚀 Starting libvirt daemon"
sudo systemctl start libvirtd
sudo virsh list --all > /dev/null

# Set a customized dnsmasq configuration for libvirt so we always get the
# same address on bootup.
greenprint "💡 Setup libvirt network"
sudo tee /tmp/integration.xml > /dev/null << EOF
<network xmlns:dnsmasq='http://libvirt.org/schemas/network/dnsmasq/1.0'>
  <name>integration</name>
  <uuid>1c8fe98c-b53a-4ca4-bbdb-deb0f26b3579</uuid>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='integration' zone='trusted' stp='on' delay='0'/>
  <mac address='52:54:00:36:46:ef'/>
  <ip address='192.168.100.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.100.2' end='192.168.100.254'/>
      <host mac='34:49:22:B0:83:30' name='vm-1' ip='192.168.100.50'/>
      <host mac='34:49:22:B0:83:31' name='vm-2' ip='192.168.100.51'/>
      <host mac='34:49:22:B0:83:32' name='vm-3' ip='192.168.100.52'/>
    </dhcp>
  </ip>
  <dnsmasq:options>
    <dnsmasq:option value='dhcp-vendorclass=set:efi-http,HTTPClient:Arch:00016'/>
    <dnsmasq:option value='dhcp-option-force=tag:efi-http,60,HTTPClient'/>
    <dnsmasq:option value='dhcp-boot=tag:efi-http,&quot;http://192.168.100.1/httpboot/EFI/BOOT/BOOTX64.EFI&quot;'/>
  </dnsmasq:options>
</network>
EOF
if ! sudo virsh net-info integration > /dev/null 2>&1; then
    sudo virsh net-define /tmp/integration.xml
fi
if [[ $(sudo virsh net-info integration | grep 'Active' | awk '{print $2}') == 'no' ]]; then
    sudo virsh net-start integration
fi

ARCH=$(uname -m)

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
PARTITION=${PARTITION:-"standard"}

case "$REDHAT_ID" in
    "rhel")
        # work with old TEST_OS variable value rhel-9-x
        TEST_OS=$(echo "${REDHAT_ID}-${REDHAT_VERSION_ID}" | sed 's/\./-/')
        sed "s/REPLACE_ME/${DOWNLOAD_NODE}/; s/REPLACE_COMPOSE_ID/${CURRENT_COMPOSE_ID}/" files/rhel-9-y.template | tee rhel-9-y.repo > /dev/null
        ADD_REPO="COPY rhel-9-y.repo /etc/yum.repos.d/rhel-9-y.repo"
        ADD_RHC="RUN dnf install -y rhc"
        BOOT_LOCATION="http://${DOWNLOAD_NODE}/rhel-9/composes/RHEL-9/${CURRENT_COMPOSE_ID}/compose/BaseOS/${ARCH}/os/"
        OS_VARIANT="rhel9-unknown"
        BOOT_ARGS="uefi"
        CUT_DIRS=8
        ;;
    "centos")
        # work with old TEST_OS variable value centos-stream-9
        TEST_OS=$(echo "${REDHAT_ID}-${REDHAT_VERSION_ID}" | sed 's/-/-stream-/')
        ADD_REPO=""
        ADD_RHC=""
        BOOT_LOCATION="https://composes.stream.centos.org/development/${CURRENT_COMPOSE_ID}/compose/BaseOS/${ARCH}/os/"
        OS_VARIANT="centos-stream9"
        BOOT_ARGS="uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no"
        CUT_DIRS=6
        ;;
    "fedora")
        ADD_REPO=""
        ADD_RHC=""
        BOOT_LOCATION="https://odcs.fedoraproject.org/composes/production/${CURRENT_COMPOSE_ID}/compose/BaseOS/${ARCH}/os/"
        OS_VARIANT="fedora-rawhide"
        BOOT_ARGS="uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no"
        CUT_DIRS=7
        ;;
    *)
        redprint "Variable TIER1_IMAGE_URL is not supported"
        exit 1
        ;;
esac

TEST_IMAGE_NAME="bootc-workflow-test"
TEST_IMAGE_URL="quay.io/redhat_emp1/${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}"

greenprint "Generate auth.json for registry auth"
[[ $- =~ x ]] && debug=1 && set +x
sed "s/REPLACE_ME/$QUAY_SECRET/g" files/auth.template | tee auth.json > /dev/null
[[ $debug == 1 ]] && set -x

greenprint "Create $TEST_OS installation Containerfile"
tee "$INSTALL_CONTAINERFILE" > /dev/null << EOF
FROM "$TIER1_IMAGE_URL"
$ADD_REPO
$ADD_RHC
RUN dnf -y install python3 && \
    dnf -y clean all
COPY auth.json /etc/ostree/auth.json
EOF

greenprint "Check $TEST_OS installation Containerfile"
cat "$INSTALL_CONTAINERFILE"

greenprint "Build $TEST_OS installation container image"
podman build --tls-verify=false --retry=5 --retry-delay=10 -t "${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" -f "$INSTALL_CONTAINERFILE" .

greenprint "Push $TEST_OS installation container image"
retry podman push --tls-verify=false --quiet "${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" "$TEST_IMAGE_URL"

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

bootloader --append="console=ttyS0,115200n8"

ostreecontainer --url $TEST_IMAGE_URL

poweroff

%pre
#!/bin/sh
curl -kLO ${CERT_URL}/certs/Current-IT-Root-CAs.pem --output-dir /etc/pki/ca-trust/source/anchors
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

if [[ "$PARTITION" == "lvm" ]]; then
    if [[ "$FIRMWARE" == "bios" ]]; then
        greenprint "BIOS LVM partition setup"
        tee -a "$KS_FILE" > /dev/null << EOF
part biosboot --size=1 --fstype=biosboot
part /boot --size=1000 --fstype=ext4 --label=boot
part pv.01 --grow
volgroup bootc pv.01
logvol / --vgname=bootc --fstype=xfs --size=10000 --name=root
EOF
    else
        greenprint "UEFI LVM partition setup"
        tee -a "$KS_FILE" > /dev/null << EOF
part /boot/efi --size=100  --fstype=efi
part /boot     --size=1000  --fstype=ext4 --label=boot
part pv.01 --grow
volgroup bootc pv.01
logvol / --vgname=bootc --fstype=xfs --size=10000 --name=root
EOF
    fi
else
    greenprint "Standard partition setup"
    echo "autopart --nohome --noswap --type=plain --fstype=xfs" >> "$KS_FILE"
fi

greenprint "Configure console log file"
VIRT_LOG="/tmp/${TEST_OS}-${FIRMWARE}-${PARTITION}-console.log"
sudo rm -f "$VIRT_LOG"

# HTTP Boot only runs on x86_64 + LVM
if [[ "$ARCH" == "x86_64" ]] && [[ "$FIRMWARE" == "uefi" ]] && [[ "$PARTITION" == "lvm" ]]; then
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

    greenprint "Install $TEST_OS via HTTP Boot on UEFI VM"
    sudo virt-install --name="bootc-${TEST_OS}-${FIRMWARE}"\
                      --disk path="$LIBVIRT_UEFI_IMAGE_PATH",format=qcow2 \
                      --ram 3072 \
                      --vcpus 2 \
                      --network network=integration,mac=34:49:22:B0:83:30 \
                      --boot "$BOOT_ARGS" \
                      --pxe \
                      --os-variant "$OS_VARIANT" \
                      --console file,source.path="$VIRT_LOG" \
                      --nographics \
                      --noautoconsole \
                      --wait \
                      --noreboot
else
    greenprint "Download boot.iso"
    curl -O "${BOOT_LOCATION}images/boot.iso"
    sudo mv boot.iso /var/lib/libvirt/images
    LOCAL_BOOT_LOCATION="/var/lib/libvirt/images/boot.iso"

    if [[ "$FIRMWARE" == "bios" ]]; then
        greenprint "Install $TEST_OS via anaconda on $FIRMWARE VM"
        sudo virt-install --initrd-inject="$KS_FILE" \
                          --extra-args="inst.ks=file:/ks.cfg console=ttyS0,115200" \
                          --name="bootc-${TEST_OS}-${FIRMWARE}"\
                          --disk path="$LIBVIRT_UEFI_IMAGE_PATH",format=qcow2 \
                          --ram 3072 \
                          --vcpus 2 \
                          --network network=integration,mac=34:49:22:B0:83:30 \
                          --os-variant "$OS_VARIANT" \
                          --location "$LOCAL_BOOT_LOCATION" \
                          --console file,source.path="$VIRT_LOG" \
                          --nographics \
                          --noautoconsole \
                          --wait \
                          --noreboot
    else
        greenprint "Install $TEST_OS via anaconda on $FIRMWARE VM"
        sudo virt-install --initrd-inject="$KS_FILE" \
                          --extra-args="inst.ks=file:/ks.cfg console=ttyS0,115200" \
                          --name="bootc-${TEST_OS}-${FIRMWARE}"\
                          --disk path="$LIBVIRT_UEFI_IMAGE_PATH",format=qcow2 \
                          --ram 3072 \
                          --vcpus 2 \
                          --network network=integration,mac=34:49:22:B0:83:30 \
                          --boot "$BOOT_ARGS" \
                          --os-variant "$OS_VARIANT" \
                          --location "$LOCAL_BOOT_LOCATION" \
                          --console file,source.path="$VIRT_LOG" \
                          --nographics \
                          --noautoconsole \
                          --wait \
                          --noreboot
    fi
fi

[[ -z ${TESTING_FARM_REQUEST_ID+x} ]] || cp "$VIRT_LOG" "${TMT_TEST_DATA}"/../installation-"${VIRT_LOG##*/}"

sudo virsh dumpxml "bootc-${TEST_OS}-${FIRMWARE}"

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

[[ -z ${TESTING_FARM_REQUEST_ID+x} ]] || cp -f "$VIRT_LOG" "${TMT_TEST_DATA}"/../bootup-"${VIRT_LOG##*/}"

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
    -e test_os="$TEST_OS" \
    -e bootc_image="$TEST_IMAGE_URL" \
    -e image_label_version_id="$REDHAT_VERSION_ID" \
    playbooks/check-system.yaml

greenprint "Create upgrade Containerfile"
tee "$UPGRADE_CONTAINERFILE" > /dev/null << EOF
FROM "$TEST_IMAGE_URL"
RUN dnf -y install wget && \
    dnf -y clean all
EOF

greenprint "Build $TEST_OS upgrade container image"
podman build --tls-verify=false --retry=5 --retry-delay=10 -t "${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" -f "$UPGRADE_CONTAINERFILE" .
greenprint "Push $TEST_OS upgrade container image"
retry podman push --tls-verify=false --quiet "${TEST_IMAGE_NAME}:${QUAY_REPO_TAG}" "$TEST_IMAGE_URL"

greenprint "Upgrade $TEST_OS system"
ansible-playbook -v \
    -i "$INVENTORY_FILE" \
    playbooks/upgrade.yaml

greenprint "Run ostree checking test after upgrade"
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

[[ -z ${TESTING_FARM_REQUEST_ID+x} ]] || cp "$VIRT_LOG" "${TMT_TEST_DATA}"/../final-"${VIRT_LOG##*/}"

greenprint "Clean up"
rm -rf auth.json rhel-9-4.repo
unset ANSIBLE_CONFIG
sudo virsh destroy "bootc-${TEST_OS}-${FIRMWARE}"
if [[ "$FIRMWARE" == bios ]]; then
    sudo virsh undefine "bootc-${TEST_OS}-${FIRMWARE}"
else
    sudo virsh undefine "bootc-${TEST_OS}-${FIRMWARE}" --nvram
fi
sudo virsh vol-delete --pool images "bootc-${TEST_OS}-${FIRMWARE}.qcow2"

if [[ "$ARCH" == "x86_64" ]] && [[ "$FIRMWARE" == "uefi" ]] && [[ "$PARTITION" == "lvm" ]]; then
    sudo rm -rf "${HTTPD_PATH}/httpboot"
    sudo rm -f "${HTTPD_PATH}/ks.cfg"
else
    sudo rm -f "$LOCAL_BOOT_LOCATION"
fi

greenprint "🎉 All tests passed."
exit 0
