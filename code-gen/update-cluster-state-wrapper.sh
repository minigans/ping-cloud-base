#!/bin/bash

# This script is a wrapper for the update-cluster-state.sh script and may be used to update the cluster state repo to
# the target version. It abstracts the knowledge of the location of the update-cluster-state.sh for a target Beluga
# version and allows the operator to update the cluster state repo by simply providing the target version. For example:
#
#     NEW_VERSION=v1.7.1 ./update-cluster-state.sh
#
# It acts on the following environment variables.
#
#   NEW_VERSION -> Required. The new version of Beluga to which to update the cluster state repo.
#   ENVIRONMENTS -> An optional space-separated list of environments. Defaults to 'dev test stage prod', if unset. If
#       provided, it must contain all or a subset of the environments currently created by the generate-cluster-state.sh
#       script, i.e. dev, test, stage, prod.

### Global variables and utility functions ###
PING_CLOUD_BASE='ping-cloud-base'
UPDATE_SCRIPT_NAME='update-cluster-state.sh'

########################################################################################################################
# Invokes pushd on the provided directory but suppresses stdout and stderr.
#
# Arguments
#   ${1} -> The directory to push.
########################################################################################################################
pushd_quiet() {
  set -e; pushd "$1" >/dev/null 2>&1; set +e
}

########################################################################################################################
# Invokes popd but suppresses stdout and stderr.
########################################################################################################################
popd_quiet() {
  set -e; popd >/dev/null 2>&1; set +e
}

### SCRIPT START ###

# Ensure that this script works from any working directory
SCRIPT_HOME=$(cd "$(dirname "$0")" 2>/dev/null; pwd)
pushd_quiet "${SCRIPT_HOME}"

# Verify that required environment variable NEW_VERSION is set
if test -z "${NEW_VERSION}"; then
  echo '=====> NEW_VERSION environment variable must be set before invoking this script'
  exit 1
fi

# Clone ping-cloud-base at the new version
NEW_CLUSTER_STATE_REPO="$(mktemp -d)"
PING_CLOUD_BASE_REPO_URL="https://github.com/pingidentity/${PING_CLOUD_BASE}"

pushd_quiet "${NEW_CLUSTER_STATE_REPO}"
echo "=====> Cloning ${PING_CLOUD_BASE}@${NEW_VERSION} from ${PING_CLOUD_BASE_REPO_URL} to '${NEW_CLUSTER_STATE_REPO}'"
git clone --depth 1 --branch "${NEW_VERSION}" "${PING_CLOUD_BASE_REPO_URL}"
if test $? -ne 0; then
  echo "=====> Unable to clone ${PING_CLOUD_BASE_REPO_URL}@${NEW_VERSION} from ${PING_CLOUD_BASE_REPO_URL}"
  exit 1
fi
popd_quiet

UPDATE_SCRIPT_PATH="${NEW_CLUSTER_STATE_REPO}/${PING_CLOUD_BASE}/${UPDATE_SCRIPT_NAME}"

if test -f "${UPDATE_SCRIPT_PATH}"; then
  cp "${UPDATE_SCRIPT_PATH}" "${SCRIPT_HOME}"
  NEW_VERSION="${NEW_VERSION}" ENVIRONMENTS="${ENVIRONMENTS}" ./"${UPDATE_SCRIPT_NAME}"
else
  echo "=====> Upgrade script not supported in version ${NEW_VERSION}"
  exit 1
fi

# Go back to the previous working directory
popd_quiet