#!/bin/bash

cd ../../
ARCH=$(uname -m)
export ARCH
COMPONENT_NAME=$(echo -n "${SNAPSHOT}" | base64 -d | jq -r .components[0].name)
CONTAINER_IMAGE=$(echo -n "${SNAPSHOT}" | base64 -d | jq -r .components[0].containerImage)
echo "${SNAPSHOT}"
echo "${COMPONENT_NAME}"
echo "${CONTAINER_IMAGE}"

if [ "$TEST_CASE" = "os-replace" ]; then
	./os-replace.sh
else
	echo "Error: Test case $TEST_CASE not found!"
	exit 1
fi
