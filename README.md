# Kamatera ❤ Kubernetes

Documentation and code to help using Kamatera cloud for running Kubernetes workloads.


## Connecting to an existing environment

Assuming there is an existing cluster and corresponding environment under `environments` directory:

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


## Deployment

Make sure helm and tiller are installed and latest version (locally and on the cluster):

```
kubectl apply -f helm-tiller-rbac-config.yaml
helm init --service-account tiller --upgrade
```

Deploy

```
./helm_upgrade.sh
```

Depending on the changes you might need to add arguments to helm upgrade, refer to the Helm documentation for details.

* On first installation you should add `--install`
* To force deployment at cost of down-time: `--force --recreate-pods`


## Create a Kubernetes master node

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

Create the master node:

```
kubeadm init --pod-network-cidr=10.244.0.0/16
```

Keep the kubeadm join command from the output, you can need it to join nodes to the cluster.

Install networking on the master node (should be done once per cluster):

```
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl apply -f https://raw.githubusercontent.com/projectcalico/canal/master/k8s-install/1.7/rbac.yaml
kubectl apply -f https://raw.githubusercontent.com/projectcalico/canal/master/k8s-install/1.7/canal.yaml
```

When creating the cluster for the first time it might take a few minutes for everything to start, you just need to wait

```
while ! kubectl get pods --all-namespaces | tee /dev/stderr | grep kube-dns- | grep Running; do echo "."; sleep 1; done
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


## Creating a new environment

Assuming you have an existing cluster you can use and you have the `secret-admin.conf` file for authentication to that cluster.

You can copy another environment (under the `environments` directory) and modify the values, specifically, the `.env` file has the connection details and the `secret-admin.conf` file has the authentication secrets.


## Join a cluster

To add a node to the cluster - follow the steps in creating a new master node, but instead of `kubeadm init`, run the `kubeadm join` command you kept from the output of the init command.


## Installing the load balancer to allow secure external access to the cluster

We use traefik to provide load balancing into the cluster from outisde of the internal network.

First, you should deploy the helm release which contains the traefik daemonset which allows to configure the traefik via helm values.

Assuming the helm release is deployed, you need to just start the traefik docker container on each cluster node you wish to route external traffic to:

```
ssh root@cluster-node-ip docker run --name=traefik -d -p 80:80 -p 443:443 \
                                    -v /etc/traefik:/etc-traefik -v /var/traefik-acme:/traefik-acme \
                                    traefik --configFile=/etc-traefik/traefik.toml
```

If let's encrypt fails refer to the [traefik documentation](https://docs.traefik.io/configuration/acme/).

If you want to run traefik for the same domain on more then one node, you should share the /var/traefik-acme directory between the nodes (e.g. via NFS shared folder)

That's it, you can now set DNS to point to the node's IP

You can create the following script to restart traefik in case of configuration changes:

```
echo "docker rm --force traefik; YOUR_TRAEFIK_DOCKER_RUN_COMMAND" > start_traefik.sh
chmod +x start_traefik.sh
```

The load balancer is configured via `templates/traefik-conf.yaml` file, you can edit that file and then deploy the helm release.

This makes sure that /etc/traefik/traefik.toml file is available on the host for the load balancer to use.

After you make changes run the start_traefik.sh script on the node

```
./start_traefik.sh
```
