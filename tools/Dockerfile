# renovate: datasource=endoflife-date depName=fedora versioning=docker
FROM quay.io/fedora/fedora:39

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
