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

# base node - used to create all other nodes, a base node doesn't require an environment
kamatera_cluster_create_base_node() {
    # server options (see kamatera_server_options.json)
    CPU="${1}"; RAM="${2}"; DISK_SIZE_GB="${3}"
    # details about the created server will be stored in files under this path
    SERVER_PATH="${4}"
    # optional prefix to prepend to the randomly generated server name uuid
    NODE_PREFIX="${5}"
    # optional password, if not provided generated a random password
    SERVER_PASSWORD="${6}"
    (
        if [ -z "${SERVER_PASSWORD}" ]; then
            password=$(python -c "import random; s='abcdefghijklmnopqrstuvwxyz01234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ'; print(''.join(random.sample(s,20)))")
        else
            password="${SERVER_PASSWORD}"
            echo "using server password from argument"
        fi
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

# worker node is a base node which is part of a cluster / environment
# if the cluster master node is installed, it will register with the cluster,
# otherwise, the node will be created but won't join a cluster
# by default it is labeled as kamateranode=true - which allows to schedule general workloads on it
kamatera_cluster_create_worker_node() {
    # the kamatera environment name to add this node to
    K8S_ENVIRONMENT_NAME="${1}"
    # server options (see kamatera_server_options.json)
    CPU="${2}"; RAM="${3}"; DISK_SIZE_GB="${4}"
    # optional path, details about the created server will be stored in files under this path
    SERVER_PATH="${5}"
    # optional label to prepend to the autogenerated node id
    NODE_LABEL="${6}"
    # optional password, if not provided generates a random password
    SERVER_PASSWORD="${7}"
    # set to 1 to disable tagging the node as worker node, to allow scheduling other workloads on it
    DISABLE_NODE_TAG="${8}"
    if [ "${SERVER_PATH}" == "" ]; then
        SERVER_PATH=`mktemp -d`
        TEMP_SERVER_PATH=1
    else
        TEMP_SERVER_PATH=0
    fi
    (
        ! kamatera_cluster_create_base_node "${CPU}" "${RAM}" "${DISK_SIZE_GB}" "${SERVER_PATH}" \
                                            "${K8S_ENVIRONMENT_NAME}-${NODE_LABEL}" "${SERVER_PASSWORD}" \
            && echo "failed to create base node for a worker node" && exit 1
        SERVER_IP=$(cat ${SERVER_PATH}/ip)
        export SSHPASS=$(cat ${SERVER_PATH}/password)
        SERVER_NAME=$(cat "${SERVER_PATH}/name")
        echo "SERVER_NAME=${SERVER_NAME}"
        if [ -e "environments/${K8S_ENVIRONMENT_NAME}/.env" ]; then
            echo "joining the cluster using kubeadm"
            if ! sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$SERVER_IP -- "
                $(cat environments/${K8S_ENVIRONMENT_NAME}/secret-kubeadm-init.log | grep 'kubeadm join --token')
            "; then
                echo "Failed to initialize kubeadm"
                exit 1
            fi
            if [ "${DISABLE_NODE_TAG}" != "1" ]; then
                echo "tagging as worker node..."
                NODE_ID=$(echo "${SERVER_NAME}" | cut -d" " -f1 - | cut -d"-" -f3 -)
                echo "NODE_ID=${NODE_ID}"
                while ! kamatera_cluster_shell "${K8S_ENVIRONMENT_NAME}" kubectl label node "${K8S_ENVIRONMENT_NAME}${NODE_LABEL}${NODE_ID}" "kamateranode=true"; do
                    sleep 20
                    echo .
                done
            fi
            echo "added worker node to the cluster"
        fi
        echo "successfully created worker node"
        exit 0
    )
    if [ "${TEMP_SERVER_PATH}" == "1" ]; then
        rm -rf "${TEMP_SERVER_PATH}"
    fi
    return $?
}

# a persistent node is a worker node which has a unique server name and persistent configuration
# it has kubernetes node labels allowing to schedule specific workloads on a specific persistent node
# this is used for the core cluster services like the master nodes, storage and load balancer
kamatera_cluster_create_persistent_node() {
    # the kamatera environment name to add this node to
    K8S_ENVIRONMENT_NAME="${1}"
    # server options (see kamatera_server_options.json)
    CPU="${2}"; RAM="${3}"; DISK_SIZE_GB="${4}"
    # details about the created server will be stored in files under this path
    SERVER_PATH="${5}"
    # unique node label
    NODE_LABEL="${6}"
    # optional password, if not provided generates a random password
    SERVER_PASSWORD="${7}"
    [ -e environments/${K8S_ENVIRONMENT_NAME}/${NODE_LABEL}.env ] \
        && echo "persistent node label exists ${NODE_LABEL}, will not re-create node" && return 0
    if [ "${SERVER_PATH}" == "" ]; then
        SERVER_PATH=`mktemp -d`
        TEMP_SERVER_PATH=1
    else
        TEMP_SERVER_PATH=0
    fi
    (
        echo "creating ${NODE_LABEL} persistent node"
        DISABLE_NODE_TAG="1"
        ! kamatera_cluster_create_worker_node "${K8S_ENVIRONMENT_NAME}" "${CPU}" "${RAM}" "${DISK_SIZE_GB}" \
                                              "${SERVER_PATH}" "${NODE_LABEL}" "${SERVER_PASSWORD}" "${DISABLE_NODE_TAG}" \
            && echo "failed to create worker node for ${NODE_LABEL}" && exit 1
        if [ -e "environments/${K8S_ENVIRONMENT_NAME}/.env" ]; then
            echo "Waiting for ${NODE_LABEL} node to join the cluster..."
            while ! kamatera_cluster_shell "${K8S_ENVIRONMENT_NAME}" "kubectl get nodes | tee /dev/stderr | grep ' Ready ' | grep ${K8S_ENVIRONMENT_NAME}${NODE_LABEL}"; do echo .; sleep 20; done
        fi
        SERVER_NAME=$(cat "${SERVER_PATH}/name")
        NODE_ID=$(echo "${SERVER_NAME}" | cut -d" " -f1 - | cut -d"-" -f3 -)
        [ -z "${NODE_ID}" ] && echo "failed to get ${NODE_LABEL} server node id" && exit 1
        echo "NODE_ID=${NODE_ID}" > "environments/${K8S_ENVIRONMENT_NAME}/${NODE_LABEL}.env"
        echo "SERVER_NAME=${SERVER_NAME}" >> "environments/${K8S_ENVIRONMENT_NAME}/${NODE_LABEL}.env"
        echo "IP="$(cat ${SERVER_PATH}/ip) >> "environments/${K8S_ENVIRONMENT_NAME}/${NODE_LABEL}.env"
        cat "environments/${K8S_ENVIRONMENT_NAME}/${NODE_LABEL}.env"
        export SSHPASS=$(cat ${SERVER_PATH}/password)
        echo "${SSHPASS}" > "environments/${K8S_ENVIRONMENT_NAME}/secret-${NODE_LABEL}-pass"
        cp "${SERVER_PATH}/params" "environments/${K8S_ENVIRONMENT_NAME}/secret-${NODE_LABEL}-params"
        if [ -e "environments/${K8S_ENVIRONMENT_NAME}/.env" ]; then
            echo "setting kubernetes node label to identify as ${NODE_LABEL}"
            while ! kamatera_cluster_shell "${K8S_ENVIRONMENT_NAME}" "kubectl label node ${K8S_ENVIRONMENT_NAME}${NODE_LABEL}${NODE_ID} kamatera${NODE_LABEL}=true"; do echo .; sleep 20; done
        fi
        exit 0
    )
    if [ "${TEMP_SERVER_PATH}" == "1" ]; then
        rm -rf "${TEMP_SERVER_PATH}"
    fi
    return $?
}

# create a persistent node that will act as the kubernetes master for the given environment
kamatera_cluster_create_master_node() {
    # the kamatera environment name to initialize for this master node
    K8S_ENVIRONMENT_NAME="${1}"
    # server options (see kamatera_server_options.json)
    CPU="${2}"; RAM="${3}"; DISK_SIZE_GB="${4}"
    # details about the created server will be stored in files under this path
    SERVER_PATH="${5}"
    # optional password, if not provided generates a random password
    SERVER_PASSWORD="${6}"
    (
        NODE_LABEL="master"
        ! kamatera_cluster_create_persistent_node "${K8S_ENVIRONMENT_NAME}" "${CPU}" "${RAM}" "${DISK_SIZE_GB}" \
                                                  "${SERVER_PATH}" "${NODE_LABEL}" "${SERVER_PASSWORD}" \
            && echo "failed to create persistent node for master node" && exit 1
        eval `cat environments/${K8S_ENVIRONMENT_NAME}/${NODE_LABEL}.env`
        export SSHPASS=$(cat "environments/${K8S_ENVIRONMENT_NAME}/secret-${NODE_LABEL}-pass")
        echo "initializing environment..."
        printf "K8S_NAMESPACE=${K8S_ENVIRONMENT_NAME}\nK8S_HELM_RELEASE_NAME=kamatera\nK8S_ENVIRONMENT_NAME=${K8S_ENVIRONMENT_NAME}\n" > "environments/${K8S_ENVIRONMENT_NAME}/.env"
        if ! sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$IP -- "kubeadm init --pod-network-cidr=10.244.0.0/16" | tee environments/${K8S_ENVIRONMENT_NAME}/secret-kubeadm-init.log; then
            echo "Failed to initialize kubeadm"
            exit 1
        fi
        echo "installing networking"
        if ! sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$IP -- "
            export KUBECONFIG=/etc/kubernetes/admin.conf &&\
            kubectl apply -f https://raw.githubusercontent.com/projectcalico/canal/master/k8s-install/1.7/rbac.yaml &&\
            kubectl apply -f https://raw.githubusercontent.com/projectcalico/canal/master/k8s-install/1.7/canal.yaml
        "; then
            echo "Failed to install networking"
            exit 1
        fi
        echo "waiting for kube-dns"
        sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$IP -- "
            export KUBECONFIG=/etc/kubernetes/admin.conf; \
            while ! kubectl get pods --all-namespaces | tee /dev/stderr | grep kube-dns- | grep Running; do
                echo .; sleep 10;
            done
        "
        echo "updating environment values"
        sshpass -e scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$IP:/etc/kubernetes/admin.conf environments/${K8S_ENVIRONMENT_NAME}/secret-admin.conf
        echo "updating master node taints"
        kamatera_cluster_shell "${K8S_ENVIRONMENT_NAME}" kubectl taint nodes --all node-role.kubernetes.io/master-
        echo "MAIN_SERVER_IP=${IP}" >> environments/${K8S_ENVIRONMENT_NAME}/.env
        exit 0
    )
    return $?
}

# creates a persistent node that will act as the loadbalancer for the environment
kamatera_cluster_create_loadbalancer_node() {
    # the kamatera environment name to add this node to
    K8S_ENVIRONMENT_NAME="${1}"
    # server options (see kamatera_server_options.json)
    CPU="${2}"; RAM="${3}"; DISK_SIZE_GB="${4}"
    # optional path, details about the created server will be stored in files under this path
    SERVER_PATH="${5}"
    # optional loadbalancer environment configuration details
    ENV_CONFIG="${6}"
    # optional password, if not provided generates a random password
    SERVER_PASSWORD="${7}"
    (
        NODE_LABEL="loadbalancer"
        ! kamatera_cluster_create_persistent_node "${K8S_ENVIRONMENT_NAME}" "${CPU}" "${RAM}" "${DISK_SIZE_GB}" \
                                                  "${SERVER_PATH}" "${NODE_LABEL}" "${SERVER_PASSWORD}" \
            && echo "failed to create persistent node for ${NODE_LABEL} node" && exit 1
        eval `cat environments/${K8S_ENVIRONMENT_NAME}/${NODE_LABEL}.env`
        export SSHPASS=$(cat "environments/${K8S_ENVIRONMENT_NAME}/secret-${NODE_LABEL}-pass")
        echo "setting up ${NODE_LABEL} node..."
        sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$IP -- "mkdir -p /etc/traefik; docker pull traefik"
        ./update_yaml.py '{"global":{"enableRootChart":true},"loadBalancer":{"enabled":true,"nodeName":"'"${K8S_ENVIRONMENT_NAME}loadbalancer${NODE_ID}"'"}}' "environments/${K8S_ENVIRONMENT_NAME}/values.auto-updated.yaml"
        echo "deploying to enable root chart and load balancer..."
        kamatera_cluster_deploy "${K8S_ENVIRONMENT_NAME}" --install
        if [ $(./read_yaml.py environments/${K8S_ENVIRONMENT_NAME}/values.auto-updated.yaml nginx enabled) != "true" ]; then
            if ! kamatera_cluster_shell "${K8S_ENVIRONMENT_NAME}" kubectl describe secret nginx-htpasswd; then
                echo "create nginx http auth secrets..."
                password=$(python -c "import random; s='abcdefghijklmnopqrstuvwxyz01234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ'; print(''.join(random.sample(s,20)))")
                ! [ -e environments/${K8S_ENVIRONMENT_NAME}/secret-nginx-htpasswd ] &&\
                    htpasswd -bc environments/${K8S_ENVIRONMENT_NAME}/secret-nginx-htpasswd superadmin "${password}"
                kamatera_cluster_shell "${K8S_ENVIRONMENT_NAME}" kubectl create secret generic nginx-htpasswd --from-file=environments/${K8S_ENVIRONMENT_NAME}/secret-nginx-htpasswd
                echo
                echo "http auth credentials"
                echo
                echo "username = superadmin"
                echo "password = ${password}"
                echo
                echo "the credentials cannot be retrieved later"
                echo
            fi
            echo "enabling and deploying nginx..."
            ./update_yaml.py '{"nginx":{"enabled":true,"htpasswdSecretName":"nginx-htpasswd"}}' "environments/${K8S_ENVIRONMENT_NAME}/values.auto-updated.yaml"
            kamatera_cluster_deploy "${K8S_ENVIRONMENT_NAME}"
            echo "getting nginx service ip..."
            while true; do
                NGINX_SERVICE_IP=$(echo $(kamatera_cluster_shell "${K8S_ENVIRONMENT_NAME}" "kubectl describe service nginx | grep 'IP:' | cut -d"'" "'" -f2-"))
                ! [ -z "${NGINX_SERVICE_IP}" ] && break
                sleep 10
            done
            echo "updating nginx service ip (${NGINX_SERVICE_IP}) in load balancer..."
            ./update_yaml.py '{"loadBalancer":{"nginxServiceClusterIP":"'${NGINX_SERVICE_IP}'"}}' "environments/${K8S_ENVIRONMENT_NAME}/values.auto-updated.yaml"
        fi
        if ! [ -z "${ENV_CONFIG}" ]; then
            echo "setting traefik environment variables..."
            ! sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$IP -- "
                for VAR in "'$(echo "'"${ENV_CONFIG}"'")'"; do echo "'"${VAR}"'"; done > /traefik.env;
            " && echo "failed to set traefik env vars" && exit 1
        fi
        echo "deploying to apply any cluster configuration changes..."
        kamatera_cluster_deploy "${K8S_ENVIRONMENT_NAME}"
        echo "reloading traefik..."
        sleep 15
        ! sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$IP -- "
            docker rm --force traefik;
            ! [ -e /traefik.env ] && touch /traefik.env;
            docker run --name=traefik -d -p 80:80 -p 443:443 -p 3033:3033 \
                                      -v /etc/traefik:/etc-traefik -v /var/traefik-acme:/traefik-acme \
                                      --env-file /traefik.env \
                                      traefik --configFile=/etc-traefik/traefik.toml
        " && echo "failed to reload the load balancer" && exit 1
        echo "verifying traefik container state..."
        sleep 5
        TRAEFIK_JSON=$(sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$IP -- "docker inspect traefik") &&\
        [ $(printf "${TRAEFIK_JSON}" | jq -r '.[0].State.Status' | tee /dev/stderr) == "running" ]
        [ "$?" != "0" ] && echo "failed to verify installation of existing load balancer node" && exit 1
        echo Id=$(printf "${TRAEFIK_JSON}" | jq '.[0].Id')
        printf "${TRAEFIK_JSON}" | jq '.[0].State'
        ROOT_DOMAIN=`eval echo $(./read_yaml.py environments/${K8S_ENVIRONMENT_NAME}/values.yaml loadBalancer letsEncrypt rootDomain)`
        echo "load balancer was installed and updated successfully"
        echo "Public IP: ${IP}"
        ! [ -z "${ROOT_DOMAIN}" ] && echo "Root Domain: ${ROOT_DOMAIN}"
        ! [ -z "${ROOT_DOMAIN}" ] && echo "Kubernetes Dashboard: https://${ROOT_DOMAIN}/dashboard/"
        exit 0
    )
    return $?
}

# creates a persistent node that will act as the storage for the environment
kamatera_cluster_create_storage_node() {
    # the kamatera environment name to add this node to
    K8S_ENVIRONMENT_NAME="${1}"
    # server options (see kamatera_server_options.json)
    CPU="${2}"; RAM="${3}"; DISK_SIZE_GB="${4}"
    # optional path, details about the created server will be stored in files under this path
    SERVER_PATH="${5}"
    # optional password, if not provided generates a random password
    SERVER_PASSWORD="${6}"
    (
        NODE_LABEL="storage"
        ! kamatera_cluster_create_persistent_node "${K8S_ENVIRONMENT_NAME}" "${CPU}" "${RAM}" "${DISK_SIZE_GB}" \
                                                  "${SERVER_PATH}" "${NODE_LABEL}" "${SERVER_PASSWORD}" \
            && echo "failed to create persistent node for ${NODE_LABEL} node" && exit 1
        eval `cat environments/${K8S_ENVIRONMENT_NAME}/${NODE_LABEL}.env`
        export SSHPASS=$(cat "environments/${K8S_ENVIRONMENT_NAME}/secret-${NODE_LABEL}-pass")
        echo "setting up ${NODE_LABEL} node..."
        sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$IP -- "
            mkdir -p /opt/kamatera/storage &&
            while ! apt-get update; do sleep 5; done &&\
            while ! apt-get install -y nfs-common nfs-kernel-server; do sleep 5; done
        "
        ./update_yaml.py '{"global":{"enableRootChart":true},"storage":{"enabled":true,"nodeName":"'"${K8S_ENVIRONMENT_NAME}${NODE_LABEL}${NODE_ID}"'"}}' "environments/${K8S_ENVIRONMENT_NAME}/values.auto-updated.yaml"
        echo "deploying to enable root chart and storage server..."
        kamatera_cluster_deploy "${K8S_ENVIRONMENT_NAME}" --install
        echo "getting nfs server cluster IP..."
        while true; do
            NFS_SERVICE_IP="$(kamatera_cluster_shell "${K8S_ENVIRONMENT_NAME}" kubectl get service nfs-server -ojson | jq -r .spec.clusterIP)"
            ! [ -z "${NFS_SERVICE_IP}" ] && break
        done
        echo "setting NFS_SERVICE_IP=${NFS_SERVICE_IP}..."
        ./update_yaml.py '{"global":{"nfsEnabled":true},"storage":{"nfsServiceIP":"'${NFS_SERVICE_IP}'"}}' "environments/${K8S_ENVIRONMENT_NAME}/values.auto-updated.yaml"
        ./kamatera.sh cluster deploy "${K8S_ENVIRONMENT_NAME}"
        echo "storage node was installed and updated successfully"
        exit 0
    )
    return $?
}

# connect to the given environment and start a shell session or run commands
kamatera_cluster_shell() {
    K8S_ENVIRONMENT_NAME="${1}"
    CMD="${@:2}"
    if [ -z "${CMD}" ]; then
        bash --rcfile <(echo "source switch_environment.sh ${K8S_ENVIRONMENT_NAME}; ${CMD}")
        return $?
    else
        source switch_environment.sh "${K8S_ENVIRONMENT_NAME}" >/dev/null
        eval "${CMD}"
        return $?
    fi
}

# store the kamatera API credentials
kamatera_auth_login() {
    echo "Enter your kamatera API clientId and secret, they will be stored in `pwd`/secret-kamatera.env"
    [ -e ./secret-kamatera.env ] && echo "WARNING! will overwrite existing secret-kamatera.env file, Press Ctrl+C to abort."
    read -p "clientID: " clientId
    read -p "secret: " secret
    echo "clientId=${clientId}" > "./secret-kamatera.env"
    echo "secret=${secret}" >> "./secret-kamatera.env"
    return 0
}

kamatera_cluster_deploy() {
    K8S_ENVIRONMENT_NAME="${1}"
    while ! kamatera_cluster_shell "${K8S_ENVIRONMENT_NAME}" "
        kubectl apply -f helm-tiller-rbac-config.yaml;
        helm init --service-account tiller --upgrade --force-upgrade --history-max 2
    "; do echo .; sleep 10; done
    while ! kamatera_cluster_shell "${K8S_ENVIRONMENT_NAME}" "
        ./helm_upgrade.sh ${@:4}
    "; do echo .; sleep 10; done
    return 0
}

usage() {
    [ -z "${SHOW_HELP_INDEX}" ] && echo "usage:"
    echo "./kamatera.sh ${1}"
}

if [ "${1} ${2}" == "auth login" ]; then
    kamatera_auth_login
    exit $?

else
    ! kamatera_login && echo "Please login by running './kamatera.sh auth login'" && exit 1


    ### low-level Kamatera service commands ###

    if [ "${1} ${2}" == "command info" ]; then
        [ -z "${3}" ] && usage "command info <COMMAND_ID>" && exit 1
        kamatera_curl "https://console.kamatera.com/service/queue/${3}"; exit $?

    elif [ "${1} ${2}" == "server options" ]; then
        kamatera_curl "https://console.kamatera.com/service/server"; exit $?

    elif [ "${1} ${2}" == "server describe" ]; then
        [ -z "${3}" ] && usage "server describe <SERVER_ID>" && exit 1
        kamatera_curl "https://console.kamatera.com/service/server/${SERVER_ID}"; exit $?

    elif [ "${1} ${2}" == "server list" ]; then
        if [ "${3}" == "--raw" ]; then
            kamatera_curl "https://console.kamatera.com/service/servers"
            exit $?
        elif [ "${3}" == "" ]; then
            kamatera_curl "https://console.kamatera.com/service/servers" \
                | jq -r 'map([.power,.name,.id]|join(" "))|join("\n")' \
                | grep '^on ' \
                | cut -d" " -f2- -
            exit $?
        else
            usage "server list [--raw]"
            exit 1
        fi

    elif [ "${1} ${2}" == "server ip" ]; then
        [ -z "${3}" ] && usage "server ip <SERVER_ID>" && exit 1
        kamatera_curl "https://console.kamatera.com/service/server/${3}" | jq -r '.networks[0].ips[0]'
        exit $?

    elif [ "${1} ${2}" == "server terminate" ]; then
        ( [ -z "${3}" ] || [ -z "${4}" ] || [ -z "${5}" ] ) \
            && usage "server terminate <SERVER_ID> <SERVER_NAME> <APPROVE>" && exit 1
        SERVER_ID="${3}"; SERVER_NAME="${4}"; APPROVE="${5}"
        ! [ "${SERVER_NAME}" == "`./kamatera.sh server list | grep "${SERVER_ID}" | cut -d" " -f1 -`" ] && exit 1
        [ "${APPROVE}" != "yes" ] && exit 1
        echo "Terminating server"
        kamatera_curl -X DELETE -d "confirm=1&force=1" "https://console.kamatera.com/service/server/${SERVER_ID}/terminate"
        exit $?


    ### cluster commands ###

    elif [ "${1} ${2}" == "cluster list" ]; then
        [ "${3}" == "--help" ] && usage "cluster list" && exit 1
        printf '['
        if [ -e "environments" ]; then
            pushd environments/ >/dev/null
                FIRST=1
                for K8S_ENVIRONMENT_NAME in *; do
                    if [ "${FIRST}" == "1" ]; then
                        FIRST=0
                    else
                        echo ','
                        printf ' '
                    fi
                    MAIN_SERVER_IP=""
                    [ -e $K8S_ENVIRONMENT_NAME/.env ] && eval `cat $K8S_ENVIRONMENT_NAME/.env`
                    IP=""
                    [ -e $K8S_ENVIRONMENT_NAME/loadbalancer.env ] && eval `cat $K8S_ENVIRONMENT_NAME/loadbalancer.env`
                    LOAD_BALANCER_IP="${IP}"
                    IP=""
                    [ -e $K8S_ENVIRONMENT_NAME/storage.env ] && eval `cat $K8S_ENVIRONMENT_NAME/storage.env`
                    STORAGE_IP="${IP}"
                    printf '{'
                    printf '"name": "'${K8S_ENVIRONMENT_NAME}'",'
                    printf '"main_server_ip": "'${MAIN_SERVER_IP}'",'
                    printf '"load_balancer_ip": "'${LOAD_BALANCER_IP}'",'
                    printf '"storage_ip": "'${STORAGE_IP}'"'
                    printf '}'
                done
            popd >/dev/null
        fi
        printf ']'
        echo
        exit 0

    elif [ "${1} ${2}" == "cluster create" ]; then
        [ -z "${3}" ] && usage "cluster create <ENVIRONMENT_NAME> [CPU] [RAM] [DISK_SIZE_GB] [SERVER_PATH] [SERVER_PASSWORD]" && exit 1
        [ -e "environments/${3}/.env" ] \
            && echo "environment already exists, delete the environment's .env file to recreate" && exit 1
        ! mkdir -p "environments/${3}" && echo "failed to create environment directory" && exit 1
        ! kamatera_cluster_create_master_node "${3}" "${4}" "${5}" "${6}" "${7}" "${8}" \
            && echo "failed to create cluster" && exit 1
        echo
        echo "Start a local shell configured with kubectl, helm and shell completion, connected to the cluster:"
        echo
        echo "./kamatera.sh cluster shell ${K8S_ENVIRONMENT_NAME}"
        echo
        exit 0

    elif [ "${1} ${2}" == "cluster shell" ]; then
        [ -z "${3}" ] && usage "cluster shell <ENVIRONMENT_NAME>" && exit 1
        ! [ -e "environments/${3}/.env" ] && echo "invalid environment: ${3}" && exit 1
        kamatera_cluster_shell "${3}" "${@:4}"
        exit $?

    elif [ "${1} ${2} ${3}" == "cluster node add" ]; then
        ( [ -z "${4}" ] || [ -z "${5}" ] || [ -z "${6}" ] || [ -z "${7}" ] ) \
            && usage "cluster node add <ENVIRONMENT_NAME> <CPU> <RAM> <DISK_SIZE_GB> [SERVER_PATH] [SERVER_PASSWORD]" && exit 1
        kamatera_cluster_create_worker_node "${4}" "${5}" "${6}" "${7}" "${8}" "node" "${9}"
        exit $?

    elif [ "${1} ${2} ${3}" == "cluster loadbalancer install" ]; then
        [ -z "${4}" ] && usage "cluster loadbalancer install <ENVIRONMENT_NAME> [ENV_CONFIG] [SERVER_PASSWORD]" && exit 1
        kamatera_cluster_create_loadbalancer_node "${4}" "2B" "2048" "20" "" "${5}" "${6}"
        exit $?

    elif [ "${1} ${2} ${3}" == "cluster loadbalancer web-ui" ]; then
        [ -z "${4}" ] && usage "cluster loadbalancer web-ui <ENVIRONMENT_NAME>" && exit 1
        ! [ -e "environments/${K8S_ENVIRONMENT_NAME}/loadbalancer.env" ] \
            && echo "loadbalancer is not installed" && exit 1
        export SSHPASS=$(cat "environments/${K8S_ENVIRONMENT_NAME}/secret-loadbalancer-pass")
        eval `cat environments/${K8S_ENVIRONMENT_NAME}/loadbalancer.env`
        echo "Load Balancer Public IP: ${IP}"
        echo "you can access the traefik web-ui at http://localhost:3033"
        echo "quit by pressing Ctrl+C"
        sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$IP -L "3033:localhost:3033" -nN

    elif [ "${1} ${2} ${3}" == "cluster loadbalancer info" ]; then
        [ -z "${4}" ] && usage "cluster loadbalancer info <ENVIRONMENT_NAME>" && exit 1
        ! [ -e "environments/${4}/loadbalancer.env" ] \
            && echo "loadbalancer is not installed" && exit 1
        export SSHPASS=$(cat "environments/${4}/secret-loadbalancer-pass")
        eval `cat environments/${K8S_ENVIRONMENT_NAME}/loadbalancer.env`
        ROOT_DOMAIN=`eval echo $(./read_yaml.py environments/${4}/values.yaml loadBalancer letsEncrypt rootDomain)`
        echo "Load Balancer Public IP: ${IP}"
        ! [ -z "${ROOT_DOMAIN}" ] && echo "Root Domain: $(echo ${ROOT_DOMAIN})"
        ! [ -z "${ROOT_DOMAIN}" ] && echo "Kubernetes Dashboard: https://$(echo ${ROOT_DOMAIN})/dashboard/"

    elif [ "${1} ${2} ${3}" == "cluster loadbalancer ssh" ]; then
        [ -z "${4}" ] && usage "cluster loadbalancer ssh <ENVIRONMENT_NAME>" && exit 1
        ! [ -e "environments/${4}/loadbalancer.env" ] \
            && echo "loadbalancer is not installed" && exit 1
        export SSHPASS=$(cat "environments/${4}/secret-loadbalancer-pass")
        eval `cat environments/${4}/loadbalancer.env`
        sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$IP

    elif [ "${1} ${2} ${3}" == "cluster storage install" ]; then
        ( [ -z "${4}" ] ) && usage "cluster storage install <ENVIRONMENT_NAME>" && exit 1
        helm install rook-master/rook --version $(helm search rook | grep rook-master/rook | cut -f2 -)
        # TODO: allow to create dedicated storage nodes using Rook
#        ( [ -z "${4}" ] ) && usage "cluster storage install <ENVIRONMENT_NAME> [DISK_SIZE_GB]" && exit 1
#        [ -e "environments/${4}/storage.env" ] && ! [ -z "${5}" ] \
#            && echo "cannot change disk size of existing storage node" && exit 1
#        ! [ -e "environments/${4}/storage.env" ] && [ -z "${5}" ] \
#            && echo "must specify disk size when creating new storage node" && exit 1
#        kamatera_cluster_create_storage_node "${4}" "2B" "2048" "${5}"
        exit $?

    elif [ "${1} ${2} ${3}" == "cluster storage ssh" ]; then
        [ -z "${4}" ] && usage "cluster storage ssh <ENVIRONMENT_NAME>" && exit 1
        ! [ -e "environments/${4}/storage.env" ] \
            && echo "storage is not installed" && exit 1
        export SSHPASS=$(cat "environments/${4}/secret-storage-pass")
        eval `cat environments/${4}/storage.env`
        sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$IP

    elif [ "${1} ${2}" == "cluster deploy" ]; then
        [ -z "${3}" ] && usage "cluster deploy <ENVIRONMENT_NAME>" && exit 1
        kamatera_cluster_deploy "${3}"

    elif [ "${1} ${2}" == "cluster web-ui" ]; then
        [ -z "${3}" ] && usage "cluster web-ui <ENVIRONMENT_NAME>" && exit 1
        echo "Kubernetes dashboard should be accessible at http://localhost:9090/"
        kamatera_cluster_shell ${3} kubectl port-forward $(kubectl get pods --namespace=kube-system | grep kubernetes-dashboard- | cut -d" " -f1 -) 9090 --namespace=kube-system
        exit $?

    elif [ "${SHOW_HELP_INDEX}" != "1" ]; then
        export SHOW_HELP_INDEX=1
        ./kamatera.sh cluster create
        ./kamatera.sh cluster list --help
        ./kamatera.sh cluster web-ui
        ./kamatera.sh cluster deploy
        ./kamatera.sh cluster loadbalancer install
        ./kamatera.sh cluster loadbalancer info
        ./kamatera.sh cluster loadbalancer ssh
        ./kamatera.sh cluster loadbalancer web-ui
        ./kamatera.sh cluster storage install
        ./kamatera.sh cluster storage ssh
        ./kamatera.sh cluster node add
        ./kamatera.sh cluster shell
        exit 1

    fi
fi
exit 0
