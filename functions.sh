#!/usr/bin/env bash
# Copyright 2014-2017 , Rackspace US, Inc.
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

## Vars ----------------------------------------------------------------------

# Set rpc-repo defaults, for testing by hand
export REPO_HOST=${REPO_HOST:-localhost}
export REPO_USER=${REPO_USER:-root}
export REPO_KEYFILE=${REPO_KEYFILE:-~/.ssh/id_rsa}

export BASE_DIR=${BASE_DIR:-"/opt/rpc-openstack"}
export OA_DIR="/opt/openstack-ansible"
export OA_OVERRIDES='/etc/openstack_deploy/user_osa_variables_overrides.yml'

export HOST_SOURCES_REWRITE=${HOST_SOURCES_REWRITE:-"yes"}
export HOST_UBUNTU_REPO=${HOST_UBUNTU_REPO:-"http://mirror.rackspace.com/ubuntu"}
export HOST_RCBOPS_REPO=${HOST_RCBOPS_REPO:-"http://rpc-repo.rackspace.com"}
export RPC_RELEASE="$(${BASE_DIR}/scripts/get-rpc_release.py)"

export ENABLE_ARTIFACTS_APT=${ENABLE_ARTIFACTS_APT:-"no"}
export ENABLE_ARTIFACTS_PYT=${ENABLE_ARTIFACTS_PYT:-"no"}

# Read the OS information
source /etc/os-release
source /etc/lsb-release

## Functions -----------------------------------------------------------------

function apt_artifacts_available {

  CHECK_URL="${HOST_RCBOPS_REPO}/apt-mirror/integrated/dists/${RPC_RELEASE}-${DISTRIB_CODENAME}"

  if curl --output /dev/null --silent --head --fail ${CHECK_URL}; then
    return 0
  else
    return 1
  fi

}

function git_artifacts_available {

  CHECK_URL="${HOST_RCBOPS_REPO}/git-archives/${RPC_RELEASE}/requirements.checksum"

  if curl --output /dev/null --silent --head --fail ${CHECK_URL}; then
    return 0
  else
    return 1
  fi

}

function python_artifacts_available {

  ARCH=$(uname -p)
  CHECK_URL="${HOST_RCBOPS_REPO}/os-releases/${RPC_RELEASE}/${ID}-${VERSION_ID}-${ARCH}/MANIFEST.in"

  if curl --output /dev/null --silent --head --fail ${CHECK_URL}; then
    return 0
  else
    return 1
  fi

}

function container_artifacts_available {

  CHECK_URL="${HOST_RCBOPS_REPO}/meta/1.0/index-system"

  if curl --silent --fail ${CHECK_URL} | grep -q "^${ID};${DISTRIB_CODENAME};.*${RPC_RELEASE};"; then
    return 0
  else
    return 1
  fi

}

function safe_to_replace_artifacts {

  # This function is used by the artifact pipeline to determine whether it
  # is safe to rebuild artifacts for the current head of the mainline branch.
  # It is only ever safe when the mainline and rc branches are different
  # versions or if there is no rc branch. When this is the case, the function
  # will return 0.

  # We can only use this method once this file exists in the RC branch, so
  # we have to implement the new method and a fall back to the old method.

  rc_branch="master-rc"
  new_file_to_fetch="origin/${rc_branch}:playbooks/vars/rpc-release.yml"
  old_file_to_fetch="origin/${rc_branch}:etc/openstack_deploy/group_vars/all/release.yml"
  release_data_file="${WORKSPACE}/rc-release-data.yml"

  # new method
  if git cat-file -e ${new_file_to_fetch} 2>/dev/null; then
    git show ${new_file_to_fetch} > ${release_data_file}
    export RC_BRANCH_VERSION=$(${GATING_PATH}/get-rpc_release.py ${release_data_file})

  # old method
  elif git cat-file -e ${old_file_to_fetch} 2>/dev/null; then
    git show ${old_file_to_fetch} > ${release_data_file}
    export RC_BRANCH_VERSION=$(awk '/^rpc_release/{print $2}' ${release_data_file} | tr -d '"')

  else
    export RC_BRANCH_VERSION="none"
  fi

  if [[ "${RC_BRANCH_VERSION}" == "${RPC_RELEASE}" ]]; then
    return 1
  else
    return 0
  fi
}

function set_galera_client_version {

  # From Ocata onwards the galera_client/galera_server version
  # is not set in the usual way - it uses a var in the distro
  # package list. As such the py_pkgs lookup cannot resolve it.
  # To work around this we work around it by setting the value
  # in the overrides.

  # Get the galera client version number
  GALERA_CLIENT_VERSION=$(awk '/galera_client_major_version/ {print $2}' /etc/ansible/roles/galera_client/defaults/main.yml)

  # Set the galera client version number
  if ! grep -q '^galera_client_major_version' ${OA_OVERRIDES}; then
    echo "galera_client_major_version: ${GALERA_CLIENT_VERSION}" | tee -a ${OA_OVERRIDES}
  else
    sed -i "s|^galera_client_major_version.*|galera_client_major_version: ${GALERA_CLIENT_VERSION}|" ${OA_OVERRIDES}
  fi

}
