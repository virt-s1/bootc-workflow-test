#!/bin/bash

cd ../../
ARCH=$(uname -m)
export ARCH

function run_tests() {
	if [ "$TEST_CASE" = "os-replace" ]; then
		./os-replace.sh
	else
		echo "Error: Test case $TEST_CASE not found!"
		exit 1
	fi
}

if [[ $CI == "RHTAP" ]]; then
	podman login -u "${QUAY_USERNAME}" -p "${QUAY_PASSWORD}" quay.io
	skopeo inspect docker://"$IMAGE_URL" >skopeo_inspect.json
	COMPOSE_ID=$(jq -r '.Labels."redhat.compose-id"' skopeo_inspect.json)
	if [[ "${COMPOSE_ID}" == "RHEL-9.4"* ]]; then
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
