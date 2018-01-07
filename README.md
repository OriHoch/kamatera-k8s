# Kamatera ❤ Kubernetes

Documentation and code to help using Kamatera cloud for running Kubernetes workloads.

## Creating a new single node cluster

* Log-in to [Kamatera Console](https://console.kamatera.com/)
* Sign up and setup billing
* Create a new server with the following configuration:
  * Ubuntu Server 16.04 64bit
  * CPU = master node should have at least 2 cores, depending on workload
  * RAM = at least 2GB
  * SSD Disk = At least 20GB
* Networking = enable both public and private network

SSH to your server with the password you specified during server setup

```
ssh root@your.server.external.ip
```

Following commands should run from the server:

```
swapoff -a
echo "127.0.0.1 `hostname`" >> /etc/hosts
sysctl net.bridge.bridge-nf-call-iptables=1
apt-get update
apt-get install -y docker.io apt-transport-https
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
cat << EOF > /etc/apt/sources.list.d/kubernetes.list
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF
apt-get update
apt-get install -y kubelet kubeadm kubectl
cat << EOF > /etc/docker/daemon.json
{
  "exec-opts": ["native.cgroupdriver=cgroupfs"]
}
EOF
systemctl restart docker
systemctl restart kubelet
kubeadm init --pod-network-cidr=10.244.0.0/16
```

Copy the kubeadm join command from the output

It should look something like this:

```
kubeadm join --token **** your.server.external.ip:6443 --discovery-token-ca-cert-hash sha256:*********
```

Install networking

```
kubectl apply -f https://raw.githubusercontent.com/projectcalico/canal/master/k8s-install/1.7/rbac.yaml
kubectl apply -f https://raw.githubusercontent.com/projectcalico/canal/master/k8s-install/1.7/canal.yaml
```

Wait for kube-dns and all pods to be in `Running` status

```
kubectl get pods --all-namespaces
```

Allow to schedule workloads on the master node

```
kubectl taint nodes --all node-role.kubernetes.io/master-
```

Install the dashboard and give the dashboard the appropriate permissions (don't expose it publically!)

```
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/master/src/deploy/recommended/kubernetes-dashboard.yaml
kubectl create clusterrolebinding dashboard-cluster-admin --clusterrole=cluster-admin --serviceaccount=kube-system:kubernetes-dashboard
```

Exit the server

```
exit
```


## Creating an environment

Each environment should have a directory under `environments` with a `.env` file with the environment configurations.

The environment directory should also contain a secret file to connect to the cluster, you can get it using scp:

```
scp root@your.server.external.ip:/etc/kubernetes/admin.conf environments/ENVIRONMENT_NAME/secret-admin.conf
```

You can now connect to this environment using:

```
source switch_environment.sh testing
```

## Accessing the dashboard via a local proxy

Once you are connected to an environment you can start a proxy to view the dashboard

```
kubectl proxy
```

Dashboard should be available at http://localhost:8001/ui

