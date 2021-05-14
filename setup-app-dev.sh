#!/bin/bash
set -Eeuo pipefail
trap "echo Execution failed!" ERR

if [[ -f local.env ]]; then
    echo "Using variables in local.env file as input parameters (target environment variables must have 'DEV_' prefix)"
    source local.env

    ENV_PREFIX="DEV"

    OCP_VERSION="${ENV_PREFIX}_OCP_VERSION"
    OCP_VERSION=${!OCP_VERSION}

    OCP_API_URL="${ENV_PREFIX}_OCP_API_URL"
    OCP_API_URL=${!OCP_API_URL}

    CICD_ENGINE_EDIT_SA_TOKEN="${ENV_PREFIX}_CICD_ENGINE_EDIT_SA_TOKEN"
    CICD_ENGINE_EDIT_SA_TOKEN=${!CICD_ENGINE_EDIT_SA_TOKEN}
else
    if [[ $# -eq 0 ]]; then
        SCRIPT_NAME=`basename "$0"`
        echo "Usage:"
        echo "./$SCRIPT_NAME <ocp-version> <ocp-api-url> <cicd-engine-edit-token>"
        echo ""
        echo "Usage example:"
        echo "./$SCRIPT_NAME 4.6 https://api.openshiftcluster.company.com:6443 abcedf-1234512345-abcdef-343286-42131..."
        exit 0
    fi
    
    if [[ $# -ne 3 ]]; then
        echo "Illegal number of parameters"
        exit 1
    fi

    OCP_VERSION="$1"
    OCP_API_URL="$2"
    CICD_ENGINE_EDIT_SA_TOKEN="$3"
fi

BASE_CONFIG_DIR="app-config"
source ${BASE_CONFIG_DIR}/deployment-setup-config.env

TOKEN_PARAM="--token=${CICD_ENGINE_EDIT_SA_TOKEN}"
OCP_PARAM="--server=${OCP_API_URL}"
NAMESPACE_PARAM="-n ${APP_NAMESPACE}"
NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM="${NAMESPACE_PARAM} ${OCP_PARAM} ${TOKEN_PARAM}"

OCP_MAJOR_VERSION=$(echo ${OCP_VERSION} | cut -d '.' -f 1)
OCP_MINOR_VERSION=$(echo ${OCP_VERSION} | cut -d '.' -f 2)

B2I_CONFIG_RELATIVE_SOURCE_DIR="${BASE_CONFIG_DIR}/b2i-config"
B2I_BUILD_DIR="b2i"
CONFIG_MAP_NAME="${APP_NAME}-config"
CONFIG_MAP_RELATIVE_SOURCE_DIR="${BASE_CONFIG_DIR}/config/"
CONFIG_MAP_MOUNT_DIR="/opt/config"
SECRET_NAME="${APP_NAME}-config-data"
SECRET_ENV_FILE="${BASE_CONFIG_DIR}/config-data-secret.env"
KEYSTORES_RELATIVE_SOURCE_DIR="${BASE_CONFIG_DIR}/keystores"
HTTPS_KEYSTORE_SECRET_NAME="eap-ssl-secret"
JGROUPS_KEYSTORE_SECRET_NAME="eap-jgroup-secret"
SSO_TRUSTSTORE_SECRET_NAME="eap-truststore-secret"

echo "----------------------------------------------------------------------"
echo "PARAMETERS"
echo "----------------------------------------------------------------------"
echo "Openshift cluster: ${OCP_API_URL} (v.${OCP_VERSION})"
echo "Application namespace: ${APP_NAMESPACE}"
echo "Application name: ${APP_NAME}"
echo "Base imagestream: ${BASE_IMAGESTREAM}"
echo "Config map ${CONFIG_MAP_NAME} mapping content of relative path ${CONFIG_MAP_RELATIVE_SOURCE_DIR} to ${CONFIG_MAP_MOUNT_DIR}"
echo "Secret ${SECRET_NAME} mapping content of file ${SECRET_ENV_FILE}"
echo "HTTPS secret ${HTTPS_KEYSTORE_SECRET_NAME} mapping file ${KEYSTORES_RELATIVE_SOURCE_DIR}/eapkeystore.jks"
echo "JGroups secret ${JGROUPS_KEYSTORE_SECRET_NAME} mapping file ${KEYSTORES_RELATIVE_SOURCE_DIR}/eapjgroups.jceks"
echo "SSO truststore secret ${SSO_TRUSTSTORE_SECRET_NAME} mapping file ${KEYSTORES_RELATIVE_SOURCE_DIR}/truststore.jks"
echo "----------------------------------------------------------------------"
echo ""

echo "Preparing b2i directory"
rm -rf ${B2I_BUILD_DIR}
mkdir -p ${B2I_BUILD_DIR}
cp -r ${B2I_CONFIG_RELATIVE_SOURCE_DIR}/* ${B2I_BUILD_DIR}

# Setup build and deployment config resources
# For OC client from v4.5 --as-deployment-config flag is required in new-app command to generate a deployment config resource type instead of a deployment one
if [[ ${OCP_MAJOR_VERSION} -eq 3 ]]; then
    # OCP 3.x
    echo "Creating and building deployment resources based on imagestream ${BASE_IMAGESTREAM} (OpenShift v.${OCP_VERSION})"
    oc new-build --image-stream=${BASE_IMAGESTREAM} --name=${APP_NAME} --binary=true ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
    # Setup required env variable on build config to consider extensions directory
    oc set env bc/${APP_NAME} --overwrite --env=CUSTOM_INSTALL_DIRECTORIES=extensions ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
    oc start-build ${APP_NAME} --from-dir=${B2I_BUILD_DIR} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM} --follow

    oc new-app ${APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
elif [[ ${OCP_MAJOR_VERSION} -ge 4 ]]; then
    # OCP 4.x/5.x/...
    echo "Creating deployment resources on OCP ${OCP_VERSION} based on imagestream ${BASE_IMAGESTREAM} (OpenShift v.${OCP_VERSION})"
    DC_FLAG="--as-deployment-config"
    if [[ ${OCP_MAJOR_VERSION} -eq 4 && ${OCP_MINOR_VERSION} -le 4 ]]; then
        # OCP 4.1, 4.2, 4.3, 4.4
        DC_FLAG=""
    fi
    oc new-app --image-stream ${BASE_IMAGESTREAM} --binary --name=${APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM} ${DC_FLAG}

    # Setup required env variable on build config to consider extensions directory
    oc set env bc/${APP_NAME} --overwrite --env=CUSTOM_INSTALL_DIRECTORIES=extensions ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
else
    echo "Invalid or unsupported OpenShift version set in OCP_VERSION variable"
fi

# Scale dc to zero (stop any rollout running after dc creation)
# oc scale dc ${APP_NAME} --replicas=0

# Pause dc (stop any rollout running after dc creation)
oc rollout pause dc ${APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}

echo "Patching the deployment config to remove automatic trigger for config/image change"
# oc patch dc ${APP_NAME} -p '{"spec":{"triggers":[]}}' -o name ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
oc set triggers dc/${APP_NAME} --remove-all ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}

# Set deployment config requests and/or limits
if [[ "${DEPLOYMENT_CPU_MEM_LIMITS_SET_ENABLED}" == "true" ]]; then
    echo "Patching deployment config to set limits values for cpu and memory"
    oc set resources dc ${APP_NAME} --limits="cpu=${DEPLOYMENT_CPU_LIMITS},memory=${DEPLOYMENT_MEM_LIMITS}" ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
else
    echo "Deployment config limits setting disabled, skipping..."
fi

if [[ "${DEPLOYMENT_CPU_MEM_REQUESTS_SET_ENABLED}" == "true" ]]; then
    echo "Patching deployment config to set requests values for cpu and memory"
    oc set resources dc ${APP_NAME} --requests="cpu=${DEPLOYMENT_CPU_REQUESTS},memory=${DEPLOYMENT_MEM_REQUESTS}" ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
else
    echo "Deployment config requests setting disabled, skipping..."
fi

# Set deployment config for deploment config (by default a Rolling strategy is set)
if [[ "${DEPLOYMENT_STRATEGY_RECREATE_ENABLED}" == "true" ]]; then
    echo "Setting \"Recreate\" deployment strategy for deployment config"
    oc patch dc ${APP_NAME} -p "{\"spec\":{\"strategy\":{\"type\":\"Recreate\"}}}" ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
else
    echo "Deployment strategy \"Recreate\" disabled, using default \"Rolling\" strategy"
fi

# Expose app using route 
if [[ "${HTTPS_ROUTE_ENABLED}" == "true" ]]; then
    echo "Creating https route to expose the app"
    oc create route passthrough ${APP_NAME} --service ${APP_NAME} --port=${HTTPS_ROUTE_INTERNAL_PORT} --insecure-policy=Redirect ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
else
    echo "Creating http route to expose the app"
    oc expose svc/${APP_NAME} --name=${APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
fi

# Setup config map
if [[ "${CONFIG_MAP_ENABLED}" == "true" ]]; then
    echo "Creating and binding config map ${CONFIG_MAP_NAME}"
    oc create configmap ${CONFIG_MAP_NAME} --from-file=${CONFIG_MAP_RELATIVE_SOURCE_DIR} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
    oc label configmap ${CONFIG_MAP_NAME} app=${APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
    oc set volumes dc/${APP_NAME} --add --name=${CONFIG_MAP_NAME} --configmap-name=${CONFIG_MAP_NAME} -m ${CONFIG_MAP_MOUNT_DIR} --overwrite -t configmap ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
else
    echo "Config map disabled, skipping..."
fi

# Setup secret for environment variables
echo "Creating and binding secret ${SECRET_NAME} from environment variables defined in file ${SECRET_ENV_FILE}"
oc create secret generic ${SECRET_NAME} --from-env-file=${SECRET_ENV_FILE} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
oc label secret ${SECRET_NAME} app=${APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
oc set env --from=secret/${SECRET_NAME} dc/${APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}

# Setup EAP liveness/readiness probes
if [[ "${LIVENESS_PROBE_ENABLED}" == "true" ]]; then
    echo "Creating liveness probe for health check"
    oc set probe dc/${APP_NAME} --liveness --initial-delay-seconds=${LIVENESS_PROBE_INITIAL_DELAY_SECONDS} --period-seconds=${LIVENESS_PROBE_PERIOD_SECONDS} --success-threshold=${LIVENESS_PROBE_SUCCESS_THRESHOLD} --failure-threshold=${LIVENESS_PROBE_FAILURE_THRESHOLD} --timeout-seconds=${LIVENESS_PROBE_TIMEOUT_SECONDS} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM} -- /bin/bash '-c' /opt/eap/bin/livenessProbe.sh
else
    echo "Liveness probe disabled, skipping..."
fi

if [[ "${READINESS_PROBE_ENABLED}" == "true" ]]; then
    echo "Creating readiness probe for health check"
    oc set probe dc/${APP_NAME} --readiness --initial-delay-seconds=${READINESS_PROBE_INITIAL_DELAY_SECONDS} --period-seconds=${READINESS_PROBE_PERIOD_SECONDS} --success-threshold=${READINESS_PROBE_SUCCESS_THRESHOLD} --failure-threshold=${READINESS_PROBE_FAILURE_THRESHOLD} --timeout-seconds=${READINESS_PROBE_TIMEOUT_SECONDS} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM} -- /bin/bash '-c' /opt/eap/bin/readinessProbe.sh
else
    echo "Readiness probe disabled, skipping..."
fi

# Setup EAP keystores and SSO truststore

if [[ "${EAP_SSL_KEYSTORE_ENABLED}" == "true" ]]; then
    echo "Creating and linking secret for EAP SSL keystore to the default service account"
    oc create secret generic ${HTTPS_KEYSTORE_SECRET_NAME} --from-file=${KEYSTORES_RELATIVE_SOURCE_DIR}/eapkeystore.jks ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
    oc label secret ${HTTPS_KEYSTORE_SECRET_NAME} app=${APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
    oc secrets link default ${HTTPS_KEYSTORE_SECRET_NAME} --for=mount ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
    echo "Creating and binding volume for EAP SSL keystore"
    oc set volume dc/${APP_NAME} --add --name="eap-keystore-volume" --type=secret --secret-name="${HTTPS_KEYSTORE_SECRET_NAME}" --mount-path="/etc/eap-secret-volume" ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
else
    echo "EAP SSL keystore disabled, skipping..."
fi

if [[ "${EAP_JGROUPS_KEYSTORE_ENABLED}" == "true" ]]; then
    echo "Creating and linking secret for EAP JGroups keystore to the default service account"
    oc create secret generic ${JGROUPS_KEYSTORE_SECRET_NAME} --from-file=${KEYSTORES_RELATIVE_SOURCE_DIR}/eapjgroups.jceks ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
    oc label secret ${JGROUPS_KEYSTORE_SECRET_NAME} app=${APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
    oc secrets link default ${JGROUPS_KEYSTORE_SECRET_NAME} --for=mount ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
    echo "Creating and binding volume for EAP JGroups keystore"
    oc set volume dc/${APP_NAME} --add --name="eap-jgroups-keystore-volume" --type=secret --secret-name="${JGROUPS_KEYSTORE_SECRET_NAME}" --mount-path="/etc/jgroups-encrypt-secret-volume" ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
else
    echo "EAP JGroups keystore disabled, skipping..."
fi

if [[ "${EAP_SSO_TRUSTSTORE_ENABLED}" == "true" ]]; then
    echo "Creating and linking secret for EAP SSO truststore to the default service account"
    oc create secret generic ${SSO_TRUSTSTORE_SECRET_NAME} --from-file=${KEYSTORES_RELATIVE_SOURCE_DIR}/truststore.jks ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
    oc label secret ${SSO_TRUSTSTORE_SECRET_NAME} app=${APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
    oc secrets link default ${SSO_TRUSTSTORE_SECRET_NAME} --for=mount ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
    echo "Creating and binding volume for EAP SSO truststore"
    oc set volume dc/${APP_NAME} --add --name="eap-truststore-volume" --type=secret --secret-name="${SSO_TRUSTSTORE_SECRET_NAME}" --mount-path="/etc/eap-truststore-secret-volume" ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
else
    echo "EAP SSO truststore disabled, skipping..."
fi

# Resume dc
oc rollout resume dc ${APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}

echo ""
echo "Setup for ${APP_NAMESPACE}/${APP_NAME} deployment successfully completed"

