
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
    if [ "${KAMATERA_DEBUG}" == "1" ]; then
        echo "DEBUG: ${*}" | tee -a ./kamatera.log
    else
        echo "DEBUG: ${*}" >> ./kamatera.log
    fi
}

kamatera_debug_file() {
    kamatera_debug "${1}
$(cat "${1}")"
}

kamatera_info() {
    echo "INFO: ${@}" | tee -a ./kamatera.log
}

kamatera_start_progress() {
    kamatera_info "${@}"
}

kamatera_progress() {
    printf "." | tee -a ./kamatera.log
    if [ "${1}" != "" ]; then
        sleep "${1}"
    fi
}

kamatera_wait_progress() {
    # this just provides nicer UX while waiting..
    kamatera_progress 5; kamatera_progress 6; kamatera_progress 7; kamatera_progress 2; kamatera_progress 3
    kamatera_progress 4; kamatera_progress 4; kamatera_progress 5; kamatera_progress 6; kamatera_progress 4
}

kamatera_stop_progress() {
    kamatera_info "${@}"
}

kamatera_warning() {
    echo "WARNING: ${@}" | tee -a ./kamatera.log
}

kamatera_error() {
    echo "ERROR: ${@}" | tee -a ./kamatera.log
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
        RES=$(kamatera_curl -X POST -d "${params}" "https://console.kamatera.com/service/server")
        kamatera_debug "${RES}"
        COMMAND_ID=$(echo "${RES}" | jq -r '.[0]')
        kamatera_debug "COMMAND_ID=${COMMAND_ID}"
        echo "${COMMAND_ID}" > "${SERVER_PATH}/command_id"
        [ -z "${COMMAND_ID}" ] && kamatera_error "failed to create server: ${RES}" && exit 1
        kamatera_info "you can track progress by running './kamatera.sh command info ${COMMAND_ID}' or in kamatera console web UI task queue"
        kamatera_start_progress "waiting for kamatera server create command to complete, please wait"
        while true; do
            kamatera_wait_progress
            COMMAND_INFO_JSON=$(./kamatera.sh command info ${COMMAND_ID} 2>/dev/null)
            if [ "${KAMATERA_DEBUG}" == "1" ]; then
                printf "${COMMAND_INFO_JSON}"
                echo
            fi
            STATUS=$(echo $COMMAND_INFO_JSON | jq -r .status)
            if [ "${STATUS}" == "complete" ]; then
                break
            elif [ "${STATUS}" == "error" ]; then
                kamatera_info "COMMAND_INFO_JSON=${COMMAND_INFO_JSON}"
                kamatera_error "command completed with error"
                exit 1
            elif [ "${STATUS}" == "cancelled" ]; then
                kamatera_info "COMMAND_INFO_JSON=${COMMAND_INFO_JSON}"
                kamatera_error "command was cancelled before it was executed"
                exit 1
            fi
        done
        kamatera_stop_progress "command completed successfully"
        COMMAND_LOG=`echo $COMMAND_INFO_JSON | jq -r .log`
        kamatera_debug "COMMAND_LOG=${COMMAND_LOG}"
        SERVER_IP=$(echo "${COMMAND_LOG}" | grep '^Network #1: wan' | grep -o '[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*')
        kamatera_debug "SERVER_IP=${SERVER_IP}"
        echo "${SERVER_IP}" > "${SERVER_PATH}/ip"
        kamatera_start_progress "waiting for ssh access to the server"
        export SSHPASS="${password}"
        while true; do
            kamatera_wait_progress
            if sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$SERVER_IP true >> ./kamatera.log 2>&1; then
                break
            fi
        done
        kamatera_stop_progress "OK"
        kamatera_info "preparing the server for kube-adm installation"
        if ! sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$SERVER_IP -- "
            swapoff -a && sed -i '/ swap / s/^/#/' /etc/fstab &&\
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
        " >> ./kamatera.log 2>&1; then
            kamatera_error "Failed to prepare the server for kube-adm"
            exit 1
        fi
        kamatera_info "successfully created base node"
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
    [ -z "${K8S_ENVIRONMENT_NAME}" ] && kamatera_error missing K8S_ENVIRONMENT_NAME && return 1
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
            && kamatera_error "failed to create base node for a worker node" && exit 1
        kamatera_start_progress "configuring worker node"
        SERVER_IP=$(cat ${SERVER_PATH}/ip)
        export SSHPASS=$(cat ${SERVER_PATH}/password)
        SERVER_NAME=$(cat "${SERVER_PATH}/name")
        kamatera_debug "SERVER_NAME=${SERVER_NAME}"
        if [ -e "environments/${K8S_ENVIRONMENT_NAME}/.env" ]; then
            kamatera_debug "joining the cluster using kubeadm"
            if ! sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$SERVER_IP -- "
                $(cat environments/${K8S_ENVIRONMENT_NAME}/secret-kubeadm-init.log | grep 'kubeadm join --token')
            " >> ./kamatera.log 2>&1; then
                kamatera_error "Failed to initialize kubeadm"
                exit 1
            fi
            kamatera_progress
            if [ "${DISABLE_NODE_TAG}" != "1" ]; then
                kamatera_debug "tagging as worker node..."
                NODE_ID=$(echo "${SERVER_NAME}" | cut -d" " -f1 - | cut -d"-" -f3 -)
                kamatera_debug "NODE_ID=${NODE_ID}"
                while ! kamatera_cluster_shell "${K8S_ENVIRONMENT_NAME}" kubectl label node "${K8S_ENVIRONMENT_NAME}${NODE_LABEL}${NODE_ID}" "kamateranode=true"; do
                    kamatera_progress
                    sleep 15
                done
            fi
            kamatera_progress
            kamatera_debug "added worker node to the cluster"
        fi
        kamatera_stop_progress "successfully created worker node"
        exit 0
    )
    RES=$?
    if [ "${TEMP_SERVER_PATH}" == "1" ]; then
        rm -rf "${TEMP_SERVER_PATH}"
    fi
    return $RES
}

