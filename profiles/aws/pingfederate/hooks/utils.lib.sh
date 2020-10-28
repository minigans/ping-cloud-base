#!/usr/bin/env sh

# Check and source environment variable(s) generated by discovery service
test -f "${STAGING_DIR}/ds_env_vars" && . "${STAGING_DIR}/ds_env_vars"

########################################################################################################################
# Makes a curl request to the PingFederate Admin API. The HTTP status code from the curl invocation will be
# stored in the http_code variable.
#
# Arguments
#   $@ -> The URL and additional data needed to make the request.
########################################################################################################################
function make_api_request() {
  set +x
  http_code=$(curl -k -o ${OUT_DIR}/api_response.txt -w "%{http_code}" \
        --retry ${API_RETRY_LIMIT} \
        --max-time ${API_TIMEOUT_WAIT} \
        --retry-delay 1 \
        --retry-connrefused \
        -u ${PF_ADMIN_USER_USERNAME}:${PF_ADMIN_USER_PASSWORD} \
        -H 'X-Xsrf-Header: PingFederate' "$@")
  curl_result=$?
  "${VERBOSE}" && set -x

  if test "${curl_result}" -ne 0; then
    beluga_log "Admin API connection refused"
    return ${curl_result}
  fi

  if test "${http_code}" -ne 200; then
    beluga_log "API call returned HTTP status code: ${http_code}"
    return 1
  fi

  cat ${OUT_DIR}/api_response.txt && rm -f ${OUT_DIR}/api_response.txt

  return 0
}

########################################################################################################################
# Used for API calls that specify an output file.
# When using this function the existence of the output file
# should be used to verify this function succeeded.
#
# Arguments
#   $@ -> The URL and additional data needed to make the request.
########################################################################################################################
function make_api_request_download() {
  set +x
  http_code=$(curl -k \
    --retry "${API_RETRY_LIMIT}" \
    --max-time "${API_TIMEOUT_WAIT}" \
    --retry-delay 1 \
    --retry-connrefused \
    -u ${PF_ADMIN_USER_USERNAME}:${PF_ADMIN_USER_PASSWORD} \
    -w '%{http_code}' \
    -H 'X-Xsrf-Header: PingFederate' "$@")
  curl_result=$?
  "${VERBOSE}" && set -x

  if test "${curl_result}" -ne 0; then
    beluga_log "Admin API connection refused"
    return ${curl_result}
  fi

  if test "${http_code}" -ne 200; then
    beluga_log "API call returned HTTP status code: ${http_code}"
    return 1
  fi

  beluga_log "Admin API request status: ${curl_result}; HTTP status: ${http_code}"
  return ${curl_result}
}

########################################################################################################################
# Wait for the local PingFederate admin API to be up and running waiting 3 seconds between each check.
#
# Arguments
#   ${1} -> The optional endpoint to wait for. If not specified, the function will wait for the version endpoint.
########################################################################################################################
function wait_for_admin_api_endpoint() {
  TIMEOUT=3
  ENDPOINT="${1:-version}"
  API_REQUEST_URL="https://${PF_ADMIN_HOST_PORT}/pf-admin-api/v1/${ENDPOINT}"

  beluga_log "Waiting for admin API endpoint at ${API_REQUEST_URL}"

  while true; do
    http_code=$(curl -k \
      --retry "${API_RETRY_LIMIT}" \
      --max-time "${API_TIMEOUT_WAIT}" \
      --retry-delay 1 \
      --retry-connrefused \
      -u ${PF_ADMIN_USER_USERNAME}:${PF_ADMIN_USER_PASSWORD} \
      -w '%{http_code}' \
      -H 'X-Xsrf-Header: PingFederate' \
      -X GET "${API_REQUEST_URL}" \
      -o /dev/null 2> /dev/null
    )
    if test "${http_code}" -eq 200; then
      beluga_log "Admin API endpoint ${ENDPOINT} ready"
      return 0
    fi

    beluga_log "Admin API not endpoint ${ENDPOINT} ready - will retry in ${TIMEOUT} seconds"
    sleep "${TIMEOUT}"
  done
}

