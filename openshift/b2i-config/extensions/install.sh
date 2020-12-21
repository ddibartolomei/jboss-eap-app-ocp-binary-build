#!/bin/bash

injected_dir=$1
source /usr/local/s2i/install-common.sh
# install_deployments ${injected_dir}/injected-deployments.war
echo "Installing custom modules into /opt/eap/modules..."
install_modules ${injected_dir}/modules
echo "Configuring custom drivers defined in drivers.env..."
configure_drivers ${injected_dir}/drivers.env

echo "Installing post configuration CLI operations into /opt/eap/extensions..."
mkdir $JBOSS_HOME/extensions/
cp ${injected_dir}/actions.cli $JBOSS_HOME/extensions/
cp ${injected_dir}/postconfigure.sh $JBOSS_HOME/extensions/