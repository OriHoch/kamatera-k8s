#!/usr/bin/env bash

source constants.sh
source kamatera_functions.sh

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
        K8S_ENVIRONMENT_NAME="${3}"
        [ -z "${K8S_ENVIRONMENT_NAME}" ] && usage "cluster create <ENVIRONMENT_NAME>" && exit 1
        ! kamatera_create_default_cluster "${K8S_ENVIRONMENT_NAME}" && kamatera_error failed to create cluster && exit 1
        exit 0

    elif [ "${1} ${2}" == "cluster shell" ]; then
        [ -z "${3}" ] && usage "cluster shell <ENVIRONMENT_NAME>" && exit 1
        ! [ -e "environments/${3}/.env" ] && echo "invalid environment: ${3}" && exit 1
        kamatera_cluster_shell_interactive "${3}" "${@:4}"
        exit $?

    elif [ "${1} ${2}" == "update server_options" ]; then
        kamatera_curl https://console.kamatera.com/service/server > ./kamatera_server_options.json
        echo Updated kamatera_server_options.json
        exit $?

    elif [ "${1} ${2} ${3}" == "cluster node add" ]; then
        ( [ -z "${4}" ] || [ -z "${5}" ] || [ -z "${6}" ] || [ -z "${7}" ] ) \
            && usage "cluster node add <ENVIRONMENT_NAME> <CPU> <RAM> <DISK_SIZE_GB> [SERVER_PATH] [SERVER_PASSWORD]" && exit 1
        ! kamatera_cluster_create_worker_node "${4}" "${5}" "${6}" "${7}" "${8}" "node" "${9}" && kamatera_error "Failed to create worker node" && exit 1
        exit 0

    elif [ "${1} ${2} ${3}" == "cluster loadbalancer reload" ]; then
        K8S_ENVIRONMENT_NAME="${4}"
        [ -z "${K8S_ENVIRONMENT_NAME}" ] && usage "cluster loadbalancer reload <ENVIRONMENT_NAME>" && exit 1
        eval `cat environments/${K8S_ENVIRONMENT_NAME}/loadbalancer.env`
        while true; do
            kamatera_cluster_loadbalancer_reload "${K8S_ENVIRONMENT_NAME}" &&\
            curl -sk https://${IP}/ | grep 'it works!' &&\
            break
            sleep 20
            kamatera_progress
        done
        exit 0

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
        kamatera_info "Public IP: ${IP}"
        kamatera_info "Dashboard: https://${IP}/dashboard/"
        # ! [ -z "${ROOT_DOMAIN}" ] && echo "Root Domain: $(echo ${ROOT_DOMAIN})"
        # ! [ -z "${ROOT_DOMAIN}" ] && echo "Kubernetes Dashboard: https://$(echo ${ROOT_DOMAIN})/dashboard/"

    elif [ "${1} ${2} ${3}" == "cluster loadbalancer ssh" ]; then
        [ -z "${4}" ] && usage "cluster loadbalancer ssh <ENVIRONMENT_NAME>" && exit 1
        ! [ -e "environments/${4}/loadbalancer.env" ] \
            && echo "loadbalancer is not installed" && exit 1
        export SSHPASS=$(cat "environments/${4}/secret-loadbalancer-pass")
        eval `cat environments/${4}/loadbalancer.env`
        sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$IP

    elif [ "${1} ${2} ${3}" == "cluster storage ssh" ]; then
        [ -z "${4}" ] && usage "cluster storage ssh <ENVIRONMENT_NAME>" && exit 1
        ! [ -e "environments/${4}/storage.env" ] \
            && echo "storage is not installed" && exit 1
        export SSHPASS=$(cat "environments/${4}/secret-storage-pass")
        eval `cat environments/${4}/storage.env`
        sshpass -e ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$IP

    elif [ "${1} ${2} ${3}" == "cluster master ssh" ]; then
        [ -z "${4}" ] && usage "cluster master ssh <ENVIRONMENT_NAME>" && exit 1
        ! [ -e "environments/${4}/master.env" ] \
            && echo "master is not installed" && exit 1
        export SSHPASS=$(cat "environments/${4}/secret-master-pass")
        eval `cat environments/${4}/master.env`
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
        ./kamatera.sh cluster loadbalancer info
        ./kamatera.sh cluster loadbalancer ssh
        ./kamatera.sh cluster loadbalancer web-ui
        ./kamatera.sh cluster loadbalancer reload
        ./kamatera.sh cluster node add
        ./kamatera.sh cluster shell
        exit 1

    fi
fi
exit 0
