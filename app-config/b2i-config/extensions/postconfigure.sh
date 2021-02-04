#!/bin/bash

# This script is run automatically via the 'postconfigure_extensions' function defined in /opt/eap/bin/launch/configure_extensions.sh
# This must be run after environment variables are used to inject content into the standalone-openshift.xml

# Remove the comment on the next line to enable actions.cli execution
# $JBOSS_HOME/bin/jboss-cli.sh --file=/opt/eap/extensions/actions.cli
