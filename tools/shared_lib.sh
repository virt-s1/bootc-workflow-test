#!/bin/bash

# Dumps details about the instance running the CI job.
function dump_runner {
    RUNNER_CPUS=$(nproc)
    RUNNER_MEM=$(free -m | grep -oP '\d+' | head -n 1)
    RUNNER_DISK=$(df --output=size -h / | sed '1d;s/[^0-9]//g')
    RUNNER_HOSTNAME=$(uname -n)
    RUNNER_USER=$(whoami)
    RUNNER_ARCH=$(uname -m)
    RUNNER_KERNEL=$(uname -r)

    echo -e "\033[0;36m"
    cat << EOF
------------------------------------------------------------------------------
CI MACHINE SPECS
------------------------------------------------------------------------------
    Hostname: ${RUNNER_HOSTNAME}
        User: ${RUNNER_USER}
        CPUs: ${RUNNER_CPUS}
         RAM: ${RUNNER_MEM} MB
        DISK: ${RUNNER_DISK} GB
        ARCH: ${RUNNER_ARCH}
      KERNEL: ${RUNNER_KERNEL}
------------------------------------------------------------------------------
EOF
}

# Colorful timestamped output.
function greenprint {
    echo -e "\033[1;32m[$(date -Isecond)] ${1}\033[0m"
}

function redprint {
    echo -e "\033[1;31m[$(date -Isecond)] ${1}\033[0m"
}

# Retry container image pull and push
function retry {
    n=0
    until [ "$n" -ge 3 ]
    do
       "$@" && break
       n=$((n+1))
       sleep 10
    done
}

function image_inspect {
    # shellcheck disable=SC2034
    if [[ $TIER1_IMAGE_URL == quay* ]]; then
        REDHAT_ID=$(skopeo inspect --tls-verify=false --creds "$QUAY_USERNAME":"$QUAY_PASSWORD" docker://"${TIER1_IMAGE_URL}" | jq -r '.Labels."redhat.id"')
        REDHAT_VERSION_ID=$(skopeo inspect --tls-verify=false --creds "$QUAY_USERNAME":"$QUAY_PASSWORD" "docker://${TIER1_IMAGE_URL}" | jq -r '.Labels."redhat.version-id"')
        CURRENT_COMPOSE_ID=$(skopeo inspect --tls-verify=false --creds "$QUAY_USERNAME":"$QUAY_PASSWORD" "docker://${TIER1_IMAGE_URL}" | jq -r '.Labels."redhat.compose-id"')
    else
        REDHAT_ID=$(skopeo inspect --tls-verify=false "docker://${TIER1_IMAGE_URL}" | jq -r '.Labels."redhat.id"')
        REDHAT_VERSION_ID=$(skopeo inspect --tls-verify=false "docker://${TIER1_IMAGE_URL}" | jq -r '.Labels."redhat.version-id"')
        CURRENT_COMPOSE_ID=$(skopeo inspect --tls-verify=false "docker://${TIER1_IMAGE_URL}" | jq -r '.Labels."redhat.compose-id"')
    fi
}