# a persistent node is a worker node which has a unique server name and persistent configuration
# it has kubernetes node labels allowing to schedule specific workloads on a specific persistent node
# this is used for the core cluster services like the master nodes and load balancer
kamatera_cluster_create_persistent_node() {
    # the kamatera environment name to add this node to
    K8S_ENVIRONMENT_NAME="${1}"
    [ -z "${K8S_ENVIRONMENT_NAME}" ] && kamatera_error missing K8S_ENVIRONMENT_NAME && return 1
    # server options (see kamatera_server_options.json)
    CPU="${2}"; RAM="${3}"; DISK_SIZE_GB="${4}"
    # details about the created server will be stored in files under this path
    SERVER_PATH="${5}"
    # unique node label
    NODE_LABEL="${6}"
    # optional password, if not provided generates a random password
    SERVER_PASSWORD="${7}"
    [ -e environments/${K8S_ENVIRONMENT_NAME}/${NODE_LABEL}.env ] \
        && kamatera_warning "persistent node label exists ${NODE_LABEL}, will not re-create node" && return 0
    if [ "${SERVER_PATH}" == "" ]; then
        SERVER_PATH=`mktemp -d`
        TEMP_SERVER_PATH=1
    else
        TEMP_SERVER_PATH=0
    fi
    (
        kamatera_info "creating ${NODE_LABEL} persistent node"
        DISABLE_NODE_TAG="1"
        ! kamatera_cluster_create_worker_node "${K8S_ENVIRONMENT_NAME}" "${CPU}" "${RAM}" "${DISK_SIZE_GB}" \
                                              "${SERVER_PATH}" "${NODE_LABEL}" "${SERVER_PASSWORD}" "${DISABLE_NODE_TAG}" \
            && kamatera_error "failed to create node for ${NODE_LABEL}" && exit 1
        if [ -e "environments/${K8S_ENVIRONMENT_NAME}/.env" ]; then
            kamatera_start_progress "Waiting for ${NODE_LABEL} node to join the cluster..."
            while ! kamatera_cluster_shell "${K8S_ENVIRONMENT_NAME}" "
                kubectl get nodes | tee /dev/stderr | grep ' Ready ' | grep ${K8S_ENVIRONMENT_NAME}${NODE_LABEL}
            "; do
                kamatera_progress
                sleep 20
            done
        fi
        SERVER_NAME=$(cat "${SERVER_PATH}/name")
        NODE_ID=$(echo "${SERVER_NAME}" | cut -d" " -f1 - | cut -d"-" -f3 -)
        [ -z "${NODE_ID}" ] && kamatera_error "failed to get ${NODE_LABEL} server node id" && exit 1
        echo "NODE_ID=${NODE_ID}" > "environments/${K8S_ENVIRONMENT_NAME}/${NODE_LABEL}.env"
        sleep 2; kamatera_progress
        echo "SERVER_NAME=${SERVER_NAME}" >> "environments/${K8S_ENVIRONMENT_NAME}/${NODE_LABEL}.env"
        sleep 2; kamatera_progress
        echo "IP="$(cat ${SERVER_PATH}/ip) >> "environments/${K8S_ENVIRONMENT_NAME}/${NODE_LABEL}.env"
        sleep 2; kamatera_progress
        cat "environments/${K8S_ENVIRONMENT_NAME}/${NODE_LABEL}.env"
        sleep 2; kamatera_progress
        export SSHPASS=$(cat ${SERVER_PATH}/password)
        echo "${SSHPASS}" > "environments/${K8S_ENVIRONMENT_NAME}/secret-${NODE_LABEL}-pass"
        sleep 2; kamatera_progress
        cp "${SERVER_PATH}/params" "environments/${K8S_ENVIRONMENT_NAME}/secret-${NODE_LABEL}-params"
        if [ -e "environments/${K8S_ENVIRONMENT_NAME}/.env" ]; then
            kamatera_debug "setting kubernetes node label to identify as ${NODE_LABEL}"
            while ! kamatera_cluster_shell "${K8S_ENVIRONMENT_NAME}" "
                kubectl label node ${K8S_ENVIRONMENT_NAME}${NODE_LABEL}${NODE_ID} kamatera${NODE_LABEL}=true
            "; do
                kamatera_progress
                sleep 20
            done
        fi
        kamatera_stop_progress "${NODE_LABEL} node created successfully"
        exit 0
    )
    RES=$?
    if [ "${TEMP_SERVER_PATH}" == "1" ]; then
        rm -rf "${TEMP_SERVER_PATH}"
    fi
    return $RES
}

