#!/bin/bash
set -Eeuo pipefail

trap "echo Setup failed!" ERR

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
BASE_IS="openshift/jboss-eap72-openshift:1.0"
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
echo "Base imagestream: ${BASE_IS}"
echo "Config map ${CONFIG_MAP_NAME} mapping content of relative path ${CONFIG_MAP_RELATIVE_SOURCE_DIR} to ${CONFIG_MAP_MOUNT_DIR}"
echo "Secret ${SECRET_NAME} mapping content of file ${SECRET_FILE}"
echo ""
echo "Creating project namespace"
oc new-project ${PROJECT}

echo "Preparing b2i directory"
rm -rf ${B2I_BUILD_DIR}
mkdir -p ${B2I_BUILD_DIR}
cp -r ${B2I_CONFIG_RELATIVE_SOURCE_DIR}/* ${B2I_BUILD_DIR}

echo "Creating new app based on image for JBoss EAP 7.2 (${BASE_IS})"
oc new-build --image-stream=${BASE_IS} --name=${APP} --binary=true -n ${PROJECT}
oc start-build ${APP} --from-dir=${B2I_BUILD_DIR} -n ${PROJECT} --follow
oc new-app ${APP} -n ${PROJECT}

echo "Patching the deployment config to remove automatic trigger for config/image change"
oc patch dc ${APP} -p '{"spec":{"triggers":[]}}' -o name -n ${PROJECT}

echo "Creating the route to expose the app"
oc expose svc/${APP} -n ${PROJECT}

echo "Creating and binding config map ${CONFIG_MAP_NAME}"
oc create configmap ${CONFIG_MAP_NAME} --from-file=${CONFIG_MAP_RELATIVE_SOURCE_DIR} -n ${PROJECT}
oc set volumes dc/${APP} --add --name=${CONFIG_MAP_NAME} --configmap-name=${CONFIG_MAP_NAME} -m ${CONFIG_MAP_MOUNT_DIR} --overwrite -t configmap -n ${PROJECT}

echo "Creating and binding secret defined in file ${SECRET_FILE}"
oc create -f ${SECRET_FILE} -n ${PROJECT}
oc set env --from=secret/${SECRET_NAME} dc/${APP} -n ${PROJECT}

echo "Creating liveness and readiness probes for health check"
oc set probe dc/${APP} --liveness --initial-delay-seconds=60 --period-seconds=16 --success-threshold=1 --failure-threshold=3 --timeout-seconds=1 -n ${PROJECT} -- /bin/bash '-c' /opt/eap/bin/livenessProbe.sh
oc set probe dc/${APP} --readiness --initial-delay-seconds=10 --period-seconds=16 --success-threshold=1 --failure-threshold=3 --timeout-seconds=1 -n ${PROJECT} -- /bin/bash '-c' /opt/eap/bin/readinessProbe.sh

# oc replace -n openshift --force -f https://raw.githubusercontent.com/jboss-container-images/jboss-eap-7-openshift-image/7.2.x/templates/eap72-image-stream.json