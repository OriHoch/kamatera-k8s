# Kamatera ❤ Kubernetes

Documentation and code to help using Kamatera cloud for running Kubernetes workloads.


## Connecting to an existing environment

Assuming there is a corresponding environment under `environments` directory:

```
source switch_environment.sh testing
```

Verify you are connected to the cluster:

```
kubectl get nodes
```

You should have tab completion:

```
kubectl describe node <TAB><TAB>
```


## Upgrading the release

```
./helm_upgrade.sh
```

Depending on the changes you might need to add arguments to helm upgrade, refer to the Helm documentation for details

This command will ensure changes are deployed at the cost of some down-time:

```
./helm_upgrade.sh --force --recreate-pods
```


## Installing the Helm release

Install helm and tiller:

```
kubectl apply -f helm-tiller-rbac-config.yaml
helm init --service-account tiller
```

Install the release

```
./helm_upgrade.sh --install
```


## Installing the load balancer to allow secure external access to the cluster

We use traefik to provide load balancing into the cluster, to simplify the setup, Traefik is installed locally, outside of Kubernetes.

SSH into a cluster node and start the traefik container

```
ssh root@cluster-node-ip
mkdir -p /etc/traefik
nano /etc/traefik/traefik.toml
```

Paste `traefik.toml` from this directory

Start the traefik docker container on the relevant cluster node

```
docker run --name=traefik -d -p 80:80 -p 443:443 \
           -v /etc/traefik:/etc-traefik -v /var/traefik-acme:/traefik-acme \
           traefik --configFile=/etc-traefik/traefik.toml
```

Set DNS to point to the node's IP


## Creating a new environment

Copy an existing environment, modify the `.env` file.

The environment should have an `secret-admin.conf` file (not committed to Git) which is used to access the cluster.


## Create a Kubernetes node / join / create a cluster

This procedure creates a node that and sets it up to serve as master or node or both

* Log-in to [Kamatera Console](https://console.kamatera.com/)
* Sign up and setup billing
* Create a new server with the following configuration:
  * Ubuntu Server 16.04 64bit
  * CPU = master node should have at least 2 cores, depending on workload
  * RAM = master node should have at least 4GB
  * SSD Disk = master node should have at least 50GB

SSH to your server with the password you specified during server setup

```
ssh root@your.server.external.ip
```

Following commands should run from the server to setup kube-adm which is then used to setup and manage the cluster:

```
swapoff -a
echo "127.0.0.1 `hostname`" >> /etc/hosts
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
sysctl net.bridge.bridge-nf-call-iptables=1
systemctl restart docker
systemctl restart kubelet
```

Now you can run the kubeadm join command to join an existing cluster.

To create a new master node:

```
kubeadm init --pod-network-cidr=10.244.0.0/16
```

Keep the kubeadm join command from the output, it should look something like this, you can run this from other nodes to add them to the cluster:

```
kubeadm join --token **** your.server.external.ip:6443 --discovery-token-ca-cert-hash sha256:*********
```

Install networking:

```
kubectl apply -f https://raw.githubusercontent.com/projectcalico/canal/master/k8s-install/1.7/rbac.yaml
kubectl apply -f https://raw.githubusercontent.com/projectcalico/canal/master/k8s-install/1.7/canal.yaml
```

Wait for kube-dns and all pods to be in `Running` status:

```
kubectl get pods --all-namespaces
```

(Optional) Allow to schedule workloads on the master node

```
kubectl taint nodes --all node-role.kubernetes.io/master-
```

Exit the server

```
exit
```

Copy the admin.conf file and keep it under the corresponding environment directory -

```
scp root@your.server.external.ip:/etc/kubernetes/admin.conf environments/ENVIRONMENT_NAME/secret-admin.conf
```


## Add monitoring using heapster

from local PC, with connected `kubectl`:

```
git clone git@github.com:kubernetes/heapster.git
cd heapster

```