#---------------------------------------------------------------------------------------------
# Function to obfuscate LDAP password
#---------------------------------------------------------------------------------------------

function obfuscatePassword() {
  currentDir="$(pwd)"
  cd "${SERVER_ROOT_DIR}/bin"

   #
   # Ensure Java home is set
   #
   if [ -z "${JAVA_HOME}" ]; then
      export JAVA_HOME=/usr/lib/jvm/default-jvm/jre/
   fi
   #
   # The master key may not exist, this means no key was passed in as a secret and this is the first run of PF
   # for this environment, we can use the obfuscate utility to generate a master key as a byproduct of obfuscating
   # the password used to authenticate to PingDirectory in the ldap properties file.
   #
   # Obfuscate the ldap password
   #
   export PF_LDAP_PASSWORD_OBFUSCATED=$(sh ./obfuscate.sh "${PF_LDAP_PASSWORD}" | tr -d '\n')
   #
   # Inject obfuscated password into ldap properties file.
   vars='${PF_PD_BIND_PROTOCOL}
${PF_PD_BIND_USESSL}
${PD_CLUSTER_DOMAIN_NAME}
${PD_CLUSTER_PRIVATE_HOSTNAME}
${PF_PD_BIND_PORT}
${PF_LDAP_PASSWORD_OBFUSCATED}'

   envsubst "${vars}" \
      < "${STAGING_DIR}/templates/ldap.properties" \
      > ldap.properties

   PF_LDAP_PASSWORD_OBFUSCATED="${PF_LDAP_PASSWORD_OBFUSCATED:8}"

   envsubst "${vars}" \
      < "${STAGING_DIR}/templates/pingfederate-ldap-ds.xml" \
      > ../server/default/data/pingfederate-ldap-ds.xml

   cd "${currentDir}"
}

########################################################################################################################
# Export values for PingFederate configuration settings based on single vs. multi cluster.
########################################################################################################################
function export_config_settings() {
  K8S_SUB_DOMAIN_NAME="${PF_DNS_PING_NAMESPACE}.svc.cluster.local"

  if is_multi_cluster; then
    MULTI_CLUSTER=true
    if is_primary_cluster; then
      PRIMARY_CLUSTER=true
      export PF_ADMIN_HOST="${PINGFEDERATE_ADMIN_SERVER}-0.${K8S_SERVICE_NAME_PINGFEDERATE_ADMIN}.${K8S_SUB_DOMAIN_NAME}"
      export PF_CLUSTER_DOMAIN_NAME="${PF_CLUSTER_PRIVATE_HOSTNAME}.${K8S_SUB_DOMAIN_NAME}"
      export PD_CLUSTER_DOMAIN_NAME="${PD_CLUSTER_PRIVATE_HOSTNAME}.${K8S_SUB_DOMAIN_NAME}"
    else
      PRIMARY_CLUSTER=false
      export PF_ADMIN_HOST="${PINGFEDERATE_ADMIN_SERVER}-0.${PF_CLUSTER_PUBLIC_HOSTNAME}"
      export PF_CLUSTER_DOMAIN_NAME="${PF_CLUSTER_PUBLIC_HOSTNAME}"
      export PD_CLUSTER_DOMAIN_NAME="${PD_CLUSTER_PUBLIC_HOSTNAME}"
    fi
  else
    MULTI_CLUSTER=false
    PRIMARY_CLUSTER=true
    export PF_ADMIN_HOST="${PINGFEDERATE_ADMIN_SERVER}-0.${K8S_SERVICE_NAME_PINGFEDERATE_ADMIN}.${K8S_SUB_DOMAIN_NAME}"
    export PF_CLUSTER_DOMAIN_NAME="${PF_CLUSTER_PRIVATE_HOSTNAME}.${K8S_SUB_DOMAIN_NAME}"
    export PD_CLUSTER_DOMAIN_NAME="${PD_CLUSTER_PRIVATE_HOSTNAME}.${K8S_SUB_DOMAIN_NAME}"
  fi

  # On the admin server itself, use localhost for the PF admin hostname because
  # the service may not be ready yet.
  SHORT_HOST_NAME="$(hostname)"
  echo "${SHORT_HOST_NAME}" | grep -qi "${PINGFEDERATE_ADMIN_SERVER}"
  test $? -eq 0 && export PF_ADMIN_HOST=localhost

  export PF_ADMIN_HOST_PORT="${PF_ADMIN_HOST}:${PF_ADMIN_PORT}"
  export POST_START_INIT_MARKER_FILE="${OUT_DIR}/instance/post-start-init-complete"

  beluga_log "MULTI_CLUSTER - ${MULTI_CLUSTER}"
  beluga_log "PRIMARY_CLUSTER - ${PRIMARY_CLUSTER}"
  beluga_log "PF_ADMIN_HOST_PORT - ${PF_ADMIN_HOST_PORT}"
  beluga_log "PF_CLUSTER_DOMAIN_NAME - ${PF_CLUSTER_DOMAIN_NAME}"
  beluga_log "PD_CLUSTER_DOMAIN_NAME - ${PD_CLUSTER_DOMAIN_NAME}"
}

