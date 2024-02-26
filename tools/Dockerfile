FROM quay.io/fedora/fedora:41@sha256:2877c7339e710503bf9b0232d2bb190dc7633c70fee459504876c1f33f9f3ea0

# Google Cloud SDK repo
COPY google-cloud-sdk.repo /etc/yum.repos.d/

RUN dnf -y update && \
    dnf -y install \
        ansible-core \
        beaker-client \
        curl \
        gcc \
        google-cloud-cli \
        net-tools \
        podman \
        procps-ng \
        python3 \
        python3-devel \
        python3-pip \
        skopeo \
        unzip && \
    dnf clean all && \
    pip install boto3 botocore openstacksdk && \
    ansible-galaxy collection install openstack.cloud community.general amazon.aws ansible.posix && \
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install && \
    rm -rf aws awscliv2.zip