# create a persistent node that will act as the kubernetes master for the given environment
kamatera_cluster_create_master_node() {
    # the kamatera environment name to initialize for this master node
    K8S_ENVIRONMENT_NAME="${1}"
    [ -z "${K8S_ENVIRONMENT_NAME}" ] && kamatera_error missing K8S_ENVIRONMENT_NAME && return 1
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
            && kamatera_error "failed to create master node" && exit 1
        eval `cat environments/${K8S_ENVIRONMENT_NAME}/${NODE_LABEL}.env`
        export SSHPASS=$(cat "environments/${K8S_ENVIRONMENT_NAME}/secret-${NODE_LABEL}-pass")
        kamatera_start_progress "initializing master node"
        printf "K8S_NAMESPACE=${K8S_ENVIRONMENT_NAME}\nK8S_HELM_RELEASE_NAME=kamatera\nK8S_ENVIRONMENT_NAME=${K8S_ENVIRONMENT_NAME}\n" > "environments/${K8S_ENVIRONMENT_NAME}/.env"
        if ! sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$IP -- "kubeadm init --pod-network-cidr=10.244.0.0/16" > environments/${K8S_ENVIRONMENT_NAME}/secret-kubeadm-init.log 2>&1; then
            kamatera_error "Failed to initialize kubeadm"
            exit 1
        fi
        kamatera_progress
        kamatera_debug "installing networking"
        if ! sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$IP -- "
            export KUBECONFIG=/etc/kubernetes/admin.conf &&\
            kubectl apply -f https://raw.githubusercontent.com/projectcalico/canal/master/k8s-install/1.7/rbac.yaml &&\
            kubectl apply -f https://raw.githubusercontent.com/projectcalico/canal/master/k8s-install/1.7/canal.yaml
        " >> ./kamatera.log 2>&1; then
            kamatera_error "Failed to install networking"
            exit 1
        fi
        kamatera_progress
        kamatera_debug "waiting for kube-dns"
        sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$IP -- "
            export KUBECONFIG=/etc/kubernetes/admin.conf; \
            while ! kubectl get pods --all-namespaces | tee /dev/stderr | grep kube-dns- | grep Running; do
                echo .; sleep 10;
            done
        " >> ./kamatera.log 2>&1
        kamatera_progress
        kamatera_debug "updating environment values"
        sshpass -e scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$IP:/etc/kubernetes/admin.conf environments/${K8S_ENVIRONMENT_NAME}/secret-admin.conf >> ./kamatera.log 2>&1
        kamatera_progress
        # uncomment following lines to allow scheduling workloads on the master, not recommended!
        # kamatera_debug "updating master node taints"
        # kamatera_cluster_shell "${K8S_ENVIRONMENT_NAME}" kubectl taint nodes --all node-role.kubernetes.io/master-
        echo "MAIN_SERVER_IP=${IP}" >> environments/${K8S_ENVIRONMENT_NAME}/.env
        kamatera_stop_progress "suuccessfully created master node"
        exit 0
    )
    return $?
}

