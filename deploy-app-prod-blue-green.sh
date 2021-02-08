#!/bin/bash
set -Eeuo pipefail
trap "echo Execution failed!" ERR

if [[ -f local.env ]]; then
    echo "Using variables in local.env file as input parameters (target environment variables must have 'PROD_' prefix)"
    source local.env

    if [[ $# -ne 1 ]]; then
        SCRIPT_NAME=`basename "$0"`
        echo "Usage:"
        echo "./$SCRIPT_NAME <image-tag>"
        echo ""
        echo "Usage example:"
        echo "./$SCRIPT_NAME 1.2"
        exit 1
    fi

    ENV_PREFIX="PROD"

    IMAGE_TAG="$1"

    IMAGE_REGISTRY_HOST_PORT_INTERNAL="${ENV_PREFIX}_IMAGE_REGISTRY_HOST_PORT_INTERNAL"
    IMAGE_REGISTRY_HOST_PORT_INTERNAL=${!IMAGE_REGISTRY_HOST_PORT_INTERNAL}

    OCP_API_URL="${ENV_PREFIX}_OCP_API_URL"
    OCP_API_URL=${!OCP_API_URL}

    CICD_ENGINE_EDIT_SA_TOKEN="${ENV_PREFIX}_CICD_ENGINE_EDIT_SA_TOKEN"
    CICD_ENGINE_EDIT_SA_TOKEN=${!CICD_ENGINE_EDIT_SA_TOKEN}
else
    if [[ $# -eq 0 ]]; then
        SCRIPT_NAME=`basename "$0"`
        echo "Usage:"
        echo "./$SCRIPT_NAME <image-tag> <internal-image-registry-host-port> <ocp-api-url> <cicd-engine-edit-token>"
        echo ""
        echo "Usage example:"
        echo "./$SCRIPT_NAME 1.2 image-registry.openshift-image-registry.svc:5000 https://api.openshiftcluster.company.com:6443 abcedf-1234512345-abcdef-343286-42131..."
        exit 0
    fi
    
    if [[ $# -ne 4 ]]; then
        echo "Illegal number of parameters"
        exit 1
    fi

    IMAGE_TAG="$1"
    IMAGE_REGISTRY_HOST_PORT_INTERNAL="$2"
    OCP_API_URL="$3"
    CICD_ENGINE_EDIT_SA_TOKEN="$4"
fi

BASE_CONFIG_DIR="app-config"
source ${BASE_CONFIG_DIR}/deployment-setup-config.env

TOKEN_PARAM="--token=${CICD_ENGINE_EDIT_SA_TOKEN}"
OCP_PARAM="--server=${OCP_API_URL}"
NAMESPACE_PARAM="-n ${APP_NAMESPACE}"
NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM="${NAMESPACE_PARAM} ${OCP_PARAM} ${TOKEN_PARAM}"

B2I_CONFIG_RELATIVE_SOURCE_DIR="${BASE_CONFIG_DIR}/b2i-config"
B2I_BUILD_DIR="b2i"
CONFIG_MAP_NAME="${APP_NAME}-config"
CONFIG_MAP_RELATIVE_SOURCE_DIR="${BASE_CONFIG_DIR}/config/"
CONFIG_MAP_MOUNT_DIR="/opt/config"
SECRET_NAME="${APP_NAME}-config-data"
SECRET_ENV_FILE="${BASE_CONFIG_DIR}/config-data-secret.env"

echo "----------------------------------------------------------------------"
echo "PARAMETERS"
echo "----------------------------------------------------------------------"
echo "Openshift cluster: ${OCP_API_URL}"
echo "Application namespace: ${APP_NAMESPACE}"
echo "Application name: ${APP_NAME}"
echo "Image tag: ${IMAGE_TAG}"
echo "Internal image registry: ${IMAGE_REGISTRY_HOST_PORT_INTERNAL}"
echo "Config map ${CONFIG_MAP_NAME} mapping content of relative path ${CONFIG_MAP_RELATIVE_SOURCE_DIR} to ${CONFIG_MAP_MOUNT_DIR}"
echo "Secret ${SECRET_NAME} mapping content of file ${SECRET_ENV_FILE}"
echo "----------------------------------------------------------------------"
echo ""

TARGET_IMAGESTREAM_TAG="${IMAGE_REGISTRY_HOST_PORT_INTERNAL}/${APP_NAMESPACE}/${APP_NAME}:${IMAGE_TAG}"

# Check currently active deployment version
echo "Checking active deployment version (blue/green)"
ACTIVE_DEPLOYMENT_VERSION=$(oc get route ${APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM} -o jsonpath='{ .spec.to.name }')
if [[ "$ACTIVE_DEPLOYMENT_VERSION" == "${APP_NAME}-blue" ]]; then
  DEPLOY_VERSION_ID="green"
elif [[ "$ACTIVE_DEPLOYMENT_VERSION" == "${APP_NAME}-green" ]]; then
  DEPLOY_VERSION_ID="blue"
else
    echo "Invalid target service for route ${APP_NAME}: expected ${APP_NAME}-blue/green but ${ACTIVE_DEPLOYMENT_VERSION} has been found"
    exit 1
fi
echo "Deploying to ${DEPLOY_VERSION_ID} version"

# Check imagestream tag exists
echo "Checking imagestream tag exists"
oc get is ${APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM} -o json --ignore-not-found=true | grep -q "\"tag\":\s*\"${IMAGE_TAG}\""

VERSIONED_APP_NAME=${APP_NAME}-${DEPLOY_VERSION_ID}
VERSIONED_CONFIG_MAP_NAME=${CONFIG_MAP_NAME}-${DEPLOY_VERSION_ID}
VERSIONED_SECRET_NAME=${SECRET_NAME}-${DEPLOY_VERSION_ID}

echo "Setting target built image in the dc"
oc set image dc/${VERSIONED_APP_NAME} ${VERSIONED_APP_NAME}=${TARGET_IMAGESTREAM_TAG} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
TARGET_IMAGE_IN_DC=$(oc get dc ${VERSIONED_APP_NAME} -o jsonpath='{.spec.template.spec.containers[0].image}' ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM})
if [ "$TARGET_IMAGE_IN_DC" != "$TARGET_IMAGESTREAM_TAG" ]; then
  echo "ERROR: deployment Config image tag version is $TARGET_IMAGE_IN_DC but expected was ${TARGET_IMAGESTREAM_TAG}"
  exit 1
fi

# Set deployment config requests and/or limits
if [[ "${DEPLOYMENT_CPU_MEM_LIMITS_SET_ENABLED}" == "true" ]]; then
    echo "Updating deployment config to set limits values for cpu and memory"
    oc set resources dc ${VERSIONED_APP_NAME} --limits="cpu=${DEPLOYMENT_CPU_LIMITS},memory=${DEPLOYMENT_MEM_LIMITS}"
else
    echo "Deployment config limits setting disabled, skipping update..."
fi

if [[ "${DEPLOYMENT_CPU_MEM_REQUESTS_SET_ENABLED}" == "true" ]]; then
    echo "Updating deployment config to set requests values for cpu and memory"
    oc set resources dc ${VERSIONED_APP_NAME} --requests="cpu=${DEPLOYMENT_CPU_REQUESTS},memory=${DEPLOYMENT_MEM_REQUESTS}"
else
    echo "Deployment config requests setting disabled, skipping update..."
fi

# Update config map
if [[ "${CONFIG_MAP_ENABLED}" == "true" ]]; then
    echo "Updating config map ${CONFIG_MAP_NAME}"
    oc create configmap ${VERSIONED_CONFIG_MAP_NAME} --from-file=${CONFIG_MAP_RELATIVE_SOURCE_DIR} --dry-run=client -o yaml ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM} | oc replace ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM} -f -
    oc label configmap ${VERSIONED_CONFIG_MAP_NAME} app=${VERSIONED_APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
else
    echo "Config map disabled, skipping update..."
fi

# Update secret for environment variables
echo "Updating and binding secret ${VERSIONED_SECRET_NAME} from environment variables defined in file ${SECRET_ENV_FILE}"
oc create secret generic ${VERSIONED_SECRET_NAME} --from-env-file=${SECRET_ENV_FILE} --dry-run=client -o yaml ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM} | oc replace ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM} -f -
oc label secret ${VERSIONED_SECRET_NAME} app=${VERSIONED_APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
oc set env --from=secret/${VERSIONED_SECRET_NAME} dc/${VERSIONED_APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}

# Setup EAP liveness/readiness probes
if [[ "${LIVENESS_PROBE_ENABLED}" == "true" ]]; then
    echo "Updating liveness probe for health check"
    oc set probe dc/${VERSIONED_APP_NAME} --liveness --initial-delay-seconds=${LIVENESS_PROBE_INITIAL_DELAY_SECONDS} --period-seconds=${LIVENESS_PROBE_PERIOD_SECONDS} --success-threshold=${LIVENESS_PROBE_SUCCESS_THRESHOLD} --failure-threshold=${LIVENESS_PROBE_FAILURE_THRESHOLD} --timeout-seconds=${LIVENESS_PROBE_TIMEOUT_SECONDS} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM} -- /bin/bash '-c' /opt/eap/bin/livenessProbe.sh
else
    echo "Liveness probe disabled, skipping update..."
fi

if [[ "${READINESS_PROBE_ENABLED}" == "true" ]]; then
    echo "Updating readiness probe for health check"
    oc set probe dc/${VERSIONED_APP_NAME} --readiness --initial-delay-seconds=${READINESS_PROBE_INITIAL_DELAY_SECONDS} --period-seconds=${READINESS_PROBE_PERIOD_SECONDS} --success-threshold=${READINESS_PROBE_SUCCESS_THRESHOLD} --failure-threshold=${READINESS_PROBE_FAILURE_THRESHOLD} --timeout-seconds=${READINESS_PROBE_TIMEOUT_SECONDS} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM} -- /bin/bash '-c' /opt/eap/bin/readinessProbe.sh
else
    echo "Readiness probe disabled, skipping update..."
fi

# TODO update keystores on each deploy?

echo "Rolling out the dc"
oc rollout latest ${VERSIONED_APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}

echo ""
echo "Deployment of ${APP_NAMESPACE}/${APP_NAME} (v.${IMAGE_TAG} on ${DEPLOY_VERSION_ID} deployment version) successfully completed"