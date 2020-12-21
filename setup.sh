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
SECRET_ENV_FILE="openshift/config-data-secret.env"
KEYSTORES_RELATIVE_SOURCE_DIR="openshift/keystores/"

OCP_VERSION=$(oc version | { grep "Server Version" || true; })
DC_FLAG=""
if [[ "$OCP_VERSION" != "" ]]; then
    # OCP 4.x ?
    OCP_VERSION=$(echo $OCP_VERSION | cut -d ':' -f 2 | sed 's/^ *//g' | cut -d '.' -f 1,2)
    if [ "$OCP_VERSION" = "4.5" ] || [ "$OCP_VERSION" = "4.6" ]; then
        # OCP 4.5, 4.6 ...
        DC_FLAG="--as-deployment-config"
    fi
fi

echo "----------------------------------------------------------------------"
echo "PARAMETERS"
echo "----------------------------------------------------------------------"
echo "Project namespace: ${PROJECT}"
echo "Application name: ${APP}"
echo "Base imagestream: ${BASE_IS}"
echo "Config map ${CONFIG_MAP_NAME} mapping content of relative path ${CONFIG_MAP_RELATIVE_SOURCE_DIR} to ${CONFIG_MAP_MOUNT_DIR}"
echo "Secret ${SECRET_NAME} mapping content of file ${SECRET_ENV_FILE}"
echo ""
echo "Creating project namespace"
oc new-project ${PROJECT}

echo "Preparing b2i directory"
rm -rf ${B2I_BUILD_DIR}
mkdir -p ${B2I_BUILD_DIR}
cp -r ${B2I_CONFIG_RELATIVE_SOURCE_DIR}/* ${B2I_BUILD_DIR}

echo "Creating new app based on image for JBoss EAP 7.2 (${BASE_IS})"
# OCP 3
oc new-build --image-stream=${BASE_IS} --name=${APP} --binary=true -n ${PROJECT}
oc start-build ${APP} --from-dir=${B2I_BUILD_DIR} -n ${PROJECT} --follow
oc new-app ${APP} -n ${PROJECT}

# OCP 4
# oc new-app --image-stream ${BASE_IS} --binary --name=${APP} -n ${PROJECT} ${DC_FLAG}

oc set env bc/${APP} --overwrite --env=CUSTOM_INSTALL_DIRECTORIES=extensions -n ${PROJECT}

echo "Patching the deployment config to remove automatic trigger for config/image change"
oc patch dc ${APP} -p '{"spec":{"triggers":[]}}' -o name -n ${PROJECT}

echo "Binding role view to default service account and setting it as service account on the dc"
oc policy add-role-to-user view system:serviceaccount:${PROJECT}:default -n ${PROJECT}
oc patch dc/${APP} --type=json -p '[{"op": "add", "path": "/spec/template/spec/serviceAccountName", "value": "default"}]' -n ${PROJECT}

echo "Creating the routes to expose the app"
# oc expose svc/${APP} -n ${PROJECT}
oc create route passthrough ${APP} --service ${APP} --port=8443 --insecure-policy=Redirect -n ${PROJECT}

echo "Creating and binding config map ${CONFIG_MAP_NAME}"
oc create configmap ${CONFIG_MAP_NAME} --from-file=${CONFIG_MAP_RELATIVE_SOURCE_DIR} -n ${PROJECT}
oc set volumes dc/${APP} --add --name=${CONFIG_MAP_NAME} --configmap-name=${CONFIG_MAP_NAME} -m ${CONFIG_MAP_MOUNT_DIR} --overwrite -t configmap -n ${PROJECT}

echo "Creating and binding secret ${SECRET_NAME} from environment variables defined in file ${SECRET_ENV_FILE}"
# DEPRECATED oc create -f ${SECRET_ENV_FILE} -n ${PROJECT}
oc create secret generic ${SECRET_NAME} --from-env-file=${SECRET_ENV_FILE} -n ${PROJECT}
oc set env --from=secret/${SECRET_NAME} dc/${APP} -n ${PROJECT}

echo "Creating liveness and readiness probes for health check"
oc set probe dc/${APP} --liveness --initial-delay-seconds=60 --period-seconds=16 --success-threshold=1 --failure-threshold=3 --timeout-seconds=1 -n ${PROJECT} -- /bin/bash '-c' /opt/eap/bin/livenessProbe.sh
oc set probe dc/${APP} --readiness --initial-delay-seconds=10 --period-seconds=16 --success-threshold=1 --failure-threshold=3 --timeout-seconds=1 -n ${PROJECT} -- /bin/bash '-c' /opt/eap/bin/readinessProbe.sh

echo "Creating and linking secrets for SSL/JGroups keystores and truststore to the default service account"
oc create secret generic eap-ssl-secret --from-file=${KEYSTORES_RELATIVE_SOURCE_DIR}/eapkeystore.jks -n ${PROJECT}
oc create secret generic eap-jgroup-secret --from-file=${KEYSTORES_RELATIVE_SOURCE_DIR}/eapjgroups.jceks -n ${PROJECT}
# oc create secret generic eap-truststore-secret --from-file=${KEYSTORES_RELATIVE_SOURCE_DIR}/truststore.jks -n ${PROJECT}
oc secrets link default eap-ssl-secret eap-jgroup-secret --for=mount -n ${PROJECT}
# oc secrets link default eap-ssl-secret eap-jgroup-secret eap-truststore-secret --for=mount -n ${PROJECT}

echo "Creating and binding volumes for SSL/JGroups keystores"
oc set volume dc/${APP} --add --name="eap-keystore-volume" --type=secret --secret-name="eap-ssl-secret" --mount-path="/etc/eap-secret-volume" -n ${PROJECT}
oc set volume dc/${APP} --add --name="eap-jgroups-keystore-volume" --type=secret --secret-name="eap-jgroup-secret" --mount-path="/etc/jgroups-encrypt-secret-volume" -n ${PROJECT}
# oc set volume dc/${APP} --add --name="eap-truststore-volume" --type=secret --secret-name="eap-truststore-secret" --mount-path="/etc/eap-truststore-secret-volume" -n ${PROJECT}

echo "Setup for ${PROJECT}/${APP} deployment successfully completed"

# import imagestream
# oc replace -n openshift --force -f https://raw.githubusercontent.com/jboss-container-images/jboss-eap-7-openshift-image/7.2.x/templates/eap72-image-stream.json