kamatera_cluster_loadbalancer_reload() {
    K8S_ENVIRONMENT_NAME="${1}"
    [ -z "${K8S_ENVIRONMENT_NAME}" ] && kamatera_error missing K8S_ENVIRONMENT_NAME && return 1
    NODE_LABEL="loadbalancer"
    eval `cat environments/${K8S_ENVIRONMENT_NAME}/${NODE_LABEL}.env`
    export SSHPASS=$(cat "environments/${K8S_ENVIRONMENT_NAME}/secret-${NODE_LABEL}-pass")
    kamatera_start_progress "reloading loadbalancer configuration"
    ./update_yaml.py '{"loadBalancer":{"enabled":true},"nginx":{"enabled":true}}' "environments/${K8S_ENVIRONMENT_NAME}/values.auto-updated.yaml"
    kamatera_debug_file "environments/${K8S_ENVIRONMENT_NAME}/values.auto-updated.yaml"
    NEEDS_SERVICE_IP_UPDATE="yes"
    kamatera_progress
    if NGINX_SERVICE_IP=$(kamatera_cluster_get_nginx_service_ip $K8S_ENVIRONMENT_NAME); then
        YAML_NGINX_IP=$(eval echo `./read_yaml.py environments/abcde/values.auto-updated.yaml loadBalancer nginxServiceClusterIP`)
        kamatera_progress
        if [ "${YAML_NGINX_IP}" == "${NGINX_SERVICE_IP}" ]; then
            NEEDS_SERVICE_IP_UPDATE="no"
        fi
    fi
    kamatera_progress
    if [ "${NEEDS_SERVICE_IP_UPDATE}" == "yes" ]; then
        kamatera_debug "deploying to create / update nginx service"
        while true; do
            kamatera_cluster_deploy "${K8S_ENVIRONMENT_NAME}" --install
            kamatera_progress
            sleep 10
            kamatera_progress
            if NGINX_SERVICE_IP=$(kamatera_cluster_get_nginx_service_ip $K8S_ENVIRONMENT_NAME); then
                kamatera_debug "updating cluster service ip in configuration to ${NGINX_SERVICE_IP}"
                ./update_yaml.py '{"loadBalancer":{"nginxServiceClusterIP":"'$NGINX_SERVICE_IP'"}}' environments/${K8S_ENVIRONMENT_NAME}/values.auto-updated.yaml
                kamatera_debug_file "environments/${K8S_ENVIRONMENT_NAME}/values.auto-updated.yaml"
                break
            fi
            sleep 20
            kamatera_progress
        done
    fi
    kamatera_progress
    kamatera_debug "deploying to apply cluster configuration changes"
    kamatera_progress
    kamatera_cluster_deploy "${K8S_ENVIRONMENT_NAME}"
    kamatera_progress
    kamatera_info "reloading traefik"
    kamatera_progress 5; kamatera_progress 5; kamatera_progress 5
    while ! sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$IP -- "
        docker rm --force traefik;
        ! [ -e /traefik.env ] && touch /traefik.env;
        docker run --name=traefik -d -p 80:80 -p 443:443 -p 3033:3033 \
                                  -v /etc/traefik:/etc-traefik -v /var/traefik-acme:/traefik-acme \
                                  --env-file /traefik.env \
                                  traefik --configFile=/etc-traefik/traefik.toml
    " >> ./kamatera.log 2>&1; do
        sleep 15
        kamatera_progress
    done
    kamatera_debug "verifying traefik container state..."
    while true; do
        sleep 5
        kamatera_progress
        TRAEFIK_JSON=$(sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$IP -- "docker inspect traefik")
        [ $(printf "${TRAEFIK_JSON}" | jq -r '.[0].State.Status' | tee /dev/stderr) == "running" ] && break
    done
    # [ "$?" != "0" ] && kamatera_error "failed to verify installation of existing load balancer node" && exit 1
    # echo Id=$(printf "${TRAEFIK_JSON}" | jq '.[0].Id')
    # printf "${TRAEFIK_JSON}" | jq '.[0].State'
    # ROOT_DOMAIN=`eval echo $(./read_yaml.py environments/${K8S_ENVIRONMENT_NAME}/values.yaml loadBalancer letsEncrypt rootDomain)`
    kamatera_stop_progress "load balancer was installed and updated successfully"
    kamatera_info "Public IP: ${IP}"
    kamatera_info "Dashboard: https://${IP}/dashboard/"
    return 0
}

