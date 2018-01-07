#!/usr/bin/env bash

# this script can run using source - to enable keeping the environment variables and shell completion
#
# please pay attention not to call exit in this script - as it might exit from the user's shell
#
# thanks for your understanding and cooperation

[ -f .env ] && eval `dotenv -f ".env" list`
export K8S_NAMESPACE
export K8S_HELM_RELEASE_NAME
export K8S_ENVIRONMENT_NAME
export KUBECONFIG=environments/${K8S_ENVIRONMENT_NAME}/secret-admin.conf
[ "${K8S_CONNECT_ORIGINAL_PS1}" == "" ] && export K8S_CONNECT_ORIGINAL_PS1="${PS1}"
export PS1="${K8S_CONNECT_ORIGINAL_PS1}\[\033[01;33m\]kamatera-${K8S_NAMESPACE}\[\033[0m\]$ "
source <(kubectl completion bash)
echo "Connected to kamatera-${K8S_NAMESPACE}"
