#!/usr/bin/env bash

[ -e environments/kamateratest1 ] && exit 1

echo
echo "Creating cluster..."
echo

! ./kamatera.sh cluster create kamateratest1 2B 2048 30 \
    && echo "failed to create cluster" && exit 1

while ! ./kamatera.sh cluster shell kamateratest1 "kubectl get nodes | grep ' Ready '"; do
    echo .
    sleep 5
done

echo
echo "Adding node to the cluster"
echo

! ./kamatera.sh cluster node add kamateratest1 2B 2048 30 \
    && echo "failed to add node" && exit 1

echo "waiting for node to be added to the cluster"
while ! [ $(./kamatera.sh cluster shell kamateratest1 "kubectl get nodes | tee /dev/stderr | grep ' Ready ' | wc -l") == "2" ]; do
    echo .
    sleep 60
done

echo "schedule a simple testing pod on the cluster"
! kubectl run test --image=alpine -- sh -c "while true; do echo .; sleep 1; done" && exit 1

echo "waiting for pod"
while ! [ $(kubectl get pods | tee /dev/stderr | grep test- | grep ' Running ' | wc -l) == "1" ]; do
    echo .
    sleep 5
done

POD_NAME=$(kubectl get pods | grep test- | grep ' Running ' | cut -d" " -f1)
echo "POD_NAME=$POD_NAME"
sleep 2
! [ $(kubectl logs --tail=1 $POD_NAME) == "." ] && echo "pod is not running or has an error" && exit 1

echo
echo "Great Success!"
echo
exit 0