init_k8s_func() {
    K8S_ENVIRONMENT_NAME="${1}"
    [ -z "${K8S_ENVIRONMENT_NAME}" ] && kamatera_error missing K8S_ENVIRONMENT_NAME && return 1
    echo "${K8S_ENVIRONMENT_NAME}"
    return 0
}

kamatera_cluster_get_nginx_service_ip() {
    ! K8SE="$(init_k8s_func $1)" && return 1
    IP=$(kamatera_cluster_shell_exec "${K8SE}" "
        kubectl get service nginx -o json | jq -r .spec.clusterIP
    " 2>/dev/null)
    [ "${IP}" == "null" ] && echo "" && return 1
    [ -z "${IP}" ] && echo "" && return 1
    echo "${IP}"
    return 0
}

# creates a persistent node that will act as the loadbalancer for the environment
kamatera_cluster_create_loadbalancer_node() {
    # the kamatera environment name to add this node to
    K8S_ENVIRONMENT_NAME="${1}"
    [ -z "${K8S_ENVIRONMENT_NAME}" ] && kamatera_error missing K8S_ENVIRONMENT_NAME && return 1
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
            && kamatera_error "failed to create persistent node for ${NODE_LABEL} node" && exit 1
        eval `cat environments/${K8S_ENVIRONMENT_NAME}/${NODE_LABEL}.env`
        export SSHPASS=$(cat "environments/${K8S_ENVIRONMENT_NAME}/secret-${NODE_LABEL}-pass")
        kamatera_start_progress "setting up ${NODE_LABEL} node..."
        sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$IP -- "mkdir -p /etc/traefik; docker pull traefik" >> ./kamatera.log 2>&1
        kamatera_progress
        kamatera_debug "enabling and deploying load balancer"
        ./update_yaml.py '{"loadBalancer":{"enabled":true}}' "environments/${K8S_ENVIRONMENT_NAME}/values.auto-updated.yaml"
        kamatera_debug_file "environments/${K8S_ENVIRONMENT_NAME}/values.auto-updated.yaml"
        kamatera_cluster_deploy "${K8S_ENVIRONMENT_NAME}" --install
        kamatera_progress
        kamatera_debug "enabling and deploying nginx"
        if ! kamatera_cluster_shell "${K8S_ENVIRONMENT_NAME}" kubectl describe secret nginx-htpasswd; then
            kamatera_debug "creating nginx http auth secrets"
            password=$(python -c "import random; s='abcdefghijklmnopqrstuvwxyz01234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ'; print(''.join(random.sample(s,20)))")
            ! [ -e environments/${K8S_ENVIRONMENT_NAME}/secret-nginx-htpasswd ] &&\
                htpasswd -bc environments/${K8S_ENVIRONMENT_NAME}/secret-nginx-htpasswd superadmin "${password}"
            kamatera_cluster_shell "${K8S_ENVIRONMENT_NAME}" kubectl create secret generic nginx-htpasswd --from-file=environments/${K8S_ENVIRONMENT_NAME}/secret-nginx-htpasswd
            kamatera_progress
            echo
            echo "http auth credentials"
            echo
            echo "username = superadmin"
            echo "password = ${password}"
            echo
            echo "the credentials cannot be retrieved later"
            echo
        fi
        ./update_yaml.py '{"nginx":{"enabled":true,"htpasswdSecretName":"nginx-htpasswd"}}' "environments/${K8S_ENVIRONMENT_NAME}/values.auto-updated.yaml"
        kamatera_debug_file "environments/${K8S_ENVIRONMENT_NAME}/values.auto-updated.yaml"
        kamatera_cluster_deploy "${K8S_ENVIRONMENT_NAME}"
        kamatera_progress
        # if ! [ -z "${ENV_CONFIG}" ]; then
        #     echo "setting traefik environment variables..."
        #     ! sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$IP -- "
        #         for VAR in "'$(echo "'"${ENV_CONFIG}"'")'"; do echo "'"${VAR}"'"; done > /traefik.env;
        #     " && echo "failed to set traefik env vars" && exit 1
        # fi
        ! kamatera_cluster_loadbalancer_reload "${K8S_ENVIRONMENT_NAME}" && kamatera_error "failed to reload loadbalancer configuration" && exit 1
        exit 0
    )
    return $?
}

