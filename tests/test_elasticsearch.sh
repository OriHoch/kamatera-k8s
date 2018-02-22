#!/usr/bin/env bash

K8SE="${1}"

./kamatera.sh cluster shell "${K8SE}" "
    kubectl delete service/elasticsearch deployment/elasticsearch
"

! ./kamatera.sh cluster shell "${K8SE}" "
    kubectl run elasticsearch --image=docker.elastic.co/elasticsearch/elasticsearch-oss:6.2.1 \
                              --port=9200 --replicas=1 --env=discovery.type=single-node --expose \
                              --requests=cpu=100m,memory=300Mi \
                              --limits=cpu=300m,memory=600Mi \
                              --env=ES_JAVA_OPTS="'"-Xms256m -Xmx256m"'" \
                              --overrides='"'{"spec":{"template":{"spec":{"nodeSelector":{"kamateranode":"true"}}}}}'"'
" && echo "Failed to deploy elasticsearch" && exit 1

sleep 20

! ./kamatera.sh cluster shell "${K8SE}" "
    kubectl rollout status deployment elasticsearch &&\
    POD_NAME="'$'"(kubectl get pods -o json --selector=run==elasticsearch | jq -r '.items[0].metadata.name') &&\
    echo POD_NAME="'$'"POD_NAME &&\
    kubectl logs "'$'"POD_NAME
" && echo "Failed to verify successful elasticsearch deployment" && exit 1

echo elasticsearch deployed successfully
exit 0