########################################################################################################################
# Determines if the environment is running in the context of multiple clusters.
#
# Returns
#   true if multi-cluster; false if not.
########################################################################################################################
function is_multi_cluster() {
  test ! -z "${IS_MULTI_CLUSTER}" && "${IS_MULTI_CLUSTER}"
}

########################################################################################################################
# Determines if the environment is set up in the primary cluster.
#
# Returns
#   true if primary cluster; false if not.
########################################################################################################################
function is_primary_cluster() {
  test "${TENANT_DOMAIN}" = "${PRIMARY_TENANT_DOMAIN}"
}

########################################################################################################################
# Determines if the environment is set up in a secondary cluster.
#
# Returns
#   true if secondary cluster; false if not.
########################################################################################################################
function is_secondary_cluster() {
  ! is_primary_cluster
}

########################################################################################################################
# Set up the tcp.xml file based on whether it is a single-cluster or multi-cluster deployment.
########################################################################################################################
function configure_tcp_xml() {
  local currentDir="$(pwd)"
  cd "${SERVER_ROOT_DIR}/server/default/conf"

  query_list="${PF_CLUSTER_DOMAIN_NAME}"
  if is_multi_cluster; then
    for domain in $(echo "${SECONDARY_TENANT_DOMAINS}" | tr ',' ' '); do
      query_list="${query_list},${PF_CLUSTER_PRIVATE_HOSTNAME}.${domain}"
    done
  fi

  export DNS_QUERY_LIST="${query_list}"
  envsubst '${DNS_QUERY_LIST}' \
      < "${STAGING_DIR}/templates/tcp.xml" \
      > tcp.xml

  beluga_log "configure_tcp_xml: contents of tcp.xml after substitution"
  cat tcp.xml

  cd "${currentDir}"
}

########################################################################################################################
# Set up tcp.xml based on whether it is a single-cluster or multi-cluster deployment.
########################################################################################################################
function configure_cluster() {
  # Copy customer native-s3-ping, if present.
  # See PDO-1438 for details. Here's the customization to native S3 ping:
  # https://github.com/jgroups-extras/native-s3-ping/pull/83/files
  CUSTOM_NATIVE_S3_PING_JAR='/opt/staging/native-s3-ping.jar'
  if test -f "${CUSTOM_NATIVE_S3_PING_JAR}"; then
    TARGET_FILE="${SERVER_ROOT_DIR}"/server/default/lib/native-s3-ping.jar
    beluga_log "Copying '${CUSTOM_NATIVE_S3_PING_JAR}' to '${TARGET_FILE}'"

    mv "${TARGET_FILE}" "${TARGET_FILE}".bak
    cp "${CUSTOM_NATIVE_S3_PING_JAR}" "${TARGET_FILE}"
  fi

  # Configure the tcp.xml file for service discovery.
  configure_tcp_xml
}

