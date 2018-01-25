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

    elif [ "${1} ${2}" == "server list" ]; then
        if [ "${3}" == "--raw" ]; then
            kamatera_curl "https://console.kamatera.com/service/servers"
        else
            ./kamatera.sh server list --raw | jq -r 'map([.power,.name,.id]|join(" "))|join("\n")' | grep '^on ' | cut -d" " -f2- -
        fi

    elif [ "${1} ${2}" == "server ip" ]; then
        SERVER_ID="${3}"
        [ -z "${SERVER_ID}" ] && echo "usage:" && echo "./kamatera.sh server ip <SERVER_ID>" && exit 1
        ./kamatera.sh server describe "${SERVER_ID}" | jq -r '.networks[0].ips[0]'

    elif [ "${1} ${2}" == "server terminate" ]; then
        SERVER_ID="${3}"
        SERVER_NAME="${4}"
        APPROVE="${5}"
        ! [ "${SERVER_NAME}" == "`./kamatera.sh server list | grep "${SERVER_ID}" | cut -d" " -f1 -`" ] && exit 1
        [ "${APPROVE}" != "yes" ] && exit 1
        echo "Terminating server"
        kamatera_curl -X DELETE -d "confirm=1&force=1" "https://console.kamatera.com/service/server/${SERVER_ID}/terminate"

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
        K8S_ENVIRONMENT_NAME="${4}"; CPU="${5}"; RAM="${6}"; DISK_SIZE_GB="${7}"; NODE_PREFIX="${8}"; SERVER_PATH="${9}"
        ([ -z "${K8S_ENVIRONMENT_NAME}" ] || [ -z "${CPU}" ] || [ -z "${RAM}" ] || [ -z "${DISK_SIZE_GB}" ]) \
            && echo "usage:" && echo "./kamatera.sh cluster node add <K8S_ENVIRONMENT_NAME> <CPU> <RAM> <DISK_SIZE_GB>" && exit 1
        [ -z "${SERVER_PATH}" ] && SERVER_PATH=$(mktemp -d)
        ! kamatera_cluster_node_create "${CPU}" "${RAM}" "${DISK_SIZE_GB}" "${SERVER_PATH}" "${K8S_ENVIRONMENT_NAME}-${NODE_PREFIX:-node}" && exit 1
        SERVER_IP=$(cat ${SERVER_PATH}/ip)
        export SSHPASS=$(cat ${SERVER_PATH}/password)
        [ -z "${9}" ] && rm -rf "${SERVER_PATH}"
        echo "joining the cluster using kubeadm"
        if ! sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$SERVER_IP -- "
            $(cat environments/${K8S_ENVIRONMENT_NAME}/secret-kubeadm-init.log | grep 'kubeadm join --token')
        "; then
            echo "Failed to initialize kubeadm"
            exit 1
        fi

    elif [ "${1} ${2} ${3}" == "cluster lb install" ]; then
        K8S_ENVIRONMENT_NAME="${4}"
        ENV_CONFIG="${5}"
        [ -z "${K8S_ENVIRONMENT_NAME}" ] && echo "missing K8S_ENVIRONMENT_NAME" && exit 1
        if ! [ -e "environments/${K8S_ENVIRONMENT_NAME}/loadbalancer.env" ]; then
            echo "adding load balancer node"
            SERVER_PATH=$(mktemp -d)
            ! ./kamatera.sh cluster node add "${K8S_ENVIRONMENT_NAME}" 1B 1024 5 "lb" "${SERVER_PATH}" && echo "failed to add lb node" && exit 1
            while ! ./kamatera.sh cluster shell "${K8S_ENVIRONMENT_NAME}" "kubectl get nodes | tee /dev/stderr | grep ' Ready ' | grep ${K8S_ENVIRONMENT_NAME}lb"; do
                echo .
                sleep 5
            done
            NODE_ID=$(./kamatera.sh server list | grep "${K8S_ENVIRONMENT_NAME}-lb-" | cut -d" " -f1 - | cut -d"-" -f3 -)
            [ -z "${NODE_ID}" ] && echo "failed to get lb server node id" && exit 1
            echo "NODE_ID=${NODE_ID}" > "environments/${K8S_ENVIRONMENT_NAME}/loadbalancer.env"
            echo "IP="$(cat ${SERVER_PATH}/ip) >> "environments/${K8S_ENVIRONMENT_NAME}/loadbalancer.env"
            export SSHPASS=$(cat ${SERVER_PATH}/password)
            echo "${SSHPASS}" > "environments/${K8S_ENVIRONMENT_NAME}/secret-loadbalancer-pass"
            cp "${SERVER_PATH}/params" "environments/${K8S_ENVIRONMENT_NAME}/secret-loadbalancer-params"
            rm -rf "${SERVER_PATH}"
            echo "setting kubernetes node label to identify as load balancer"
            kubectl label node "${K8S_ENVIRONMENT_NAME}lb${NODE_ID}" kamateralb=true
            eval `cat environments/${K8S_ENVIRONMENT_NAME}/loadbalancer.env`
            sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$IP -- "mkdir -p /etc/traefik"
            sshpass -e scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ./traefik.toml root@$IP:/etc/traefik/traefik.toml
            if ! sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$IP -- "
                docker run --name=traefik -d -p 80:80 -p 443:443 -p 3033:3033 \
                                          -v /etc/traefik:/etc-traefik -v /var/traefik-acme:/traefik-acme \
                                          traefik --configFile=/etc-traefik/traefik.toml
            "; then
                echo "Failed to install load balancer"
                exit 1
            fi
            while ! [ $(sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$IP -- "docker inspect traefik" | jq -r '.[0].State.Status') == "running" ]; do
                echo .
                sleep 2
            done
            ./update_yaml.py '{"global":{"enableRootChart":true},"loadBalancer":{"enabled":true,"nodeName":"'"${K8S_ENVIRONMENT_NAME}lb${NODE_ID}"'"},"nginx":{"enabled":true}}' "environments/${K8S_ENVIRONMENT_NAME}/values.auto-updated.yaml"
            ! ./kamatera.sh cluster deploy "${K8S_ENVIRONMENT_NAME}" --install \
                && echo "failed to deploy root chart" && exit 1
            sleep 5
        else
            echo "using existing load balancer node"
            echo "to re-create, delete environments/${K8S_ENVIRONMENT_NAME}/loadbalancer.env and the corresponding node"
            eval `cat environments/${K8S_ENVIRONMENT_NAME}/loadbalancer.env`
            export SSHPASS=$(cat "environments/${K8S_ENVIRONMENT_NAME}/secret-loadbalancer-pass")
        fi
        while ! ./kamatera.sh cluster shell "${K8S_ENVIRONMENT_NAME}" kubectl get service | tee /dev/stderr | grep 'nginx ' >/dev/null; do
            echo .
            sleep 2
        done
        if ! ./kamatera.sh cluster shell "${K8S_ENVIRONMENT_NAME}" kubectl describe secret nginx-htpasswd; then
            echo "create auth secrets..."
            password=$(python -c "import random; s='abcdefghijklmnopqrstuvwxyz01234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ'; print(''.join(random.sample(s,20)))")
            ! [ -e environments/${K8S_ENVIRONMENT_NAME}/secret-nginx-htpasswd ] &&\
                htpasswd -bc environments/${K8S_ENVIRONMENT_NAME}/secret-nginx-htpasswd superadmin "${password}"
            kubectl create secret generic nginx-htpasswd --from-file=environments/${K8S_ENVIRONMENT_NAME}/secret-nginx-htpasswd
            echo
            echo "http auth credentials"
            echo
            echo "username = superadmin"
            echo "password = ${password}"
            echo
            echo "the credentials cannot be retrieved later"
            echo
        fi
        NGINX_SERVICE_IP=$(echo $(kubectl describe service nginx | grep 'IP:' | cut -d" " -f2-))
        echo "updating internal nginx cluster ip: ${NGINX_SERVICE_IP}"
        ./update_yaml.py '{"loadBalancer":{"nginxServiceClusterIP":"'${NGINX_SERVICE_IP}'"},"nginx":{"htpasswdSecretName":"nginx-htpasswd"}}' "environments/${K8S_ENVIRONMENT_NAME}/values.auto-updated.yaml"
        echo "deploying root chart..."
        ! ./kamatera.sh cluster deploy "${K8S_ENVIRONMENT_NAME}" >/dev/null 2>&1 && echo "failed to deploy root chart" && exit 1
        if ! [ -z "${ENV_CONFIG}" ]; then
            echo "setting traefik environment variables..."
            ! sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$IP -- "
                for VAR in "'$(echo "'"${ENV_CONFIG}"'")'"; do echo "'"${VAR}"'"; done > /traefik.env;
            " && echo "failed to set traefik env vars" && exit 1
        fi
        echo "reloading traefik..."
        sleep 5
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
        ./kamatera.sh cluster lb info "${K8S_ENVIRONMENT_NAME}"
        TRAEFIK_JSON=$(sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$IP -- "docker inspect traefik") &&\
        [ $(printf "${TRAEFIK_JSON}" | jq -r '.[0].State.Status' | tee /dev/stderr) == "running" ]
        [ "$?" != "0" ] && echo "failed to verify installation of existing load balancer node" && exit 1
        echo Id=$(printf "${TRAEFIK_JSON}" | jq '.[0].Id')
        printf "${TRAEFIK_JSON}" | jq '.[0].State'
        ROOT_DOMAIN=$(./read_yaml.py environments/${K8S_ENVIRONMENT_NAME}/values.yaml loadBalancer letsEncrypt rootDomain)
        echo "load balancer was installed and updated successfully"
        echo "Public IP: ${IP}"
        ! [ -z "${ROOT_DOMAIN}" ] && echo "Root Domain: ${ROOT_DOMAIN}"
        ! [ -z "${ROOT_DOMAIN}" ] && echo "Kubernetes Dashboard: https://${ROOT_DOMAIN}/dashboard/"

    elif [ "${1} ${2} ${3}" == "cluster lb web-ui" ]; then
        K8S_ENVIRONMENT_NAME="${4}"
        [ -z "${K8S_ENVIRONMENT_NAME}" ] && echo "missing K8S_ENVIRONMENT_NAME" && exit 1
        export SSHPASS=$(cat "environments/${K8S_ENVIRONMENT_NAME}/secret-loadbalancer-pass")
        eval `cat environments/${K8S_ENVIRONMENT_NAME}/loadbalancer.env`
        echo "Load Balancer Public IP: ${IP}"
        echo "you can access the traefik web-ui at http://localhost:3033"
        echo "quit by pressing Ctrl+C"
        sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$IP -L "3033:localhost:3033" -nN

    elif [ "${1} ${2} ${3}" == "cluster lb info" ]; then
        K8S_ENVIRONMENT_NAME="${4}"
        [ -z "${K8S_ENVIRONMENT_NAME}" ] && echo "missing K8S_ENVIRONMENT_NAME" && exit 1
        export SSHPASS=$(cat "environments/${K8S_ENVIRONMENT_NAME}/secret-loadbalancer-pass")
        eval `cat environments/${K8S_ENVIRONMENT_NAME}/loadbalancer.env`
        sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$IP docker logs traefik
        echo "Load Balancer Public IP: ${IP}"

    elif [ "${1} ${2}" == "cluster deploy" ]; then
        K8S_ENVIRONMENT_NAME="${3}"
        [ -z "${K8S_ENVIRONMENT_NAME}" ] && echo "missing K8S_ENVIRONMENT_NAME" && exit 1
        ./kamatera.sh cluster shell "${K8S_ENVIRONMENT_NAME}" "
            kubectl apply -f helm-tiller-rbac-config.yaml &&
            helm init --service-account tiller --upgrade
        " &&\
        while ! [ $(./kamatera.sh cluster shell "${K8S_ENVIRONMENT_NAME}" kubectl get pods --namespace=kube-system | grep tiller-deploy- | grep ' Running ' | wc -l) == "1" ]; do echo .; sleep 1; done &&\
        ./helm_upgrade.sh "${@:4}"
        exit $?

    else
        echo "unknown command"
        exit 1
    fi
fi
exit 0
