
## OS replace test

### How to run OS replace test

#### Run RHEL test

1. Run on local machine

```shell
    TEST_OS=rhel-9-4 ARCH=<arch> PLATFORM=<platform> QUAY_USERNAME=<quay_username> QUAY_PASSWORD=<quay_password> RHEL_REGISTRY_URL=<url> DOWNLOAD_NODE=<nightly_compose_node> QUAY_SECRET=<quay_secert> ./os-replace.sh
```

2. Run on local machine using the [`tmt`](https://tmt.readthedocs.io/en/latest/overview.html) tool.

```shell
    tmt run -e TEST_OS=rhel-9-4 -e ARCH=<arch> -e PLATFORM=<platform> -e QUAY_USERNAME=<quay_username> -e QUAY_PASSWORD=<quay_password> -e RHEL_REGISTRY_URL=<url> -e DOWNLOAD_NODE=<nightly_compose_node> -e QUAY_SECRET=<quay_secert> -a plan --name 'os-replace/<platform>' provision --how connect --guest 127.0.0.1
```

3. Run on a shared test infrastructure using the [`testing farm`](https://docs.testing-farm.io/Testing%20Farm/0.1/cli.html) tool.

```shell
    testing-farm request \
        --plan "os-replace/<platform>" \
        --environment DOWNLOAD_NODE=<download_node> \
        --environment RHEL_REGISTRY_URL=<rhel_registry_url> \
        --environment TEST_OS="rhel-9-4" \
        --secret QUAY_USERNAME=<quay_username> \
        --secret QUAY_PASSWORD=<quay_password> \
        --secret QUAY_SECRET=<quay_secret> \
        --git-url "https://github.com/virt-s1/bootc-workflow-test" \
        --git-ref "main" \
        --compose "RHEL-9.4.0-Nightly" \
        --arch "<arch>" \
        --context "arch=<arch>" \
        --timeout "720"
```

#### Run CentOS Stream test

1. Run on local machine

```shell
    TEST_OS=centos-stream-9 ARCH=<arch> PLATFORM=<platform> QUAY_USERNAME=<quay_username> QUAY_PASSWORD=<quay_password> ./os-replace.sh
```

2. Run on local machine using the [`tmt`](https://tmt.readthedocs.io/en/latest/overview.html) tool.

```shell
    tmt run -e TEST_OS=centos-stream-9 -e ARCH=<arch> -e PLATFORM=<platform> -e QUAY_USERNAME=<quay_username> -e QUAY_PASSWORD=<quay_password> -a plan --name 'os-replace/<platform>' provision --how connect --guest 127.0.0.1
```

3. Run on a shared test infrastructure using the [`testing farm`](https://docs.testing-farm.io/Testing%20Farm/0.1/cli.html) tool.

```shell
    testing-farm request \
        --plan "os-replace/<platform>" \
        --environment TEST_OS="centos-stream-9" \
        --secret QUAY_USERNAME=<quay_username> \
        --secret QUAY_PASSWORD=<quay_password> \
        --secret QUAY_SECRET=<quay_secret> \
        --git-url "https://github.com/virt-s1/bootc-workflow-test" \
        --git-ref "main" \
        --compose "CentOS-Stream-9" \
        --arch "<arch>" \
        --context "arch=<arch>" \
        --timeout "720"
```

* AWS test needs environment variables `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_REGION=us-east-1` have to be configured.

* GCP test needs environment variables `GCP_PROJECT`, `GCP_SERVICE_ACCOUNT_NAME` and `GCP_SERVICE_ACCOUNT_FILE` have to be configured.

* OpenStack test needs environment variables `OS_USERNAME`, `OS_PASSWORD`, `OS_PROJECT_NAME`, `OS_AUTH_URL`, `OS_USER_DOMAIN_NAME` and `OS_PROJECT_DOMAIN_NAME` have to be configured.

### Required environment variables

    TEST_OS        The OS to run the tests in. Currently supported values:
                       "rhel-9-4"
                       "centos-stream-9"
                       "fedora-eln"
    ARCH           Test architecture
                       "x86_64"
                       "aarch64"

    PLATFORM       Run test on:
                       "openstack"
                       "gcp"
                       "aws"
    QUAY_USERNAME      quay.io username
    QUAY_PASSWORD      quay.io password
    DOWNLOAD_NODE      RHEL nightly compose download URL
    RHEL_REGISTRY_URL  RHEL bootc image URL
    QUAY_SECRET        Save into /etc/ostree/auth.json for authenticated registry
    GCP_PROJECT                 Google Cloud Platform project name
    GCP_SERVICE_ACCOUNT_NAME    Google Cloud Platform service account name
    GCP_SERVICE_ACCOUNT_FILE    Google Cloud Platform service account file path
    AWS_ACCESS_KEY_ID           AWS access key id
    AWS_SECRET_ACCESS_KEY       AWS secrety key
    AWS_REGION                  AWS region
                                    "us-east-1"
    OS_USERNAME                 OpenStack username
    OS_PASSWORD                 OpenStack password
    OS_PROJECT_NAME             OpenStack project name
    OS_AUTH_URL                 OpenStack authentication URL
    OS_USER_DOMAIN_NAME         OpenStack domain name
    OS_PROJECT_DOMAIN_NAME      OpenStack project domain name

