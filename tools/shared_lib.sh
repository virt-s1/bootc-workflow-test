#!/bin/bash

# Dumps details about the instance running the CI job.
function dump_runner {
    CPUS=$(nproc)
    MEM=$(free -m | grep -oP '\d+' | head -n 1)
    DISK=$(df --output=size -h / | sed '1d;s/[^0-9]//g')
    HOSTNAME=$(uname -n)
    USER=$(whoami)
    ARCH=$(uname -m)
    KERNEL=$(uname -r)

    echo -e "\033[0;36m"
    cat << EOF
------------------------------------------------------------------------------
CI MACHINE SPECS
------------------------------------------------------------------------------
    Hostname: ${HOSTNAME}
        User: ${USER}
        CPUs: ${CPUS}
         RAM: ${MEM} MB
        DISK: ${DISK} GB
        ARCH: ${ARCH}
      KERNEL: ${KERNEL}
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