# exec cluster shell command and print output + return code
kamatera_cluster_shell_exec() {
    K8S_ENVIRONMENT_NAME="${1}"
    [ -z "${K8S_ENVIRONMENT_NAME}" ] && kamatera_error missing K8S_ENVIRONMENT_NAME && return 1
    CMD="${@:2}"
    [ -z "${CMD}" ] && return 1
    bash -c "source switch_environment.sh ${K8S_ENVIRONMENT_NAME} >/dev/null; ${CMD}"
    return $?
}

# connect to the given environment and start a shell session or run commands
kamatera_cluster_shell() {
    K8S_ENVIRONMENT_NAME="${1}"
    [ -z "${K8S_ENVIRONMENT_NAME}" ] && kamatera_error missing K8S_ENVIRONMENT_NAME && return 1
    CMD="${@:2}"
    if [ -z "${CMD}" ]; then
        # start an interactive bash shell
        bash --rcfile <(echo "source switch_environment.sh ${K8S_ENVIRONMENT_NAME} >/dev/null;")
        return $?
    else
        # run the given bash script
        if [ "${KAMATERA_DEBUG}" == "1" ]; then
            bash -c "source switch_environment.sh ${K8S_ENVIRONMENT_NAME} >/dev/null; ${CMD}"
            RES=$?
        else
            bash -c "source switch_environment.sh ${K8S_ENVIRONMENT_NAME} >/dev/null; ${CMD}" >> ./kamatera.log
            RES=$?
        fi
        return $RES
    fi
}

