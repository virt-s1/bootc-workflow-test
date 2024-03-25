#!/bin/bash
set -exuo pipefail

BP=bootc-vhd

case "$TEST_OS" in
"rhel-9-4")
	BASEURL="http://${DOWNLOAD_NODE}/rhel-9/nightly/RHEL-9/latest-RHEL-9.4.0"
	;;
"centos-stream-9")
	BASEURL="https://composes.stream.centos.org/production/latest-CentOS-Stream"
	;;
*)
	redprint "Variable TEST_OS has to be defined"
	exit 1
	;;
esac

dnf install -y osbuild-composer composer-cli cockpit-composer
systemctl enable --now osbuild-composer.socket
systemctl enable --now cockpit.socket
systemctl restart osbuild-composer
composer-cli status show
mkdir -p /etc/osbuild-composer/repositories
# shellcheck disable=SC2001
tee /etc/osbuild-composer/repositories/"$(echo "$TEST_OS" | sed 's/\(.*\)-\(.*\)/\1.\2/')".json >/dev/null <<EOF
{
     "x86_64": [
        {
            "name": "baseos",
            "baseurl": "$BASEURL/compose/BaseOS/x86_64/os/",
            "check_gpg": false,
            "rhsm": false
        },
        {
            "name": "appstream",
            "baseurl": "$BASEURL/compose/AppStream/x86_64/os/",
            "check_gpg": false,
            "rhsm": false
        }
    ]
}
EOF
tee bp.toml >/dev/null <<EOF
name = "$BP"
version = "0.0.1"

packages = [
    { name = "cloud-init" },
    { name = "WALinuxAgent" },
    { name = "podman" },
]

[customizations]
partitioning_mode = "raw"

[[customizations.filesystem]]
mountpoint = "/boot"
minsize = "1 GiB"

[[customizations.filesystem]]
mountpoint = "/"
minsize = "8 GiB"
EOF
composer-cli blueprints push bp.toml
systemctl restart osbuild-composer
composer-cli blueprints depsolve $BP
composer-cli compose start $BP vhd
composer-cli compose status --json | jq -r ".[]|select(.path==\"/compose/queue\")|.body"
sleep 60
n=0
until [ "$n" -ge 15 ]; do
	[[ -n $(composer-cli compose status --json | jq -r ".[]|select(.path==\"/compose/finished\")|.body.finished[]|select(.blueprint==\"$BP\")|.id") ]] && break
	composer-cli compose status --json | jq -r ".[]|select(.path==\"/compose/queue\")|.body"
	n=$((n + 1))
	sleep 60
done
UUID=$(composer-cli compose status --json | jq -r ".[]|select(.path==\"/compose/finished\")|.body.finished[]|select(.blueprint==\"$BP\")|.id")
[[ -n $UUID ]] || exit 1
composer-cli compose image "$UUID"
VHD_FILE=$(ls -- *.vhd)
rpm --import https://packages.microsoft.com/keys/microsoft.asc
dnf install -y https://packages.microsoft.com/config/rhel/9.0/packages-microsoft-prod.rpm
dnf install -y azure-cli
[[ $- =~ x ]] && debug=1 && set +x
az login --service-principal -u "$AZURE_CLIENT_ID" -p "$AZURE_SECRET" --tenant "$AZURE_TENANT"
[[ $debug == 1 ]] && set -x
az group create --name bootc_upload --location eastus --tags "delete=no"
az storage account create --resource-group bootc_upload --name bootcstorage --location eastus --access-tier Hot --sku Standard_LRS
az storage container create --account-name bootcstorage --name bootc
az storage blob upload --account-name bootcstorage --container-name bootc --file "$VHD_FILE" --name "$VHD_FILE" --type page
OLD_IMAGE=$(az image list --resource-group bootc-images --query "[?tags.project=='bootc' && tags.test_os=='$TEST_OS' && tags.arch=='x86_64'].id" | jq -r '.[]')
TIME=$(date "+%Y%m%d%H%M%S")
az image create --resource-group bootc-images --name "$TEST_OS"-"$TIME" --os-type linux --location eastus --source https://bootcstorage.blob.core.windows.net/bootc/"$VHD_FILE" --hyper-v-generation V2 --tag "project=bootc" "test_os=$TEST_OS" "arch=x86_64"
echo "$OLD_IMAGE" | while read -r R_ID; do
	az tag update --tags "test_os=$TEST_OS" --operation Delete --resource-id "$R_ID"
done
# TODO cleanup old images
az group delete --name bootc_upload -y
