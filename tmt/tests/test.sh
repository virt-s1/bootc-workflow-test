#!/bin/bash

cd ../../

TEMPDIR=$(mktemp -d)
trap 'rm -rf -- "$TEMPDIR"' EXIT
[[ $- =~ x ]] && debug=1 && set +x
[[ -n "${GCP_SERVICE_ACCOUNT_FILE_B64+x}" ]] && echo "$GCP_SERVICE_ACCOUNT_FILE_B64" | base64 -d > "${TEMPDIR}"/gcp_auth.json && export GCP_SERVICE_ACCOUNT_FILE=${TEMPDIR}/gcp_auth.json
[[ -n "${BEAKER_KEYTAB_B64+x}" ]] && echo "$BEAKER_KEYTAB_B64" | base64 -d > "${TEMPDIR}/beaker.keytab" && sudo mv "${TEMPDIR}/beaker.keytab" /etc/beaker.keytab
[[ -n "${BEAKER_CLIENT_B64+x}" ]] && echo "$BEAKER_CLIENT_B64" | base64 -d > "${TEMPDIR}/client.conf" && sudo mv "${TEMPDIR}/client.conf" /etc/beaker/client.conf
[[ -n "${KRB5_CONF_B64+x}" ]] && echo "$KRB5_CONF_B64" | base64 -d > "${TEMPDIR}/krb5.conf" && sudo mv "${TEMPDIR}/krb5.conf" /etc/krb5.conf
[[ $debug == 1 ]] && set -x

function run_tests() {
	if [ "$TEST_CASE" = "os-replace" ]; then
		./os-replace.sh
	elif [ "$TEST_CASE" = "anaconda" ]; then
		./anaconda.sh
	elif [ "$TEST_CASE" = "bib-image" ]; then
		./bib-image.sh
	else
		echo "Error: Test case $TEST_CASE not found!"
		exit 1
	fi
}

if [[ ${CI-x} == "RHTAP" ]]; then
	podman login -u "${QUAY_USERNAME}" -p "${QUAY_PASSWORD}" quay.io
	skopeo inspect docker://"$IMAGE_URL" >skopeo_inspect.json
	COMPOSE_ID=$(jq -r '.Labels."redhat.compose-id"' skopeo_inspect.json)
	if [[ "${COMPOSE_ID}" =~ ^RHEL-[0-9]+\.[0-9]+- ]]; then
		TEST_OS=$(echo "${COMPOSE_ID//./-}" | grep -oP '^RHEL-[0-9]+\-[0-9]+' | tr '[:upper:]' '[:lower:]')
	elif [[ "${COMPOSE_ID}" == "CentOS-Stream-9"* ]]; then
		TEST_OS=$(echo "$COMPOSE_ID" | grep -oP '^CentOS-Stream-[0-9]+' | tr '[:upper:]' '[:lower:]')
	else
		echo "Error: Compose ID is invalid: ${COMPOSE_ID}"
		exit 1
	fi
	export TEST_OS
	run_tests
else
	run_tests
fi