########################################################################################################################
# Function sets required environment variables for skbn
#
########################################################################################################################
function initializeSkbnConfiguration() {
  unset SKBN_CLOUD_PREFIX
  unset SKBN_K8S_PREFIX

  # Allow overriding the backup URL with an arg
  test ! -z "${1}" && BACKUP_URL="${1}"

  # Check if endpoint is AWS cloud storage service (S3 bucket)
  case "$BACKUP_URL" in "s3://"*)

    # Set AWS specific variable for skbn
    export AWS_REGION=${REGION}

    DIRECTORY_NAME=$(echo "${PING_PRODUCT}" | tr '[:upper:]' '[:lower:]')

    if ! $(echo "$BACKUP_URL" | grep -q "/$DIRECTORY_NAME"); then
      BACKUP_URL="${BACKUP_URL}/${DIRECTORY_NAME}"
    fi

  esac

  beluga_log "Getting cluster metadata"

  # Get prefix of HOSTNAME which match the pod name.  
  export POD="$(echo "${HOSTNAME}" | cut -d. -f1)"
  
  METADATA=$(kubectl get "$(kubectl get pod -o name | grep "${POD}")" \
    -o=jsonpath='{.metadata.namespace},{.metadata.name},{.metadata.labels.role}')

  METADATA_NS=$(echo "$METADATA"| cut -d',' -f1)
  METADATA_PN=$(echo "$METADATA"| cut -d',' -f2)
  METADATA_CN=$(echo "$METADATA"| cut -d',' -f3)

  # Remove suffix for PF runtime.
  METADATA_CN="${METADATA_CN%-engine}"

  export SKBN_CLOUD_PREFIX="${BACKUP_URL}"
  export SKBN_K8S_PREFIX="k8s://${METADATA_NS}/${METADATA_PN}/${METADATA_CN}"
}

########################################################################################################################
# Function to copy file(s) between cloud storage and k8s
#
########################################################################################################################
function skbnCopy() {
  PARALLEL="0"
  SOURCE="${1}"
  DESTINATION="${2}"

  # Check if the number of files to be copied in parallel is defined (0 for full parallelism)
  test ! -z "${3}" && PARALLEL="${3}"

  if ! skbn cp --src "$SOURCE" --dst "${DESTINATION}" --parallel "${PARALLEL}"; then
    return 1
  fi
}

########################################################################################################################
# Logs the provided message at the provided log level. Default log level is INFO, if not provided.
#
# Arguments
#   $1 -> The log message.
#   $2 -> Optional log level. Default is INFO.
########################################################################################################################
function beluga_log() {
  file_name="$(basename "$0")"
  message="$1"
  test -z "$2" && log_level='INFO' || log_level="$2"
  format='+%Y-%m-%d %H:%M:%S'
  timestamp="$(TZ=UTC date "${format}")"
  echo "${file_name}: ${timestamp} ${log_level} ${message}"
}

########################################################################################################################
# Logs the provided message and set the log level to ERROR.
#
# Arguments
#   $1 -> The log message.
########################################################################################################################
function beluga_error() {
  beluga_log "$1" 'ERROR'
}

########################################################################################################################
# Logs the provided message and set the log level to WARN.
#
# Arguments
#   $1 -> The log message.
########################################################################################################################
function beluga_warn() {
  beluga_log "$1" 'WARN'
}

# These are needed by every script - so export them when this script is sourced.
beluga_log "export config settings"
export_config_settings