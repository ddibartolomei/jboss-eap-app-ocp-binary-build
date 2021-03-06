#!/bin/bash
set -Eeuo pipefail

trap "echo Setup failed!" ERR

if [[ $# -eq 0 ]]; then
    SCRIPT_NAME=`basename "$0"`
    echo "Usage:"
    echo "./$SCRIPT_NAME <domain>"
    echo ""
    echo "Usage example:"
    echo "./$SCRIPT_NAME eap-test-app-test-project.apps.lab.openshift.com"
    exit 0
fi

if [[ $# -ne 1 ]]; then
    echo "Illegal number of parameters"
    exit 1
fi

DOMAIN=$1

BASE_CONFIG_DIR="app-config"
KEYSTORES_RELATIVE_TARGET_DIR="${BASE_CONFIG_DIR}/keystores"

echo "----------------------------------------------------------------------"
echo "PARAMETERS"
echo "----------------------------------------------------------------------"
echo "Domain: ${DOMAIN}"
echo "Target keystores directory: ${KEYSTORES_RELATIVE_TARGET_DIR}"
echo ""

echo "Generating keystore for HTTPS"
rm -f ${KEYSTORES_RELATIVE_TARGET_DIR}/eapkeystore.jks
keytool -genkeypair -alias ${DOMAIN} -keyalg RSA -keysize 2048 -storetype JKS -keystore ${KEYSTORES_RELATIVE_TARGET_DIR}/eapkeystore.jks -storepass password -keypass password -validity 10950

echo "Generating keystore for JGroups"
rm -f ${KEYSTORES_RELATIVE_TARGET_DIR}/eapjgroups.jceks
keytool -genseckey -alias jgroups -storetype JCEKS -keystore ${KEYSTORES_RELATIVE_TARGET_DIR}/eapjgroups.jceks -storepass password -keypass password

# To import the certificate of the SSO server into a truststore
# rm -f ${KEYSTORES_RELATIVE_TARGET_DIR}/truststore.jks
# keytool -importcert -keystore ${KEYSTORES_RELATIVE_TARGET_DIR}/truststore.jks -storepass password -alias sso-https -trustcacerts -file keystore.crt

echo "Keystores generation successfully completed"

