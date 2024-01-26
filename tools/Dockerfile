FROM quay.io/fedora/fedora:39

# Google Cloud SDK repo
COPY google-cloud-sdk.repo /etc/yum.repos.d/

RUN dnf -y update && \
    dnf -y install \
        ansible-core \
        beaker-client \
        curl \
        google-cloud-cli \
        net-tools \
        procps-ng \
        python3 \
        python3-devel \
        python3-pip && \
    dnf clean all && \
    pip install boto3 botocore openstacksdk && \
    ansible-galaxy collection install openstack.cloud community.general amazon.aws ansible.posix && \
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install && \
    aws --version && \
    rm -rf aws awscliv2.zip && \
    ansible --version && \
    ansible-galaxy collection list && \
    gcloud --version && \
    pip list
