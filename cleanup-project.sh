#!/bin/bash
set -Eeuo pipefail

trap "echo Deploy failed!" ERR

# Cleanup Project
if [[ $# -eq 0 ]]; then
    SCRIPT_NAME=`basename "$0"`
    echo "Usage:"
    echo "./$SCRIPT_NAME <project-namespace>"
    echo ""
    echo "Usage example:"
    echo "./$SCRIPT_NAME my-project"
    exit 0
fi

if [[ $# -ne 1 ]]; then
    echo "Illegal number of parameters"
    exit 1
fi

PROJECT=$1

echo "----------------------------------------------------------------------"
echo "PARAMETERS"
echo "----------------------------------------------------------------------"
echo "Project Namespace: ${PROJECT}"
echo ""
echo "Deleting namespace ${PROJECT}"
oc delete project ${PROJECT}