kamatera_cluster_shell_interactive() {
    K8S_ENVIRONMENT_NAME="${1}"
    [ -z "${K8S_ENVIRONMENT_NAME}" ] && kamatera_error missing K8S_ENVIRONMENT_NAME && return 1
    CMD="${@:2}"
    if [ -z "${CMD}" ]; then
        # start an interactive bash shell
        bash --rcfile <(echo "source switch_environment.sh ${K8S_ENVIRONMENT_NAME};")
        return $?
    else
        # run the given bash script
        bash -c "source switch_environment.sh ${K8S_ENVIRONMENT_NAME}; ${CMD}"
        return $?
    fi
}

kamatera_cluster_install_helm() {
    K8S_ENVIRONMENT_NAME="${1}"
    [ -z "${K8S_ENVIRONMENT_NAME}" ] && kamatera_error missing K8S_ENVIRONMENT_NAME && return 1
    kamatera_start_progress "installing helm on ${K8S_ENVIRONMENT_NAME} environment"
    while ! kamatera_cluster_shell "${K8S_ENVIRONMENT_NAME}" "
        kubectl apply -f helm-tiller-rbac-config.yaml &&\
        helm init --service-account tiller --upgrade --force-upgrade --history-max 1
    "; do kamatera_progress; sleep 30; done
    kamatera_progress
    while ! kamatera_cluster_shell "${K8S_ENVIRONMENT_NAME}" "
        kubectl get pods -n kube-system | grep tiller-deploy- | grep ' Running ' &&\
        helm version
    "; do
        sleep 20
        kamatera_progress
    done
    sleep 20
    kamatera_stop_progress OK
    return 0
}

kamatera_cluster_test_storage_operator() {
    kamatera_cluster_shell "${1}" "
        kubectl -n rook-system get pod | grep rook-agent- | grep ' Running ' &&\
        kubectl -n rook-system get pod | grep rook-operator- | grep ' Running '
    "
}

kamatera_cluster_test_storage_cluster() {
    kamatera_cluster_shell "${1}" "
        kubectl -n rook get pod | grep rook-ceph-mon | grep ' Running ' &&\
        kubectl -n rook get pod | grep rook-api | grep ' Running ' &&\
        kubectl -n rook get pod | grep rook-ceph-mgr | grep ' Running ' &&\
        kubectl -n rook get pod | grep rook-ceph-osd | grep ' Running '
    "
}

kamatera_cluster_install_storage() {
    K8S_ENVIRONMENT_NAME="${1}"
    [ -z "${K8S_ENVIRONMENT_NAME}" ] && kamatera_error missing K8S_ENVIRONMENT_NAME && return 1
    kamatera_start_progress "installing storage"
    ! kamatera_cluster_test_storage_operator "${K8S_ENVIRONMENT_NAME}" \
        && ! kamatera_cluster_shell "${K8S_ENVIRONMENT_NAME}" "kubectl create -f rook-operator-0.6.yaml" \
            && kamatera_error failed to install rook operator && return 1
    kamatera_progress
    while ! kamatera_cluster_test_storage_operator "${K8S_ENVIRONMENT_NAME}"; do sleep 10; kamatera_progress; done
    kamatera_progress
    ! kamatera_cluster_test_storage_cluster "${K8S_ENVIRONMENT_NAME}" \
        && ! kamatera_cluster_shell "${K8S_ENVIRONMENT_NAME}" "kubectl create -f rook-cluster-0.6.2.yaml" \
            && kamatera_error failed to install rook operator && return 1
    kamatera_progress
    while ! kamatera_cluster_test_storage_cluster "${K8S_ENVIRONMENT_NAME}"; do sleep 10; kamatera_progress; done
    kamatera_progress
    sleep 10
    kamatera_stop_progress "OK"
    return 0
}

