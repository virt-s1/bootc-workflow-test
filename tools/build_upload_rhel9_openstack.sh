#!/bin/bash
set -euox pipefail

# Set up temporary files.
TEMPDIR=$(mktemp -d)
# trap 'rm -rf -- "$TEMPDIR"' EXIT

INVENTORY_FILE="${TEMPDIR}/inventory"
SSH_KEY=${TEMPDIR}/id_rsa
ssh-keygen -f "${SSH_KEY}" -N "" -q -t rsa-sha2-256 -b 2048
SSH_KEY_PUB="${SSH_KEY}.pub"
SSH_USER=cloud-user

tee -a "$INVENTORY_FILE" > /dev/null << EOF
[openstack]
localhost

[guest]

[builder]

[openstack:vars]
ansible_connection=local

[guest:vars]
ansible_user="$SSH_USER"
ansible_private_key_file="$SSH_KEY"
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

[builder:vars]
ansible_user=fedora
ansible_private_key_file="$SSH_KEY"
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

[all:vars]
ansible_python_interpreter=/usr/bin/python3
EOF

export ANSIBLE_CONFIG="${PWD}/playbooks/ansible.cfg"

ansible-playbook -v \
    -i "$INVENTORY_FILE" \
    -e ssh_key_pub="$SSH_KEY_PUB" \
    tools/playbooks/build-upload-openstack.yaml
