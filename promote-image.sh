#!/bin/bash
set -Eeuo pipefail
trap "echo Execution failed!" ERR

SKOPEO_COMMAND="skopeo"
# SKOPEO_COMMAND="podmanr run --rm quay.io/skopeo/stable"

if [[ -f local.env ]]; then
    echo "Using variables in local.env file as input parameters"
    source local.env

    if [[ $# -ne 3 ]]; then
        SCRIPT_NAME=`basename "$0"`
        echo "Usage:"
        echo "./$SCRIPT_NAME <tag> <source-env-name> <target-env-name>"
        echo ""
        echo "  <source-env-name> and <target-env-name> are used as prefixes for environment variables in local.env file."
        echo "  E.g.: if <target-env-name> is 'PROD', variables with 'PROD_' prefix are going to be considered for"
        echo "  target environment"
        echo ""
        echo "Usage example:"
        echo "./$SCRIPT_NAME 1.2 DEV PROD"
        exit 1
    fi
    
    BUILD_TAG="$1"
    SOURCE_PREFIX="$2"
    TARGET_PREFIX="$3"

    SOURCE_IMAGE_REGISTRY_HOST_PORT="${SOURCE_PREFIX}_IMAGE_REGISTRY_HOST_PORT"
    SOURCE_IMAGE_REGISTRY_HOST_PORT=${!SOURCE_IMAGE_REGISTRY_HOST_PORT}
    TARGET_IMAGE_REGISTRY_HOST_PORT="${TARGET_PREFIX}_IMAGE_REGISTRY_HOST_PORT"
    TARGET_IMAGE_REGISTRY_HOST_PORT=${!TARGET_IMAGE_REGISTRY_HOST_PORT}

    SOURCE_IMAGE_REGISTRY_USERNAME="${SOURCE_PREFIX}_IMAGE_REGISTRY_USERNAME"
    SOURCE_IMAGE_REGISTRY_USERNAME=${!SOURCE_IMAGE_REGISTRY_USERNAME}
    TARGET_IMAGE_REGISTRY_USERNAME="${TARGET_PREFIX}_IMAGE_REGISTRY_USERNAME"
    TARGET_IMAGE_REGISTRY_USERNAME=${!TARGET_IMAGE_REGISTRY_USERNAME}

    SOURCE_IMAGE_REGISTRY_PASSWORD="${SOURCE_PREFIX}_IMAGE_REGISTRY_PASSWORD"
    SOURCE_IMAGE_REGISTRY_PASSWORD=${!SOURCE_IMAGE_REGISTRY_PASSWORD}
    TARGET_IMAGE_REGISTRY_PASSWORD="${TARGET_PREFIX}_IMAGE_REGISTRY_PASSWORD"
    TARGET_IMAGE_REGISTRY_PASSWORD=${!TARGET_IMAGE_REGISTRY_PASSWORD}
else
    if [[ $# -eq 0 ]]; then
        SCRIPT_NAME=`basename "$0"`
        echo "Usage:"
        echo "./$SCRIPT_NAME <tag> <app-namespace> <app-name> \\"
        echo "                   <source-registry-host-port> <target-registry-host-port> \\"
        echo "                   <source-registry-username> <source-registry-password> \\"
        echo "                   <target-registry-username> <target-registry-password> \\"
        echo "                   <force-override>"
        echo ""
        echo "  <force-override> : can be 'force' to force image override on target registry or 'unforce' to stop if the image already exists"
        echo ""
        echo "Usage example:"
        echo "./$SCRIPT_NAME 1.2 my-namespace my-app \\"
        echo "                   default-route-openshift-image-registry.openshiftcluster1.company.com \\"
        echo "                   default-route-openshift-image-registry.openshiftcluster2.company.com \\"
        echo "                   jsmith@company.com abcedf-1234512345-... \\"
        echo "                   jsmith@company.com fedcba-5432154321-... \\"
        echo "                   force"
        exit 0
    fi
    
    if [[ $# -ne 10 ]]; then
        echo "Illegal number of parameters"
        exit 1
    fi

    BUILD_TAG="$1"
    APP_NAMESPACE="$2"
    APP_NAME="$3"
    SOURCE_IMAGE_REGISTRY_HOST_PORT="$4"
    TARGET_IMAGE_REGISTRY_HOST_PORT="$5"
    SOURCE_IMAGE_REGISTRY_USERNAME="$6"
    SOURCE_IMAGE_REGISTRY_PASSWORD="$7"
    TARGET_IMAGE_REGISTRY_USERNAME="$8"
    TARGET_IMAGE_REGISTRY_PASSWORD="$9"

    if [[ "${10}" == "force" ]]; then
        OVERRIDE_IMAGE_ON_PROMOTION="true"
    elif [[ "${10}" == "unforce" ]]; then
        OVERRIDE_IMAGE_ON_PROMOTION="false"
    else
        echo "Illegal parameter force-override: ${10}"
        exit 1
    fi
fi

echo "----------------------------------------------------------------------"
echo "PARAMETERS"
echo "----------------------------------------------------------------------"
echo "Application namespace: ${APP_NAMESPACE}"
echo "Application name: ${APP_NAME}"
echo "Image tag: ${BUILD_TAG}"
echo "Source registry host/port: ${SOURCE_IMAGE_REGISTRY_HOST_PORT}"
echo "Source registry username: ${SOURCE_IMAGE_REGISTRY_USERNAME}"
echo "Target registry host/port: ${TARGET_IMAGE_REGISTRY_HOST_PORT}"
echo "Target registry username: ${TARGET_IMAGE_REGISTRY_USERNAME}"
echo "Override image: ${OVERRIDE_IMAGE_ON_PROMOTION}"
echo "----------------------------------------------------------------------"
echo ""

SOURCE_IMAGE="${SOURCE_IMAGE_REGISTRY_HOST_PORT}/${APP_NAMESPACE}/${APP_NAME}:${BUILD_TAG}"
TARGET_IMAGE="${TARGET_IMAGE_REGISTRY_HOST_PORT}/${APP_NAMESPACE}/${APP_NAME}:${BUILD_TAG}"

# Check the image does not already exists in the target registry
# A skopeo inspect command returns an error code:
# - >0 if and error occured or the image/tag has not been found
# - =0 if the image/tag exists
# N.B.: trap and exit-on-error setting are disabled (and enabled again after return code check) to avoid exiting on error return
echo "Checking if the image/tag exists on the target registry"
echo "Target image ${TARGET_IMAGE}"
set +Eeuo pipefail
trap - ERR
${SKOPEO_COMMAND} inspect --creds ${TARGET_IMAGE_REGISTRY_USERNAME}:${TARGET_IMAGE_REGISTRY_PASSWORD} --tls-verify=false docker://${TARGET_IMAGE} > /dev/null 2>&1

# CHECK_TARGET_IMAGE=$(${SKOPEO_COMMAND} inspect --creds ${TARGET_IMAGE_REGISTRY_USERNAME}:${TARGET_IMAGE_REGISTRY_PASSWORD} --tls-verify=false docker://${TARGET_IMAGE} > /dev/null 2>&1)

CHECK_TARGET_IMAGE_RESULT=$?
set -Eeuo pipefail
trap "echo Execution failed!" ERR

if [[ $CHECK_TARGET_IMAGE_RESULT -eq 0 ]]; then
    # Target image (tag) already exists
    if [[ "${OVERRIDE_IMAGE_ON_PROMOTION}" == "false" ]]; then
        echo "Target image already exists but override is disabled"
        exit 1
    fi
    echo "Target image already exists but is going to be overridden"
else 
    echo "Target image does not exist"
fi

echo "Copying source image to target registry"
echo "Source image ${SOURCE_IMAGE}"
echo "Target image ${TARGET_IMAGE}"
${SKOPEO_COMMAND} copy --src-creds ${SOURCE_IMAGE_REGISTRY_USERNAME}:${SOURCE_IMAGE_REGISTRY_PASSWORD} --src-tls-verify=false --dest-creds ${TARGET_IMAGE_REGISTRY_USERNAME}:${TARGET_IMAGE_REGISTRY_PASSWORD} --dest-tls-verify=false docker://${SOURCE_IMAGE} docker://${TARGET_IMAGE}

echo ""
echo "Promotion of image ${APP_NAMESPACE}/${APP_NAME}:${BUILD_TAG} successfully completed"

