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

run_tests
