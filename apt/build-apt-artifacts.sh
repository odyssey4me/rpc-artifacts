#!/usr/bin/env bash
# Copyright 2014-2017, Rackspace US, Inc.
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

## Shell Opts ----------------------------------------------------------------

set -e
set -o pipefail

## Vars ----------------------------------------------------------------------

# To provide flexibility in the jobs, we have the ability to set any
# parameters that will be supplied on the ansible-playbook CLI.
export ANSIBLE_PARAMETERS=${ANSIBLE_PARAMETERS:--v}

# Set this to NO if you do not want to pull any existing data from rpc-repo.
export PULL_FROM_MIRROR=${PULL_FROM_MIRROR:-yes}

# Set this to YES if you want to replace any existing artifacts for the current
# release with those built in this job.
export RECREATE_SNAPSHOTS=${REPLACE_ARTIFACTS:-no}

# Set this to YES if you want to push any changes made in this job to rpc-repo.
export PUSH_TO_MIRROR=${PUSH_TO_MIRROR:-no}

# The BASE_DIR needs to be set to ensure that the scripts
# know it and use this checkout appropriately.
export BASE_DIR=${PWD}

# We want the role downloads to be done via git
# This ensures that there is no race condition with the artifacts-git job
export ANSIBLE_ROLE_FETCH_MODE="git-clone"

# These are allowed to be flexible for the purpose of testing by hand.
export PUBLISH_SNAPSHOT=${PUBLISH_SNAPSHOT:-yes}
export RPC_ARTIFACTS_FOLDER=${RPC_ARTIFACTS_FOLDER:-/var/www/artifacts}
export RPC_ARTIFACTS_PUBLIC_FOLDER=${RPC_ARTIFACTS_PUBLIC_FOLDER:-/var/www/repo}

export SCRIPT_PATH="$(readlink -f $(dirname ${0}))"

## Main ----------------------------------------------------------------------

if [ -z ${REPO_USER_KEY+x} ] || [ -z ${REPO_USER+x} ] || [ -z ${REPO_HOST+x} ] || [ -z ${REPO_HOST_PUBKEY+x} ]; then
  echo "ERROR: The required REPO_ environment variables are not set."
  exit 1
elif [ -z ${GPG_PRIVATE+x} ] || [ -z ${GPG_PUBLIC+x} ]; then
  echo "ERROR: The required GPG_ environment variables are not set."
  exit 1
fi

# Remove any previous installed plugins, libraries,
# facts and ansible/openstack-ansible refs. This
# ensures that as we upgrade/downgrade on the long
# running jenkins slave we do not get interference
# from previously installed/configured items.
rm -rf /etc/ansible /etc/openstack_deploy /usr/local/bin/ansible* /usr/local/bin/openstack-ansible*

# Run basic setup
source ${SCRIPT_PATH}/../setup/artifact-setup.sh

# Bootstrap Ansible using OSA
pushd /opt/openstack-ansible
  bash -c "/opt/openstack-ansible/scripts/bootstrap-ansible.sh"
popd

cp ${SCRIPT_PATH}/lookup/* /etc/ansible/roles/plugins/lookup/

# Figure out when it is safe to automatically replace artifacts
if [[ "$(echo ${PUSH_TO_MIRROR} | tr [a-z] [A-Z])" == "YES" ]]; then

  if apt_artifacts_available; then
    # If there are artifacts for this release already, and it is not
    # safe to replace them, then set PUSH_TO_MIRROR to NO to prevent
    # them from being overwritten.
    if ! safe_to_replace_artifacts; then
      export PUSH_TO_MIRROR="NO"

    # If there are artifacts for this release already, and it is safe
    # to replace them, then set REPLACE_ARTIFACTS to YES to ensure
    # that they do get replaced.
    else
      export REPLACE_ARTIFACTS="YES"
    fi
  fi
fi

# If REPLACE_ARTIFACTS is YES then force PUSH_TO_MIRROR to YES
if [[ "$(echo ${REPLACE_ARTIFACTS} | tr [a-z] [A-Z])" == "YES" ]]; then
  export RECREATE_SNAPSHOTS="YES"
  export PUSH_TO_MIRROR="YES"
fi

# Ensure the required folders are present
mkdir -p ${RPC_ARTIFACTS_FOLDER}
mkdir -p ${RPC_ARTIFACTS_PUBLIC_FOLDER}

set +x
# Setup the repo key for package download/upload
REPO_KEYFILE=~/.ssh/repo.key
cat $REPO_USER_KEY > ${REPO_KEYFILE}
chmod 600 ${REPO_KEYFILE}

# Setup the GPG key for package signing
cat $GPG_PRIVATE > ${RPC_ARTIFACTS_FOLDER}/aptly.private.key
cat $GPG_PUBLIC > ${RPC_ARTIFACTS_FOLDER}/aptly.public.key
set -x

# Ensure that the repo server public key is a known host
grep "${REPO_HOST}" ~/.ssh/known_hosts || echo "${REPO_HOST} $(cat $REPO_HOST_PUBKEY)" >> ~/.ssh/known_hosts

# Basic host/mirror inventory
envsubst < ${SCRIPT_PATH}/../inventory > /opt/inventory

# Remove the previously used rpc-repo.log file to prevent
# it growing too large. We want a fresh log for every job.
[ -e /var/log/rpc-repo.log ] && rm -f /var/log/rpc-repo.log

# Execute the playbooks
cd ${SCRIPT_PATH}
ansible-playbook -i /opt/inventory ${ANSIBLE_PARAMETERS} aptly-pre-install.yml
ansible-playbook -i /opt/inventory ${ANSIBLE_PARAMETERS} aptly-all.yml

source /opt/openstack-ansible/scripts/openstack-ansible.rc
ansible-playbook -i /opt/inventory ${ANSIBLE_PARAMETERS} apt-artifacts-testing.yml
