#!/bin/bash
set -Eeuo pipefail
trap "echo Execution failed!" ERR

if [[ -f local.env ]]; then
    echo "Using variables in local.env file as input parameters (target environment variables must have 'PROD_' prefix)"
    source local.env

    ENV_PREFIX="PROD"

    OCP_API_URL="${ENV_PREFIX}_OCP_API_URL"
    OCP_API_URL=${!OCP_API_URL}

    CICD_ENGINE_EDIT_SA_TOKEN="${ENV_PREFIX}_CICD_ENGINE_EDIT_SA_TOKEN"
    CICD_ENGINE_EDIT_SA_TOKEN=${!CICD_ENGINE_EDIT_SA_TOKEN}
else
    if [[ $# -eq 0 ]]; then
        SCRIPT_NAME=`basename "$0"`
        echo "Usage:"
        echo "./$SCRIPT_NAME <app-namespace> <app-name> <ocp-api-url> <cicd-engine-edit-token>"
        echo ""
        echo "Usage example:"
        echo "./$SCRIPT_NAME my-namespace my-app \\
                                https://api.openshiftcluster.company.com:6443 \\
                                abcedf-1234512345-abcdef-343286-42131..."
        exit 0
    fi
    
    if [[ $# -ne 4 ]]; then
        echo "Illegal number of parameters"
        exit 1
    fi

    APP_NAMESPACE="$1"
    APP_NAME="$2"
    OCP_API_URL="$3"
    CICD_ENGINE_EDIT_SA_TOKEN="$4"
fi

TOKEN_PARAM="--token=${CICD_ENGINE_EDIT_SA_TOKEN}"
OCP_PARAM="--server=${OCP_API_URL}"
NAMESPACE_PARAM="-n ${APP_NAMESPACE}"
NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM="${NAMESPACE_PARAM} ${OCP_PARAM} ${TOKEN_PARAM}"

echo "----------------------------------------------------------------------"
echo "PARAMETERS"
echo "----------------------------------------------------------------------"
echo "Openshift cluster: ${OCP_API_URL}"
echo "Application namespace: ${APP_NAMESPACE}"
echo "Application name: ${APP_NAME}"
echo "----------------------------------------------------------------------"
echo ""

# Check currently active deployment version
echo "Checking active deployment version (blue/green)"
ACTIVE_DEPLOYMENT_VERSION=$(oc get route ${APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM} -o jsonpath='{ .spec.to.name }')
if [[ "$ACTIVE_DEPLOYMENT_VERSION" == "${APP_NAME}-blue" ]]; then
  NEXT_ACTIVE_DEPLOYMENT_VERSION_ID="green"
elif [[ "$ACTIVE_DEPLOYMENT_VERSION" == "${APP_NAME}-green" ]]; then
  NEXT_ACTIVE_DEPLOYMENT_VERSION_ID="blue"
else
    echo "Invalid target service for route ${APP_NAME}: expected ${APP_NAME}-blue/green but ${ACTIVE_DEPLOYMENT_VERSION} has been found"
    exit 1
fi

echo "Switching to ${NEXT_ACTIVE_DEPLOYMENT_VERSION_ID} version"
oc patch route ${APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM} -p "{\"spec\":{\"to\":{\"name\":\"${APP_NAME}-${NEXT_ACTIVE_DEPLOYMENT_VERSION_ID}\"}}}"

echo ""
echo "Switch to ${NEXT_ACTIVE_DEPLOYMENT_VERSION_ID} version of ${APP_NAMESPACE}/${APP_NAME} successfully completed"