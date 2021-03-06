#!/bin/bash

# Copyright 2014 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# A library of helper functions and constant for the local config.

# Use the config file specified in $KUBE_CONFIG_FILE, or default to
# config-default.sh.
source $(dirname ${BASH_SOURCE})/${KUBE_CONFIG_FILE-"config-default.sh"}

# Find the release to use.  If passed in, go with that and validate.  If not use
# the release/config.sh version assuming a dev workflow.
function find-release() {
  if [ -n "$1" ]; then
    RELEASE_NORMALIZED=$1
  else
    local RELEASE_CONFIG_SCRIPT=$(dirname $0)/../release/config.sh
    if [ -f $(dirname $0)/../release/config.sh ]; then
      . $RELEASE_CONFIG_SCRIPT
      normalize_release
    fi
  fi

  # Do one final check that we have a good release
  if ! gsutil -q stat $RELEASE_NORMALIZED/master-release.tgz; then
    echo "Could not find release tar.  If developing, make sure you have run src/release/release.sh to create a release." 1>&2
    exit 1
  fi
  echo "Release: ${RELEASE_NORMALIZED}"
}

# Use the gcloud defaults to find the project.  If it is already set in the
# environment then go with that.
function detect-project () {
  if [ -z "$PROJECT" ]; then
    PROJECT=$(gcloud config list project | tail -n 1 | cut -f 3 -d ' ')
  fi

  if [ -z "$PROJECT" ]; then
    echo "Could not detect Google Cloud Platform project.  Set the default project using 'gcloud config set project <PROJECT>'" 1>&2
    exit 1
  fi
  echo "Project: $PROJECT (autodetected from gcloud config)"
}

