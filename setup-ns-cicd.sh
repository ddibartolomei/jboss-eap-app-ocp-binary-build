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
        echo "  <source-env-name> and <target-env-name> are used as prefixes for environment variables in local.env file."
        echo "  E.g.: if <target-env-name> is 'PROD', variables with 'PROD_' prefix are going to be considered for"
        echo "  target environment"
        echo ""
        echo "Usage example:"
        echo "./$SCRIPT_NAME DEV"
        exit 1
    fi

    ENV_PREFIX="${1}"

    CICD_ENGINE_NAMESPACE="${ENV_PREFIX}_CICD_ENGINE_NAMESPACE"
    CICD_ENGINE_NAMESPACE=${!CICD_ENGINE_NAMESPACE}

    OCP_API_URL="${ENV_PREFIX}_OCP_API_URL"
    OCP_API_URL=${!OCP_API_URL}

    ADMIN_TOKEN="${ENV_PREFIX}_ADMIN_TOKEN"
    ADMIN_TOKEN=${!ADMIN_TOKEN}
else
    if [[ $# -eq 0 ]]; then
        SCRIPT_NAME=`basename "$0"`
        echo "Usage:"
        echo "./$SCRIPT_NAME <cicd-engine-namespace> <ocp-api-url> <ocp-admin-token>"
        echo ""
        echo "Usage example:"
        echo "./$SCRIPT_NAME cicd-engine https://api.openshiftcluster.company.com:6443 abcedf-1234512345-abcdef"
        exit 0
    fi
    
    if [[ $# -ne 3 ]]; then
        echo "Illegal number of parameters"
        exit 1
    fi

    CICD_ENGINE_NAMESPACE="$1"
    OCP_API_URL="$2"
    ADMIN_TOKEN="$3"
fi

TOKEN_PARAM="--token=${ADMIN_TOKEN}"
OCP_PARAM="--server=${OCP_API_URL}"
NAMESPACE_PARAM="-n ${CICD_ENGINE_NAMESPACE}"
NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM="${NAMESPACE_PARAM} ${OCP_PARAM} ${TOKEN_PARAM}"
CICD_ENGINE_EDIT_SA="${CICD_ENGINE_NAMESPACE}-edit-sa"
CICD_ENGINE_VIEW_SA="${CICD_ENGINE_NAMESPACE}-view-sa"


echo "----------------------------------------------------------------------"
echo "PARAMETERS"
echo "----------------------------------------------------------------------"
echo "Openshift cluster: ${OCP_API_URL}"
echo "CI/CD Engine namespace: ${CICD_ENGINE_NAMESPACE}"
echo "----------------------------------------------------------------------"
echo ""

# Create CI/CD Engine namespace
echo "Creating CI/CD Engine namespace ${CICD_ENGINE_NAMESPACE}"
oc new-project ${CICD_ENGINE_NAMESPACE}

# Create service accounts
echo "Creating service account ${CICD_ENGINE_EDIT_SA} to edit resources of application projects"
oc create serviceaccount ${CICD_ENGINE_EDIT_SA} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}

echo "Creating service account ${CICD_ENGINE_VIEW_SA} to view resources of application projects"
oc create serviceaccount ${CICD_ENGINE_VIEW_SA} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}

# Generate service accounts tokens
echo "Generating token for service account ${CICD_ENGINE_EDIT_SA}"
CICD_ENGINE_EDIT_SA_TOKEN=$(oc serviceaccounts get-token ${CICD_ENGINE_EDIT_SA} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM})
echo ""
echo "Token for ${CICD_ENGINE_EDIT_SA} service account: ${CICD_ENGINE_EDIT_SA_TOKEN}"

CICD_ENGINE_VIEW_SA_TOKEN=$(oc serviceaccounts get-token ${CICD_ENGINE_VIEW_SA} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM})
echo ""
echo "Token for ${CICD_ENGINE_VIEW_SA} service account: ${CICD_ENGINE_VIEW_SA_TOKEN}"

echo ""
echo "Setup of ${CICD_ENGINE_NAMESPACE} namespace successfully completed"

