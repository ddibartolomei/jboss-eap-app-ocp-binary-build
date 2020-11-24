#!/bin/bash
set -Eeuo pipefail

trap "echo Deploy failed!" ERR

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

APP="eap-test-app"
APP_ARTIFACT_FILE="eap-test-app.war"
B2I_CONFIG_RELATIVE_SOURCE_DIR="openshift/b2i-config"
B2I_BUILD_DIR="b2i"
CONFIG_MAP_NAME="${APP}-config"
CONFIG_MAP_RELATIVE_SOURCE_DIR="openshift/config/"
CONFIG_MAP_MOUNT_DIR="/opt/config"
SECRET_NAME="${APP}-config-data"
SECRET_FILE="openshift/config-data-secret.yaml"

echo "----------------------------------------------------------------------"
echo "PARAMETERS"
echo "----------------------------------------------------------------------"
echo "Project namespace: ${PROJECT}"
echo "Application name: ${APP}"
echo "Config map ${CONFIG_MAP_NAME} mapping content of relative path ${CONFIG_MAP_RELATIVE_SOURCE_DIR} to ${CONFIG_MAP_MOUNT_DIR}"
echo "Secret ${SECRET_NAME} mapping content of file ${SECRET_FILE}"
echo ""

echo "Reading project version from pom.xml"
BUILD_TAG=$(mvn -q -Dexec.executable=echo -Dexec.args='${project.version}' --non-recursive exec:exec)
echo "Build tag set to: ${BUILD_TAG}"
TARGET_IMAGE=docker-registry.default.svc:5000/${PROJECT}/${APP}:${BUILD_TAG}

echo "Building app artifact"
mvn clean package -Dmaven.javadoc.skip=true -DskipTests

echo "Preparing b2i directory"
rm -rf ${B2I_BUILD_DIR}
mkdir -p ${B2I_BUILD_DIR}
cp -r ${B2I_CONFIG_RELATIVE_SOURCE_DIR}/* ${B2I_BUILD_DIR}
cp target/${APP_ARTIFACT_FILE} ${B2I_BUILD_DIR}

echo "Patching bc output image tag to ${BUILD_TAG}"
oc patch bc ${APP} -o name -p "{\"spec\":{\"output\":{\"to\":{\"kind\":\"ImageStreamTag\",\"name\":\"${APP}:${BUILD_TAG}\"}}}}" -n ${PROJECT}

echo "Building target app image ${TARGET_IMAGE}"
oc start-build ${APP} --from-dir=${B2I_BUILD_DIR} -n ${PROJECT} --follow

echo "Setting target built image in the dc"
oc set image dc/${APP} ${APP}=${TARGET_IMAGE} -n ${PROJECT}
TARGET_IMAGE_IN_DC=$(oc get dc ${APP} -o jsonpath='{.spec.template.spec.containers[0].image}' -n ${PROJECT})
if [ "$TARGET_IMAGE_IN_DC" != "$TARGET_IMAGE" ]; then
  echo "Deployment Config image tag version is $TARGET_IMAGE_IN_DC but expected was ${TARGET_IMAGE}"
  exit 1
fi

echo "Updating config map ${CONFIG_MAP_NAME}"
oc create configmap ${CONFIG_MAP_NAME} --from-file=${CONFIG_MAP_RELATIVE_SOURCE_DIR} --dry-run -o yaml -n ${PROJECT} | oc replace -n ${PROJECT} -f -

echo "Updating and binding secret defined in file ${SECRET_FILE}"
oc apply -f ${SECRET_FILE} -n ${PROJECT}
oc set env --from=secret/${SECRET_NAME} dc/${APP} -n ${PROJECT}

echo "Rolling out the dc"
oc rollout latest ${APP} -n ${PROJECT}