function detect-minions () {
  KUBE_MINION_IP_ADDRESSES=()
  for (( i=0; i<${#MINION_NAMES[@]}; i++)); do
    # gcutil will print the "external-ip" column header even if no instances are found
    local minion_ip=$(gcutil listinstances --format=csv --sort=external-ip \
      --columns=external-ip --zone ${ZONE} --filter="name eq ${MINION_NAMES[$i]}" \
      | tail -n '+2' | tail -n 1)
    if [ -z "$minion_ip" ] ; then
      echo "Did not find ${MINION_NAMES[$i]}" 1>&2
    else
      echo "Found ${MINION_NAMES[$i]} at ${minion_ip}"
      KUBE_MINION_IP_ADDRESSES+=("${minion_ip}")
    fi
  done
  if [ -z "$KUBE_MINION_IP_ADDRESSES" ]; then
    echo "Could not detect Kubernetes minion nodes.  Make sure you've launched a cluster with 'kube-up.sh'" 1>&2
    exit 1
  fi
}

function detect-master () {
  KUBE_MASTER=${MASTER_NAME}
  if [ -z "$KUBE_MASTER_IP" ]; then
    # gcutil will print the "external-ip" column header even if no instances are found
    KUBE_MASTER_IP=$(gcutil listinstances --format=csv --sort=external-ip \
      --columns=external-ip --zone ${ZONE} --filter="name eq ${MASTER_NAME}" \
      | tail -n '+2' | tail -n 1)
  fi
  if [ -z "$KUBE_MASTER_IP" ]; then
    echo "Could not detect Kubernetes master node.  Make sure you've launched a cluster with 'kube-up.sh'" 1>&2
    exit 1
  fi
  echo "Using master: $KUBE_MASTER (external IP: $KUBE_MASTER_IP)"
}

function get-password {
  file=${HOME}/.kubernetes_auth
  if [ -e ${file} ]; then
    user=$(cat $file | python -c 'import json,sys;print json.load(sys.stdin)["User"]')
    passwd=$(cat $file | python -c 'import json,sys;print json.load(sys.stdin)["Password"]')
    return
  fi
  user=admin
  passwd=$(python -c 'import string,random; print "".join(random.SystemRandom().choice(string.ascii_letters + string.digits) for _ in range(16))')

  # Store password for reuse.
  cat << EOF > ~/.kubernetes_auth
{
  "User": "$user",
  "Password": "$passwd"
}
EOF
  chmod 0600 ~/.kubernetes_auth
}

# Verify prereqs
function verify-prereqs {
  for x in gcloud gcutil gsutil; do
    if [ "$(which $x)" == "" ]; then
      echo "Can't find $x in PATH, please fix and retry." 1>&2
      exit 1
    fi
  done
}

# Instantiate a kubernetes cluster
function kube-up {

  # Find the release to use.  Generally it will be passed when doing a 'prod'
  # install and will default to the release/config.sh version when doing a
  # developer up.
  find-release $1

  # Detect the project into $PROJECT if it isn't set
  detect-project

  # This will take us up to the git repo root
  local base_dir=$(dirname "${BASH_SOURCE}")/../..

  # Build up start up script for master
  KUBE_TEMP=$(mktemp -d -t kubernetes.XXXXXX)
  trap 'rm -rf "${KUBE_TEMP}"' EXIT

  get-password
  python "${base_dir}/third_party/htpasswd/htpasswd.py" -b \
    -c "${KUBE_TEMP}/htpasswd" $user $passwd
  HTPASSWD=$(cat "${KUBE_TEMP}/htpasswd")

  if ! gcutil getnetwork "${NETWORK}"; then
    echo "Creating new network for: ${NETWORK}"
    # The network needs to be created synchronously or we have a race. The
    # firewalls can be added concurrent with instance creation.
    gcutil addnetwork "${NETWORK}" --range "10.240.0.0/16"
    gcutil addfirewall "${NETWORK}-default-internal" \
      --project "${PROJECT}" \
      --norespect_terminal_width \
      --sleep_between_polls "${POLL_SLEEP_INTERVAL}" \
      --network "${NETWORK}" \
      --allowed_ip_sources "10.0.0.0/8" \
      --allowed "tcp:1-65535,udp:1-65535,icmp" &
    gcutil addfirewall "${NETWORK}-default-ssh" \
      --project "${PROJECT}" \
      --norespect_terminal_width \
      --sleep_between_polls "${POLL_SLEEP_INTERVAL}" \
      --network "${NETWORK}" \
      --allowed_ip_sources "0.0.0.0/0" \
      --allowed "tcp:22" &
  fi

  echo "Starting VMs and configuring firewalls"
  gcutil addfirewall ${MASTER_NAME}-https \
    --project ${PROJECT} \
    --norespect_terminal_width \
    --sleep_between_polls "${POLL_SLEEP_INTERVAL}" \
    --network ${NETWORK} \
    --target_tags ${MASTER_TAG} \
    --allowed tcp:443 &

  (
    echo "#! /bin/bash"
    echo "MASTER_NAME='${MASTER_NAME}'"
    echo "MASTER_RELEASE_TAR=${RELEASE_NORMALIZED}/master-release.tgz"
    echo "MASTER_HTPASSWD='${HTPASSWD}'"
    grep -v "^#" "${base_dir}/cluster/templates/download-release.sh"
    grep -v "^#" "${base_dir}/cluster/templates/salt-master.sh"
  ) > "${KUBE_TEMP}/master-start.sh"

  gcutil addinstance ${MASTER_NAME}\
    --project ${PROJECT} \
    --norespect_terminal_width \
    --sleep_between_polls "${POLL_SLEEP_INTERVAL}" \
    --zone ${ZONE} \
    --machine_type ${MASTER_SIZE} \
    --image ${IMAGE} \
    --tags ${MASTER_TAG} \
    --network ${NETWORK} \
    --service_account_scopes="storage-ro,compute-rw" \
    --automatic_restart \
    --metadata_from_file "startup-script:${KUBE_TEMP}/master-start.sh" &

  for (( i=0; i<${#MINION_NAMES[@]}; i++)); do
    (
      echo "#! /bin/bash"
      echo "MASTER_NAME='${MASTER_NAME}'"
      echo "MINION_IP_RANGE=${MINION_IP_RANGES[$i]}"
      grep -v "^#" "${base_dir}/cluster/templates/salt-minion.sh"
    ) > ${KUBE_TEMP}/minion-start-${i}.sh

    gcutil addfirewall ${MINION_NAMES[$i]}-all \
      --project ${PROJECT} \
      --norespect_terminal_width \
      --sleep_between_polls "${POLL_SLEEP_INTERVAL}" \
      --network ${NETWORK} \
      --allowed_ip_sources ${MINION_IP_RANGES[$i]} \
      --allowed "tcp,udp,icmp,esp,ah,sctp" &

    gcutil addinstance ${MINION_NAMES[$i]} \
      --project ${PROJECT} \
      --norespect_terminal_width \
      --sleep_between_polls "${POLL_SLEEP_INTERVAL}" \
      --zone ${ZONE} \
      --machine_type ${MINION_SIZE} \
      --image ${IMAGE} \
      --tags ${MINION_TAG} \
      --network ${NETWORK} \
      --service_account_scopes=${MINION_SCOPES} \
      --automatic_restart \
      --can_ip_forward \
      --metadata_from_file "startup-script:${KUBE_TEMP}/minion-start-${i}.sh" &

    gcutil addroute ${MINION_NAMES[$i]} ${MINION_IP_RANGES[$i]} \
      --project ${PROJECT} \
      --norespect_terminal_width \
      --sleep_between_polls "${POLL_SLEEP_INTERVAL}" \
      --network ${NETWORK} \
      --next_hop_instance ${ZONE}/instances/${MINION_NAMES[$i]} &
  done

  FAIL=0
  for job in `jobs -p`
  do
      wait $job || let "FAIL+=1"
  done
  if (( $FAIL != 0 )); then
    echo "${FAIL} commands failed.  Exiting."
    exit 2
  fi


  detect-master > /dev/null

  echo "Waiting for cluster initialization."
  echo
  echo "  This will continually check to see if the API for kubernetes is reachable."
  echo "  This might loop forever if there was some uncaught error during start"
  echo "  up."
  echo

  until $(curl --insecure --user ${user}:${passwd} --max-time 5 \
          --fail --output /dev/null --silent https://${KUBE_MASTER_IP}/api/v1beta1/pods); do
      printf "."
      sleep 2
  done

  echo "Kubernetes cluster created."
  echo "Sanity checking cluster..."

  sleep 5

  # Don't bail on errors, we want to be able to print some info.
  set +e

  # Basic sanity checking
  for (( i=0; i<${#MINION_NAMES[@]}; i++)); do
      # Make sure docker is installed
      gcutil ssh ${MINION_NAMES[$i]} which docker > /dev/null
      if [ "$?" != "0" ]; then
          echo "Docker failed to install on ${MINION_NAMES[$i]}. Your cluster is unlikely to work correctly." 1>&2
          echo "Please run ./cluster/kube-down.sh and re-create the cluster. (sorry!)" 1>&2
          exit 1
      fi
  done

  echo
  echo "Kubernetes cluster is running.  The master is running at:"
  echo
  echo "  https://${KUBE_MASTER_IP}"
  echo
  echo "The user name and password to use is located in ~/.kubernetes_auth."
  echo

  kube_cert=".kubecfg.crt"
  kube_key=".kubecfg.key"
  ca_cert=".kubernetes.ca.crt"

  (umask 077
   gcutil ssh "${MASTER_NAME}" sudo cat /usr/share/nginx/kubecfg.crt > "${HOME}/${kube_cert}"
   gcutil ssh "${MASTER_NAME}" sudo cat /usr/share/nginx/kubecfg.key > "${HOME}/${kube_key}"
   gcutil ssh "${MASTER_NAME}" sudo cat /usr/share/nginx/ca.crt > "${HOME}/${ca_cert}"

   cat << EOF > ~/.kubernetes_auth
{
  "User": "$user",
  "Password": "$passwd",
  "CAFile": "$HOME/$ca_cert",
  "CertFile": "$HOME/$kube_cert",
  "KeyFile": "$HOME/$kube_key"
}
EOF

   chmod 0600 ~/.kubernetes_auth
   chmod 0600 "${HOME}/${kube_cert}"
   chmod 0600 "${HOME}/${kube_key}"
   chmod 0600 "${HOME}/${ca_cert}")
}

# Delete a kubernetes cluster
function kube-down {
  # Detect the project into $PROJECT
  detect-project

  echo "Bringing down cluster"
  gcutil deletefirewall  \
    --project ${PROJECT} \
    --norespect_terminal_width \
    --sleep_between_polls "${POLL_SLEEP_INTERVAL}" \
    --force \
    ${MASTER_NAME}-https &

  gcutil deleteinstance \
    --project ${PROJECT} \
    --norespect_terminal_width \
    --sleep_between_polls "${POLL_SLEEP_INTERVAL}" \
    --force \
    --delete_boot_pd \
    --zone ${ZONE} \
    ${MASTER_NAME} &

  gcutil deletefirewall  \
    --project ${PROJECT} \
    --norespect_terminal_width \
    --sleep_between_polls "${POLL_SLEEP_INTERVAL}" \
    --force \
    ${MINION_NAMES[*]/%/-all} &

  gcutil deleteinstance \
    --project ${PROJECT} \
    --norespect_terminal_width \
    --sleep_between_polls "${POLL_SLEEP_INTERVAL}" \
    --force \
    --delete_boot_pd \
    --zone ${ZONE} \
    ${MINION_NAMES[*]} &

  gcutil deleteroute  \
    --project ${PROJECT} \
    --norespect_terminal_width \
    --sleep_between_polls "${POLL_SLEEP_INTERVAL}" \
    --force \
    ${MINION_NAMES[*]} &

  wait

}

# Update a kubernetes cluster with latest source
function kube-push {

  # Find the release to use.  Generally it will be passed when doing a 'prod'
  # install and will default to the release/config.sh version when doing a
  # developer up.
  find-release $1

  # Detect the project into $PROJECT
  detect-master

  (
    echo MASTER_RELEASE_TAR=$RELEASE_NORMALIZED/master-release.tgz
    grep -v "^#" $(dirname $0)/templates/download-release.sh
    echo "echo Executing configuration"
    echo "sudo salt '*' mine.update"
    echo "sudo salt --force-color '*' state.highstate"
  ) | gcutil ssh --project ${PROJECT} --zone ${ZONE} $KUBE_MASTER bash

  get-password

  echo
  echo "Kubernetes cluster is running.  The master is running at:"
  echo
  echo "  https://${KUBE_MASTER_IP}"
  echo
  echo "The user name and password to use is located in ~/.kubernetes_auth."
  echo

}

# Execute prior to running tests to build a release if required for env
function test-build-release {
  # Build source
  ${KUBE_REPO_ROOT}/hack/build-go.sh
  # Make a release
  $(dirname $0)/../release/release.sh
}

# Execute prior to running tests to initialize required structure
function test-setup {

  # Detect the project into $PROJECT if it isn't set
  # gce specific
  detect-project

  if [[ ${ALREADY_UP} -ne 1 ]]; then
    # Open up port 80 & 8080 so common containers on minions can be reached
    gcutil addfirewall \
      --project ${PROJECT} \
      --norespect_terminal_width \
      --sleep_between_polls "${POLL_SLEEP_INTERVAL}" \
      --target_tags ${MINION_TAG} \
      --allowed tcp:80,tcp:8080 \
      --network ${NETWORK} \
      ${MINION_TAG}-${INSTANCE_PREFIX}-http-alt
  fi

}

# Execute after running tests to perform any required clean-up
function test-teardown {
  echo "Shutting down test cluster in background."
  gcutil deletefirewall  \
    --project ${PROJECT} \
    --norespect_terminal_width \
    --sleep_between_polls "${POLL_SLEEP_INTERVAL}" \
    --force \
    ${MINION_TAG}-${INSTANCE_PREFIX}-http-alt || true > /dev/null
  $(dirname $0)/../cluster/kube-down.sh > /dev/null
}


