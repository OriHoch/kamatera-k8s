#!/usr/bin/env bash

kamatera_login() {
    if [ -e ./secret-kamatera.env ]; then
        eval $(cat ./secret-kamatera.env)
    fi
    export clientId=${clientId:-KAMATERA_CLIENT_ID}
    export secret=${secret:-KAMATERA_SECRET}
    [ -z "${clientId}" ] && echo "missing KAMATERA_CLIENT_ID" && return 1
    [ -z "${secret}" ] && echo "missing KAMATERA_SECRET" && return 1
    return 0
}

kamatera_curl() {
    curl -s -H "AuthClientId: ${clientId}" -H "AuthSecret: ${secret}" "$@"
}

kamatera_debug() {
    [ "${KAMATERA_DEBUG}" == "1" ] && echo "${*}"
}

kamatera_cluster_node_create() {
    CPU="${1}"
    RAM="${2}"
    DISK_SIZE_GB="${3}"
    SERVER_PATH="${4}"
    NODE_PREFIX="${5}"
    (
        password=$(python -c "import random; s='abcdefghijklmnopqrstuvwxyz01234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ'; print(''.join(random.sample(s,20)))")
        kamatera_debug "password=${password}"
        echo "${password}" > "${SERVER_PATH}/password"
        name="${NODE_PREFIX}-$(python -c 'import uuid;print(str(uuid.uuid1()).replace("-",""))')"
        kamatera_debug "name=${name}"
        echo "${name}" > "${SERVER_PATH}/name"
        params="datacenter=IL&name=${name}&password=${password}&cpu=${CPU}&ram=${RAM}&billing=hourly"
        params+="&power=1&disk_size_0=${DISK_SIZE_GB}&disk_src_0=IL%3A6000C298bbb2d3b6e9721f4f4f3c5bf0&network_name_0=wan"
        kamatera_debug "params=${params}"
        echo "${params}" > "${SERVER_PATH}/params"
        COMMAND_ID=$(kamatera_curl -X POST -d "${params}" "https://console.kamatera.com/service/server" | jq -r '.[0]')
        kamatera_debug "COMMAND_ID=${COMMAND_ID}"
        echo "${COMMAND_ID}" > "${SERVER_PATH}/command_id"
        [ -z "${COMMAND_ID}" ] && echo "failed to create server" && exit 1
        echo "waiting for kamatera server create command to complete..."
        echo "you can track progress by running './kamatera.sh command info ${COMMAND_ID}' or in kamatera console web UI task queue"
        while true; do
            sleep 60
            COMMAND_INFO_JSON=$(./kamatera.sh command info ${COMMAND_ID} 2>/dev/null)
            printf "${COMMAND_INFO_JSON}"
            echo
            STATUS=$(echo $COMMAND_INFO_JSON | jq -r .status)
            if [ "${STATUS}" == "complete" ]; then
                echo "command completed successfully"
                break
            elif [ "${STATUS}" == "error" ]; then
                echo "COMMAND_INFO_JSON=${COMMAND_INFO_JSON}"
                echo "command completed with error"
                exit 1
            elif [ "${STATUS}" == "cancelled" ]; then
                echo "COMMAND_INFO_JSON=${COMMAND_INFO_JSON}"
                echo "command was cancelled before it was executed"
                exit 1
            fi
        done
        echo "command complete"
        COMMAND_LOG=`echo $COMMAND_INFO_JSON | jq -r .log`
        echo "COMMAND_LOG=${COMMAND_LOG}"
        SERVER_IP=$(echo "${COMMAND_LOG}" | grep '^Network #1: wan' | grep -o '[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*')
        kamatera_debug "SERVER_IP=${SERVER_IP}"
        echo "${SERVER_IP}" > "${SERVER_PATH}/ip"
        echo "waiting for ssh access to the server"
        export SSHPASS="${password}"
        while true; do
            sleep 60
            echo .
            if sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$SERVER_IP true; then
                echo "ssh works!"
                break
            fi
        done
        echo "preparing the server for kube-adm installation"
        if ! sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$SERVER_IP -- "
            swapoff -a &&\
            echo "'"'"127.0.0.1 "'`'"hostname"'`'""'"'" >> /etc/hosts &&\
            while ! apt-get update; do sleep 5; done &&\
            while ! apt-get install -y docker.io apt-transport-https; do sleep 5; done &&\
            curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add - &&\
            echo 'deb http://apt.kubernetes.io/ kubernetes-xenial main' > /etc/apt/sources.list.d/kubernetes.list &&\
            sleep 5 && apt-get update && sleep 10 &&\
            apt-get install -y kubelet kubeadm kubectl &&\
            echo '"'{"exec-opts": ["native.cgroupdriver=cgroupfs"]}'"' > /etc/docker/daemon.json &&\
            sysctl net.bridge.bridge-nf-call-iptables=1 &&\
            sleep 5 &&\
            systemctl restart docker &&\
            systemctl restart kubelet
        "; then
            echo "Failed to prepare the server for kube-adm"
            exit 1
        fi
        exit 0
    )
    return $?
}

