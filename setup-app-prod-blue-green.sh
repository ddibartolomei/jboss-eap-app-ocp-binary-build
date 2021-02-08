#!/bin/bash
set -Eeuo pipefail
trap "echo Execution failed!" ERR

if [[ -f local.env ]]; then
    echo "Using variables in local.env file as input parameters (target environment variables must have 'PROD_' prefix)"
    source local.env

    if [[ $# -ne 1 ]]; then
        SCRIPT_NAME=`basename "$0"`
        echo "Usage:"
        echo "./$SCRIPT_NAME <first-image-tag>"
        echo ""
        echo "Usage example:"
        echo "./$SCRIPT_NAME 1.0"
        exit 1
    fi

    IMAGE_TAG="$1"

    ENV_PREFIX="PROD"

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
        echo "./$SCRIPT_NAME <first-image-tag> <ocp-version> <ocp-api-url> <cicd-engine-edit-token>"
        echo ""
        echo "Usage example:"
        echo "./$SCRIPT_NAME 1.0 4.6 https://api.openshiftcluster.company.com:6443 abcedf-1234512345-abcdef-343286-42131..."
        exit 0
    fi
    
    if [[ $# -ne 4 ]]; then
        echo "Illegal number of parameters"
        exit 1
    fi

    IMAGE_TAG="$1"
    OCP_VERSION="$2"
    OCP_API_URL="$3"
    CICD_ENGINE_EDIT_SA_TOKEN="$4"
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
echo "First image tag: ${IMAGE_TAG}"
echo "Config map ${CONFIG_MAP_NAME} mapping content of relative path ${CONFIG_MAP_RELATIVE_SOURCE_DIR} to ${CONFIG_MAP_MOUNT_DIR}"
echo "Secret ${SECRET_NAME} mapping content of file ${SECRET_ENV_FILE}"
echo "HTTPS secret ${HTTPS_KEYSTORE_SECRET_NAME} mapping file ${KEYSTORES_RELATIVE_SOURCE_DIR}/eapkeystore.jks"
echo "JGroups secret ${JGROUPS_KEYSTORE_SECRET_NAME} mapping file ${KEYSTORES_RELATIVE_SOURCE_DIR}/eapjgroups.jceks"
echo "SSO truststore secret ${SSO_TRUSTSTORE_SECRET_NAME} mapping file ${KEYSTORES_RELATIVE_SOURCE_DIR}/truststore.jks"
echo "----------------------------------------------------------------------"
echo ""

# For OC client from v4.5 --as-deployment-config flag is required in new-app command to generate a deployment config resource type instead of a deployment one
DC_FLAG="--as-deployment-config"
if [[ ${OCP_MAJOR_VERSION} -eq 3 ]] || [[ ${OCP_MAJOR_VERSION} -eq 4 && ${OCP_MINOR_VERSION} -le 4 ]]; then
    # OCP 3.x, 4.1, 4.2, 4.3, 4.4
    DC_FLAG=""
fi

DEPLOYMENT_VERSIONS="blue green"
# Iterate the string variable using for loop
for DEPLOY_VERSION_ID in $DEPLOYMENT_VERSIONS; do
    echo "Setup ${DEPLOY_VERSION_ID} version of deployment resources"
    VERSIONED_APP_NAME=${APP_NAME}-${DEPLOY_VERSION_ID}
    VERSIONED_CONFIG_MAP_NAME=${CONFIG_MAP_NAME}-${DEPLOY_VERSION_ID}
    VERSIONED_SECRET_NAME=${SECRET_NAME}-${DEPLOY_VERSION_ID}
    VERSIONED_HTTPS_KEYSTORE_SECRET_NAME=${HTTPS_KEYSTORE_SECRET_NAME}-${DEPLOY_VERSION_ID}
    VERSIONED_JGROUPS_KEYSTORE_SECRET_NAME=${JGROUPS_KEYSTORE_SECRET_NAME}-${DEPLOY_VERSION_ID}
    VERSIONED_SSO_TRUSTSTORE_SECRET_NAME=${SSO_TRUSTSTORE_SECRET_NAME}-${DEPLOY_VERSION_ID}

    echo "Creating and building deployment resources"
    oc new-app ${APP_NAMESPACE}/${APP_NAME}:${IMAGE_TAG} --name=${VERSIONED_APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM} ${DC_FLAG} 

    # Scale dc to zero (stop any rollout running after dc creation)
    # oc scale dc ${VERSIONED_APP_NAME} --replicas=0

    # Pause dc (stop any rollout running after dc creation)
    oc rollout pause dc ${VERSIONED_APP_NAME}

    # Delete unuseful imagestream created by oc new-app command (both green and blue dc will shar the same imagestream name ${APP_NAMESPACE}/${APP_NAME})
    oc delete is/${VERSIONED_APP_NAME}

    echo "Patching the deployment config to remove automatic trigger for config/image change"
    # oc patch dc ${APP_NAME} -p '{"spec":{"triggers":[]}}' -o name ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
    oc set triggers dc/${VERSIONED_APP_NAME} --remove-all ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}

    # Set deployment config requests and/or limits
    if [[ "${DEPLOYMENT_CPU_MEM_LIMITS_SET_ENABLED}" == "true" ]]; then
        echo "Patching deployment config to set limits values for cpu and memory"
        oc set resources dc ${VERSIONED_APP_NAME} --limits="cpu=${DEPLOYMENT_CPU_LIMITS},memory=${DEPLOYMENT_MEM_LIMITS}"
    else
        echo "Deployment config limits setting disabled, skipping..."
    fi

    if [[ "${DEPLOYMENT_CPU_MEM_REQUESTS_SET_ENABLED}" == "true" ]]; then
        echo "Patching deployment config to set requests values for cpu and memory"
        oc set resources dc ${VERSIONED_APP_NAME} --requests="cpu=${DEPLOYMENT_CPU_REQUESTS},memory=${DEPLOYMENT_MEM_REQUESTS}"
    else
        echo "Deployment config requests setting disabled, skipping..."
    fi

    # Set deployment config for deploment config (by default a Rolling strategy is set)
    if [[ "${DEPLOYMENT_STRATEGY_RECREATE_ENABLED}" == "true" ]]; then
        echo "Setting \"Recreate\" deployment strategy for deployment config"
        oc patch dc ${VERSIONED_APP_NAME} -p "{\"spec\":{\"strategy\":{\"type\":\"Recreate\"}}}"
    else
        echo "Deployment strategy \"Recreate\" disabled, using default \"Rolling\" strategy"
    fi

    # Setup config map
    if [[ "${CONFIG_MAP_ENABLED}" == "true" ]]; then
        echo "Creating and binding config map ${VERSIONED_CONFIG_MAP_NAME}"
        oc create configmap ${VERSIONED_CONFIG_MAP_NAME} --from-file=${CONFIG_MAP_RELATIVE_SOURCE_DIR} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
        oc label configmap ${VERSIONED_CONFIG_MAP_NAME} app=${VERSIONED_APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
        oc set volumes dc/${VERSIONED_APP_NAME} --add --name=${CONFIG_MAP_NAME} --configmap-name=${VERSIONED_CONFIG_MAP_NAME} -m ${CONFIG_MAP_MOUNT_DIR} --overwrite -t configmap ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
    else
        echo "Config map disabled, skipping..."
    fi

    # Setup secret for environment variables
    echo "Creating and binding secret ${VERSIONED_SECRET_NAME} from environment variables defined in file ${SECRET_ENV_FILE}"
    oc create secret generic ${VERSIONED_SECRET_NAME} --from-env-file=${SECRET_ENV_FILE} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
    oc label secret ${VERSIONED_SECRET_NAME} app=${VERSIONED_APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
    oc set env --from=secret/${VERSIONED_SECRET_NAME} dc/${VERSIONED_APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}

    # Setup EAP liveness/readiness probes
    if [[ "${LIVENESS_PROBE_ENABLED}" == "true" ]]; then
        echo "Creating liveness probe for health check"
        oc set probe dc/${VERSIONED_APP_NAME} --liveness --initial-delay-seconds=${LIVENESS_PROBE_INITIAL_DELAY_SECONDS} --period-seconds=${LIVENESS_PROBE_PERIOD_SECONDS} --success-threshold=${LIVENESS_PROBE_SUCCESS_THRESHOLD} --failure-threshold=${LIVENESS_PROBE_FAILURE_THRESHOLD} --timeout-seconds=${LIVENESS_PROBE_TIMEOUT_SECONDS} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM} -- /bin/bash '-c' /opt/eap/bin/livenessProbe.sh
    else
        echo "Liveness probe disabled, skipping..."
    fi

    if [[ "${READINESS_PROBE_ENABLED}" == "true" ]]; then
        echo "Creating readiness probe for health check"
        oc set probe dc/${VERSIONED_APP_NAME} --readiness --initial-delay-seconds=${READINESS_PROBE_INITIAL_DELAY_SECONDS} --period-seconds=${READINESS_PROBE_PERIOD_SECONDS} --success-threshold=${READINESS_PROBE_SUCCESS_THRESHOLD} --failure-threshold=${READINESS_PROBE_FAILURE_THRESHOLD} --timeout-seconds=${READINESS_PROBE_TIMEOUT_SECONDS} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM} -- /bin/bash '-c' /opt/eap/bin/readinessProbe.sh
    else
        echo "Readiness probe disabled, skipping..."
    fi

    # Setup EAP keystores and SSO truststore

    if [[ "${EAP_SSL_KEYSTORE_ENABLED}" == "true" ]]; then
        echo "Creating and linking secret for EAP SSL keystore to the default service account"
        oc create secret generic ${VERSIONED_HTTPS_KEYSTORE_SECRET_NAME} --from-file=${KEYSTORES_RELATIVE_SOURCE_DIR}/eapkeystore.jks ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
        oc label secret ${VERSIONED_HTTPS_KEYSTORE_SECRET_NAME} app=${VERSIONED_APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
        oc secrets link default ${VERSIONED_HTTPS_KEYSTORE_SECRET_NAME} --for=mount ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
        echo "Creating and binding volume for EAP SSL keystore"
        oc set volume dc/${VERSIONED_APP_NAME} --add --name="eap-keystore-volume" --type=secret --secret-name="${VERSIONED_HTTPS_KEYSTORE_SECRET_NAME}" --mount-path="/etc/eap-secret-volume" ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
    else
        echo "EAP SSL keystore disabled, skipping..."
    fi

    if [[ "${EAP_JGROUPS_KEYSTORE_ENABLED}" == "true" ]]; then
        echo "Creating and linking secret for EAP JGroups keystore to the default service account"
        oc create secret generic ${VERSIONED_JGROUPS_KEYSTORE_SECRET_NAME} --from-file=${KEYSTORES_RELATIVE_SOURCE_DIR}/eapjgroups.jceks ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
        oc label secret ${VERSIONED_JGROUPS_KEYSTORE_SECRET_NAME} app=${VERSIONED_APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
        oc secrets link default ${VERSIONED_JGROUPS_KEYSTORE_SECRET_NAME} --for=mount ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
        echo "Creating and binding volume for EAP JGroups keystore"
        oc set volume dc/${VERSIONED_APP_NAME} --add --name="eap-jgroups-keystore-volume" --type=secret --secret-name="${VERSIONED_JGROUPS_KEYSTORE_SECRET_NAME}" --mount-path="/etc/jgroups-encrypt-secret-volume" ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
    else
        echo "EAP JGroups keystore disabled, skipping..."
    fi

    if [[ "${EAP_SSO_TRUSTSTORE_ENABLED}" == "true" ]]; then
        echo "Creating and linking secret for EAP SSO truststore to the default service account"
        oc create secret generic ${VERSIONED_SSO_TRUSTSTORE_SECRET_NAME} --from-file=${KEYSTORES_RELATIVE_SOURCE_DIR}/truststore.jks ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
        oc label secret ${VERSIONED_SSO_TRUSTSTORE_SECRET_NAME} app=${VERSIONED_APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
        oc secrets link default ${VERSIONED_SSO_TRUSTSTORE_SECRET_NAME} --for=mount ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
        echo "Creating and binding volume for EAP SSO truststore"
        oc set volume dc/${VERSIONED_APP_NAME} --add --name="eap-truststore-volume" --type=secret --secret-name="${VERSIONED_SSO_TRUSTSTORE_SECRET_NAME}" --mount-path="/etc/eap-truststore-secret-volume" ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
    else
        echo "EAP SSO truststore disabled, skipping..."
    fi

    # Resume dc
    oc rollout resume dc ${VERSIONED_APP_NAME}

    echo ""
done

# Expose app using route (by default start pointing to blue version)
if [[ "${HTTPS_ROUTE_ENABLED}" == "true" ]]; then
    echo "Creating https route to expose the app (exposing 'blue' deployment version by default)"
    oc create route passthrough ${APP_NAME} --service ${APP_NAME}-blue --port=${HTTPS_ROUTE_INTERNAL_PORT} --insecure-policy=Redirect ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
else
    echo "Creating http route to expose the app (exposing 'blue' deployment version by default)"
    oc expose svc/${APP_NAME}-blue ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}
fi

# Add label to the imagestream
oc label is ${APP_NAME} app=${APP_NAME} ${NAMESPACE_OCP_TOKEN_COMPOSITE_PARAM}

echo ""
echo "Setup for ${APP_NAMESPACE}/${APP_NAME} deployment successfully completed"

 