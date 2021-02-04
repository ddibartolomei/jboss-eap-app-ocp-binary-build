#!/bin/bash
set -Eeuo pipefail
trap "echo Execution failed!" ERR

if [[ -f local.env ]]; then
    echo "Using variables in local.env file as input parameters"
    source local.env

    if [[ $# -ne 1 ]]; then
        SCRIPT_NAME=`basename "$0"`
        echo "Usage:"
        echo "./$SCRIPT_NAME <env-name>"
        echo ""
        echo "  <env-name> is used as prefix for environment variables in local.env file."
        echo "  E.g.: if <env-name> is 'PROD', variables with 'PROD_' prefix are going to be considered for"
        echo "  target environment"
        echo ""
        echo "Usage example:"
        echo "./$SCRIPT_NAME DEV"
        exit 1
    fi
    
    ENV_PREFIX="${1}"

    OCP_API_URL="${ENV_PREFIX}_OCP_API_URL"
    OCP_API_URL=${!OCP_API_URL}

    ADMIN_TOKEN="${ENV_PREFIX}_ADMIN_TOKEN"
    ADMIN_TOKEN=${!ADMIN_TOKEN}
else
    if [[ $# -eq 0 ]]; then
        SCRIPT_NAME=`basename "$0"`
        echo "Usage:"
        echo "./$SCRIPT_NAME <app-namespace> <ocp-api-url> <ocp-admin-token>"
        echo ""
        echo "Usage example:"
        echo "./$SCRIPT_NAME my-namespace https://api.openshiftcluster.company.com:6443 abcedf-1234512345-abcdef"
        exit 0
    fi
    
    if [[ $# -ne 3 ]]; then
        echo "Illegal number of parameters"
        exit 1
    fi

    APP_NAMESPACE="$1"
    OCP_API_URL="$2"
    ADMIN_TOKEN="$3"
fi

TOKEN_PARAM="--token=${ADMIN_TOKEN}"
OCP_PARAM="--server=${OCP_API_URL}"
OCP_TOKEN_COMPOSITE_PARAM="${OCP_PARAM} ${TOKEN_PARAM}"

echo "----------------------------------------------------------------------"
echo "PARAMETERS"
echo "----------------------------------------------------------------------"
echo "Openshift cluster: ${OCP_API_URL}"
echo "Application namespace: ${APP_NAMESPACE}"
echo "----------------------------------------------------------------------"
echo ""

echo "Deleting namespace ${APP_NAMESPACE}"
oc delete project ${APP_NAMESPACE} ${OCP_TOKEN_COMPOSITE_PARAM}

echo ""
echo "Delete of ${APP_NAMESPACE} namespace successfully completed"

