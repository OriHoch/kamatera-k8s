#!/usr/bin/env bash

test_cluster() {
    TEST_ENVIRONMENT_NAME="${1}"
    [ -z "${TEST_ENVIRONMENT_NAME}" ] && echo "missing ENVIRONMENT_NAME" && return 1
    [ -e environments/${TEST_ENVIRONMENT_NAME} ] && echo "environment already exists" && return 1
    ./kamatera.sh server list | grep "${TEST_ENVIRONMENT_NAME}-" && echo "existing servers with environment name prefix" && return 1

    echo
    echo "Creating environment ${TEST_ENVIRONMENT_NAME}"
    echo

    ! ./kamatera.sh cluster create ${TEST_ENVIRONMENT_NAME} 2B 2048 30 "${MASTER_SERVER_PASSWORD}" \
        && echo "failed to create cluster" && return 1

    while ! ./kamatera.sh cluster shell ${TEST_ENVIRONMENT_NAME} "kubectl get nodes | grep ' Ready '"; do
        echo .
        sleep 5
    done

    echo
    echo "Adding node to the cluster"
    echo

    ! ./kamatera.sh cluster node add ${TEST_ENVIRONMENT_NAME} 2B 2048 30 "" "" "${NODE_SERVER_PASSWORD}" \
        && echo "failed to add node" && return 1

    echo "waiting for node to be added to the cluster"
    while ! [ $(./kamatera.sh cluster shell ${TEST_ENVIRONMENT_NAME} "kubectl get nodes | tee /dev/stderr | grep ' Ready ' | wc -l") == "2" ]; do
        echo .
        sleep 60
    done

    echo "schedule a simple testing pod on the cluster"
    ! ./kamatera.sh cluster shell ${TEST_ENVIRONMENT_NAME} 'kubectl run test --image=alpine -- sh -c "while true; do echo .; sleep 1; done"' && return 1

    echo "waiting for pod"
    while ! [ $(./kamatera.sh cluster shell ${TEST_ENVIRONMENT_NAME} kubectl get pods | tee /dev/stderr | grep test- | grep ' Running ' | wc -l) == "1" ]; do
        echo .
        sleep 5
    done

    POD_NAME=$(./kamatera.sh cluster shell ${TEST_ENVIRONMENT_NAME} kubectl get pods | grep test- | grep ' Running ' | cut -d" " -f1)
    echo "POD_NAME=$POD_NAME"
    sleep 2
    ! [ $(./kamatera.sh cluster shell ${TEST_ENVIRONMENT_NAME} kubectl logs --tail=1 $POD_NAME) == "." ] && echo "pod is not running or has an error" && return 1

    echo "installing the load balancer"

    echo "loadBalancer:
  redirectToHttps: true
  enableHttps: true
  letsEncrypt:
    acmeEmail: ${DO_EMAIL}
    dnsProvider: digitalocean
    rootDomain: ${DO_DOMAIN}
" > environments/${TEST_ENVIRONMENT_NAME}/values.yaml

    ! ./kamatera.sh cluster lb install ${TEST_ENVIRONMENT_NAME} "DO_AUTH_TOKEN=${DO_AUTH_TOKEN}" "${LB_SERVER_PASSWORD}" \
        && echo "failed to install the load balancer" && return 1

    eval `cat environments/${TEST_ENVIRONMENT_NAME}/loadbalancer.env`

    echo "updating DNS..."
    curl -X PUT -H "Content-Type: application/json" -H "Authorization: Bearer ${DO_AUTH_TOKEN}" \
         -d '{"data":"'${IP}'"}' "https://api.digitalocean.com/v2/domains/${DO_DOMAIN_ROOT}/records/${DO_DOMAIN_RECORD_ID}"
    sleep 10

    echo "waiting for external access to the cluster..."
    sleep 60
    ! curl -v "https://${DO_DOMAIN}/" && return 1

    echo
    echo "Great Success!"
    echo
    return 0
}

terminate_cluster() {
    TEST_ENVIRONMENT_NAME="${1}"
    [ -z "${TEST_ENVIRONMENT_NAME}" ] && echo "missing ENVIRONMENT_NAME" && return 1
    echo "Terminating environment ${TEST_ENVIRONMENT_NAME}"
    MASTER=`./kamatera.sh server list | grep ${TEST_ENVIRONMENT_NAME}-master`
    NODE=`./kamatera.sh server list | grep ${TEST_ENVIRONMENT_NAME}-node`
    LB=`./kamatera.sh server list | grep ${TEST_ENVIRONMENT_NAME}-lb`
    [ "${MASTER}" != "" ] && ./kamatera.sh server terminate $(echo $MASTER | cut -d" " -f2 -) $(echo $MASTER | cut -d" " -f1 -) yes
    [ "${NODE}" != "" ] && ./kamatera.sh server terminate $(echo $NODE | cut -d" " -f2 -) $(echo $NODE | cut -d" " -f1 -) yes
    [ "${LB}" != "" ] && ./kamatera.sh server terminate $(echo $LB | cut -d" " -f2 -) $(echo $LB | cut -d" " -f1 -) yes
    rm -rf environments/${TEST_ENVIRONMENT_NAME}
    return 0
}

# set env vars on travis using:
# travis env set --private VAR_NAME VALUE
if
    ! [ -z "${DO_EMAIL}" ] &&\
    ! [ -z "${DO_DOMAIN}" ] &&\
    ! [ -z "${DO_AUTH_TOKEN}" ] &&\
    ! [ -z "${DO_DOMAIN_ROOT}" ] &&\
    ! [ -z "${DO_DOMAIN_RECORD_ID}" ] &&\
    ! [ -z "${MASTER_SERVER_PASSWORD}" ] &&\
    ! [ -z "${NODE_SERVER_PASSWORD}" ] &&\
    ! [ -z "${LB_SERVER_PASSWORD}" ];
then
    echo "environment verified"
else
    echo "missing reuqired env vars"
    exit 1
fi

RES=0
( [ "${1}" == "--terminate-first" ] || [ "${1}" == "--terminate-only" ] ) && terminate_cluster "kamateratest1"
if [ "${1}" != "--terminate-only" ]; then
    test_cluster "kamateratest1"
    RES=$?; echo "RES=$RES"
    [ "${1}" != "--terminate-first" ] && terminate_cluster "kamateratest1"
fi
exit $RES
