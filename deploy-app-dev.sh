#!/bin/bash
set -Eeuo pipefail
trap "echo Execution failed!" ERR

RC_BUILD=false

if [[ -f local.env ]]; then
    echo "Using variables in local.env file as input parameters (target environment variables must have 'DEV_' prefix)"
    source local.env

    ENV_PREFIX="DEV"

    IMAGE_REGISTRY_HOST_PORT_INTERNAL="${ENV_PREFIX}_IMAGE_REGISTRY_HOST_PORT_INTERNAL"
    IMAGE_REGISTRY_HOST_PORT_INTERNAL=${!IMAGE_REGISTRY_HOST_PORT_INTERNAL}

    OCP_API_URL="${ENV_PREFIX}_OCP_API_URL"
    OCP_API_URL=${!OCP_API_URL}

    CICD_ENGINE_EDIT_SA_TOKEN="${ENV_PREFIX}_CICD_ENGINE_EDIT_SA_TOKEN"
    CICD_ENGINE_EDIT_SA_TOKEN=${!CICD_ENGINE_EDIT_SA_TOKEN}

    if [[ $# -eq 1 && "$1"=="RC" ]]; then
        RC_BUILD=true
    fi
else
    if [[ $# -eq 0 ]]; then
        SCRIPT_NAME=`basename "$0"`
        echo "Usage:"
        echo "./$SCRIPT_NAME <internal-image-registry-host-port> <ocp-api-url> <cicd-engine-edit-token> [<RC>]"
        echo ""
        echo "  <RC> : optional parameter, must be 'RC' for Release Candidate builds or omitted otherwise"
        echo ""
        echo "Usage example:"
        echo "./$SCRIPT_NAME image-registry.openshift-image-registry.svc:5000 https://api.openshiftcluster.company.com:6443 \\
                    abcedf-1234512345-abcdef-343286-42131... RC"
        echo "  Execute a build and deploy using pom.xml version as is, since it is a Release Candidate (RC) build"
        echo ""
        echo "./$SCRIPT_NAME docker-registry.default.svc:5000 https://api.openshiftcluster.company.com:6443 \\
                    abcedf-1234512345-abcdef-343286-42131..."
        echo "  Execute a build and deploy using pom.xml version and adding the git changeset (e.g. 1.2-e834a58)"
        exit 0
    fi
    
    if [[ $# -ge 5 || $# -lt 3 ]]; then
        echo "Illegal number of parameters"
        exit 1
    fi

    IMAGE_REGISTRY_HOST_PORT_INTERNAL="$1"
    OCP_API_URL="$2"
    CICD_ENGINE_EDIT_SA_TOKEN="$3"

    RC_BUILD=false
    if [[ $# -eq 4 && "$4"=="RC" ]]; then
        RC_BUILD=true
    fi
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
echo "RC build: ${RC_BUILD}"
echo "Internal image registry: ${IMAGE_REGISTRY_HOST_PORT_INTERNAL}"
echo "Config map ${CONFIG_MAP_NAME} mapping content of relative path ${CONFIG_MAP_RELATIVE_SOURCE_DIR} to ${CONFIG_MAP_MOUNT_DIR}"
echo "Secret ${SECRET_NAME} mapping content of file ${SECRET_ENV_FILE}"
echo "----------------------------------------------------------------------"
echo ""

echo "Reading project version from pom.xml"
BUILD_TAG=$(mvn -q -Dexec.executable=echo -Dexec.args='${project.version}' --non-recursive exec:exec)
if [[ "${RC_BUILD}" == "false" ]]; then
    CHANGESET="$(git rev-parse --short HEAD)"
    BUILD_TAG="${BUILD_TAG}_${CHANGESET}"
fi
echo "Build tag set to: ${BUILD_TAG}"

# Set full versione inside pom.xml for this build (remote repository will not be updated)
if [[ "${UPDATE_POM_VERSION_ENABLED}" == "true" ]]; then
    mvn versions:set -DgenerateBackupPoms=false -DnewVersion=${BUILD_TAG}
fi

TARGET_IMAGE="${IMAGE_REGISTRY_HOST_PORT_INTERNAL}/${APP_NAMESPACE}/${APP_NAME}:${BUILD_TAG}"

# Building artifact and preparing image build
echo "Building app artifact"
mvn clean package -Dmaven.javadoc.skip=true -DskipTests

# TODO archive artifact on Nexus

echo "Preparing b2i directory"
rm -rf ${B2I_BUILD_DIR}
mkdir -p ${B2I_BUILD_DIR}
cp -r ${B2I_CONFIG_RELATIVE_SOURCE_DIR}/* ${B2I_BUILD_DIR}

echo "Copying artifact ${APP_RELATIVE_DIR}/${APP_ARTIFACT_FILE} to b2i directory"
cp ${APP_RELATIVE_DIR}/${APP_ARTIFACT_FILE} ${B2I_BUILD_DIR}

# Starting build config and patching deployment config
echo "Patching bc output image tag to ${BUILD_TAG}"
oc patch bc ${APP_NAME} -o name -p "{\"spec\":{\"output\":{\"to\":{\"kind\":\"ImageStreamTag\",\"name\":\"${APP_NAME}:${BUILD_TAG}\"}}}}" ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}

echo "Building target app image ${TARGET_IMAGE}"
oc start-build ${APP_NAME} --from-dir=${B2I_BUILD_DIR} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM} --follow

echo "Setting target built image in the dc"
oc set image dc/${APP_NAME} ${APP_NAME}=${TARGET_IMAGE} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
TARGET_IMAGE_IN_DC=$(oc get dc ${APP_NAME} -o jsonpath='{.spec.template.spec.containers[0].image}' ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM})
if [ "$TARGET_IMAGE_IN_DC" != "$TARGET_IMAGE" ]; then
  echo "ERROR: deployment Config image tag version is $TARGET_IMAGE_IN_DC but expected was ${TARGET_IMAGE}"
  exit 1
fi

# Set deployment config requests and/or limits
if [[ "${DEPLOYMENT_CPU_MEM_LIMITS_SET_ENABLED}" == "true" ]]; then
    echo "Updating deployment config to set limits values for cpu and memory"
    oc set resources dc ${APP_NAME} --limits="cpu=${DEPLOYMENT_CPU_LIMITS},memory=${DEPLOYMENT_MEM_LIMITS}" ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
else
    echo "Deployment config limits setting disabled, skipping update..."
fi

if [[ "${DEPLOYMENT_CPU_MEM_REQUESTS_SET_ENABLED}" == "true" ]]; then
    echo "Updating deployment config to set requests values for cpu and memory"
    oc set resources dc ${APP_NAME} --requests="cpu=${DEPLOYMENT_CPU_REQUESTS},memory=${DEPLOYMENT_MEM_REQUESTS}" ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
else
    echo "Deployment config requests setting disabled, skipping update..."
fi

# Update config map
if [[ "${CONFIG_MAP_ENABLED}" == "true" ]]; then
    echo "Updating config map ${CONFIG_MAP_NAME}"
    oc create configmap ${CONFIG_MAP_NAME} --from-file=${CONFIG_MAP_RELATIVE_SOURCE_DIR} --dry-run -o yaml ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM} | oc replace ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM} -f -
    oc label configmap ${CONFIG_MAP_NAME} app=${APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
else
    echo "Config map disabled, skipping update..."
fi

# Update secret for environment variables
echo "Updating and binding secret ${SECRET_NAME} from environment variables defined in file ${SECRET_ENV_FILE}"
oc create secret generic ${SECRET_NAME} --from-env-file=${SECRET_ENV_FILE} --dry-run -o yaml ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM} | oc replace ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM} -f -
oc label secret ${SECRET_NAME} app=${APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
oc set env --from=secret/${SECRET_NAME} dc/${APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}

# Setup EAP liveness/readiness probes
if [[ "${LIVENESS_PROBE_ENABLED}" == "true" ]]; then
    echo "Updating liveness probe for health check"
    oc set probe dc/${APP_NAME} --liveness --initial-delay-seconds=${LIVENESS_PROBE_INITIAL_DELAY_SECONDS} --period-seconds=${LIVENESS_PROBE_PERIOD_SECONDS} --success-threshold=${LIVENESS_PROBE_SUCCESS_THRESHOLD} --failure-threshold=${LIVENESS_PROBE_FAILURE_THRESHOLD} --timeout-seconds=${LIVENESS_PROBE_TIMEOUT_SECONDS} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM} -- /bin/bash '-c' /opt/eap/bin/livenessProbe.sh
else
    echo "Liveness probe disabled, skipping update..."
fi

if [[ "${READINESS_PROBE_ENABLED}" == "true" ]]; then
    echo "Updating readiness probe for health check"
    oc set probe dc/${APP_NAME} --readiness --initial-delay-seconds=${READINESS_PROBE_INITIAL_DELAY_SECONDS} --period-seconds=${READINESS_PROBE_PERIOD_SECONDS} --success-threshold=${READINESS_PROBE_SUCCESS_THRESHOLD} --failure-threshold=${READINESS_PROBE_FAILURE_THRESHOLD} --timeout-seconds=${READINESS_PROBE_TIMEOUT_SECONDS} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM} -- /bin/bash '-c' /opt/eap/bin/readinessProbe.sh
else
    echo "Readiness probe disabled, skipping update..."
fi

# TODO update keystores?

echo "Rolling out the dc"
oc rollout latest ${APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}

echo ""
echo "Deployment of ${APP_NAMESPACE}/${APP_NAME} (v.${BUILD_TAG}) successfully completed"