#!/bin/sh

cd ../../

if [ "$TEST_CASE" = "os-replace" ]; then
  ./os-replace.sh
else
  echo "Error: Test case $TEST_CASE not found!"
  exit 1
fi