kamatera_create_default_cluster() {
    K8S_ENVIRONMENT_NAME="${1}"
    [ -z "${K8S_ENVIRONMENT_NAME}" ] && kamatera_error missing K8S_ENVIRONMENT_NAME && return 1
    kamatera_debug "creating default cluster for ${K8S_ENVIRONMENT_NAME} environment"
    [ -e "environments/${K8S_ENVIRONMENT_NAME}/.env" ] && kamatera_error "environment already exists" && return 1
    ! mkdir -p "environments/${K8S_ENVIRONMENT_NAME}" && kamatera_error "failed to create environment directory" && return 1
    ! kamatera_cluster_create_master_node "${K8S_ENVIRONMENT_NAME}" "2B" "2048" "30" \
        && kamatera_error "failed to create cluster" && return 1
    if [ "${SKIP_COMPONENTS}" != "yes" ]; then
        ! kamatera_cluster_install_default_components "${K8S_ENVIRONMENT_NAME}" \
            && kamatera_error "failed to install default components" && return 1
    else
        kamatera_info "Skipping cluster components installation, only master node was created"
    fi
    return 0
}

kamatera_cluster_install_default_components() {
    K8S_ENVIRONMENT_NAME="${1}"
    [ -z "${K8S_ENVIRONMENT_NAME}" ] && kamatera_error missing K8S_ENVIRONMENT_NAME && return 1
    kamatera_start_progress "Installing and initializing cluster components on ${K8S_ENVIRONMENT_NAME} environment"

    kamatera_debug creating default worker node
    ! kamatera_cluster_create_worker_node "${K8S_ENVIRONMENT_NAME}" "2B" "2048" "30" "" "node" \
        && kamatera_error failed to create worker node && exit 1
    kamatera_progress

    kamatera_debug installing helm
    ! kamatera_cluster_install_helm "${K8S_ENVIRONMENT_NAME}" \
        && kamatera_error failed to install helm && exit 1
    kamatera_progress

    kamatera_debug installing storage
    ! kamatera_cluster_install_storage "${K8S_ENVIRONMENT_NAME}" \
        && kamatera_error failed to install storage && exit 1
    kamatera_progress

    kamatera_debug deploying root chart
    ! kamatera_cluster_deploy "${K8S_ENVIRONMENT_NAME}" --install \
        && kamatera_error failed to deploy root chart && exit 1
    kamatera_progress

    while ! kamatera_cluster_shell "${K8S_ENVIRONMENT_NAME}" "
        kubectl get pods --all-namespaces | grep ' Running ' | grep kubernetes-dashboard- &&\
        kubectl get pods -n rook | grep rook-ceph-osd | grep ' Running ' &&\
        kubectl get pods -n rook | grep rook-ceph-mgr | grep ' Running ' &&\
        kubectl get pods -n rook | grep rook-ceph-mon | grep ' Running ' &&\
        kubectl get pods -n kube-system | grep canal- | grep ' Running '
    "; do
        kamatera_progress
        sleep 20
    done

    kamatera_debug "Creating load balancer node"
    ! kamatera_cluster_create_loadbalancer_node "${K8S_ENVIRONMENT_NAME}" "2B" "2048" "20" \
        && kamatera_error failed to create loadbalancer node && exit 1
    kamatera_progress

    kamatera_stop_progress Great Success!
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
    [ -z "${K8S_ENVIRONMENT_NAME}" ] && kamatera_error missing K8S_ENVIRONMENT_NAME && return 1
    kamatera_start_progress "deploying root chart to ${K8S_ENVIRONMENT_NAME} environment"
    while ! kamatera_cluster_shell "${K8S_ENVIRONMENT_NAME}" "
        kubectl apply -f helm-tiller-rbac-config.yaml;
        helm init --service-account tiller --upgrade --force-upgrade --history-max 2
    "; do kamatera_progress; sleep 10; done
    while ! kamatera_cluster_shell "${K8S_ENVIRONMENT_NAME}" "
        ./helm_upgrade.sh ${@:2}
    "; do kamatera_progress; sleep 10; done
    kamatera_stop_progress "deployed successfully"
    return 0
}

usage() {
    [ -z "${SHOW_HELP_INDEX}" ] && echo "usage:"
    echo "./kamatera.sh ${1}"
}