if [ "${1} ${2}" == "auth login" ]; then
    echo "Enter your kamatera API clientId and secret, they will be stored in `pwd`/secret-kamatera.env"
    [ -e ./secret-kamatera.env ] && echo "WARNING! will overwrite existing secret-kamatera.env file, Press Ctrl+C to abort."
    read -p "clientID: " clientId
    read -p "secret: " secret
    echo "clientId=${clientId}" > "./secret-kamatera.env"
    echo "secret=${secret}" >> "./secret-kamatera.env"
    exit 0

else
    ! kamatera_login && echo "Please login by running './kamatera.sh auth login'" && exit 1

    if [ "${1} ${2}" == "command info" ]; then
        COMMAND_ID="${3}"
        [ -z "${COMMAND_ID}" ] && echo "usage:" && echo "./kamatera.sh command info <COMMAND_ID>" && exit 1
        kamatera_curl "https://console.kamatera.com/service/queue/${COMMAND_ID}"

    elif [ "${1} ${2}" == "server options" ]; then
        kamatera_curl "https://console.kamatera.com/service/server"

    elif [ "${1} ${2}" == "server describe" ]; then
        SERVER_ID="${3}"
        [ -z "${SERVER_ID}" ] && echo "usage:" && echo "./kamatera.sh server describe <SERVER_ID>" && exit 1
        kamatera_curl "https://console.kamatera.com/service/server/${SERVER_ID}"

    elif [ "${1} ${2}" == "cluster create" ]; then
        K8S_ENVIRONMENT_NAME="${3}"; CPU="${4}"; RAM="${5}"; DISK_SIZE_GB="${6}"
        ([ -z "${K8S_ENVIRONMENT_NAME}" ] || [ -z "${CPU}" ] || [ -z "${RAM}" ] || [ -z "${DISK_SIZE_GB}" ]) \
            && echo "usage:" && echo "./kamatera.sh cluster create <K8S_ENVIRONMENT_NAME> <CPU> <RAM> <DISK_SIZE_GB>" && exit 1
        [ -e environments/${K8S_ENVIRONMENT_NAME} ] && echo "environment already exists, delete the environment directory or create a new environment" && exit 1
        mkdir -p environments/${K8S_ENVIRONMENT_NAME}
        printf "K8S_NAMESPACE=${K8S_ENVIRONMENT_NAME}\nK8S_HELM_RELEASE_NAME=kamatera\nK8S_ENVIRONMENT_NAME=${K8S_ENVIRONMENT_NAME}\n" > environments/${K8S_ENVIRONMENT_NAME}/.env
        MAIN_SERVER_PATH=$(mktemp -d)
        ! kamatera_cluster_node_create "${CPU}" "${RAM}" "${DISK_SIZE_GB}" "${MAIN_SERVER_PATH}" "${K8S_ENVIRONMENT_NAME}-master" && exit 1
        MAIN_SERVER_IP=$(cat ${MAIN_SERVER_PATH}/ip)
        export SSHPASS=$(cat ${MAIN_SERVER_PATH}/password)
        cp "${MAIN_SERVER_PATH}/params" "environments/${K8S_ENVIRONMENT_NAME}/secret-main-server-params"
        rm -rf "${MAIN_SERVER_PATH}"
        echo "intializing kubeadm as main cluster node"
        if ! sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$MAIN_SERVER_IP -- "kubeadm init --pod-network-cidr=10.244.0.0/16" | tee environments/${K8S_ENVIRONMENT_NAME}/secret-kubeadm-init.log; then
            echo "Failed to initialize kubeadm"
            exit 1
        fi
        echo "installing networking"
        if ! sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$MAIN_SERVER_IP -- "
            export KUBECONFIG=/etc/kubernetes/admin.conf &&\
            kubectl apply -f https://raw.githubusercontent.com/projectcalico/canal/master/k8s-install/1.7/rbac.yaml &&\
            kubectl apply -f https://raw.githubusercontent.com/projectcalico/canal/master/k8s-install/1.7/canal.yaml
        "; then
            echo "Failed to install networking"
            exit 1
        fi
        echo "waiting for kube-dns"
        sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$MAIN_SERVER_IP -- "
            export KUBECONFIG=/etc/kubernetes/admin.conf; \
            while ! kubectl get pods --all-namespaces | tee /dev/stderr | grep kube-dns- | grep Running; do
                echo .; sleep 10;
            done
        "
        echo "updating environment values"
        sshpass -e scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$MAIN_SERVER_IP:/etc/kubernetes/admin.conf environments/${K8S_ENVIRONMENT_NAME}/secret-admin.conf
        echo "MAIN_SERVER_IP=${MAIN_SERVER_IP}" >> environments/${K8S_ENVIRONMENT_NAME}/.env
        echo
        echo "Great Success!"
        echo
        echo "Start a local shell configured with kubectl, helm and shell completion, connected to the cluster:"
        echo
        echo "./kamatera.sh cluster shell ${K8S_ENVIRONMENT_NAME}"
        echo

    elif [ "${1} ${2}" == "cluster shell" ]; then
        K8S_ENVIRONMENT_NAME="${3}"
        CMD="${@:4}"
        [ -z "${K8S_ENVIRONMENT_NAME}" ] && echo "usage:" && echo "./kamatera.sh cluster shell <K8S_ENVIRONMENT_NAME>" && exit 1
        if [ -z "${CMD}" ]; then
            bash --rcfile <(echo "source switch_environment.sh ${K8S_ENVIRONMENT_NAME}; ${@:4}")
        else
            source switch_environment.sh "${K8S_ENVIRONMENT_NAME}" >/dev/null
            eval "${CMD}"
            exit $?
        fi

    elif [ "${1} ${2} ${3}" == "cluster node add" ]; then
        K8S_ENVIRONMENT_NAME="${4}"; CPU="${5}"; RAM="${6}"; DISK_SIZE_GB="${7}"
        ([ -z "${K8S_ENVIRONMENT_NAME}" ] || [ -z "${CPU}" ] || [ -z "${RAM}" ] || [ -z "${DISK_SIZE_GB}" ]) \
            && echo "usage:" && echo "./kamatera.sh cluster node add <K8S_ENVIRONMENT_NAME> <CPU> <RAM> <DISK_SIZE_GB>" && exit 1
        SERVER_PATH=$(mktemp -d)
        ! kamatera_cluster_node_create "${CPU}" "${RAM}" "${DISK_SIZE_GB}" "${SERVER_PATH}" "${K8S_ENVIRONMENT_NAME}-node" && exit 1
        SERVER_IP=$(cat ${SERVER_PATH}/ip)
        export SSHPASS=$(cat ${SERVER_PATH}/password)
        rm -rf "${SERVER_PATH}"
        echo "joining the cluster using kubeadm"
        if ! sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$SERVER_IP -- "
            $(cat environments/${K8S_ENVIRONMENT_NAME}/secret-kubeadm-init.log | grep 'kubeadm join --token')
        "; then
            echo "Failed to initialize kubeadm"
            exit 1
        fi

    else
        echo "unknown command"
        exit 1
    fi
fi
exit 0
