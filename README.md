# Kamatera ❤ Kubernetes

Documentation and code to help using Kamatera cloud for running Kubernetes workloads.

[![Build Status](https://travis-ci.org/OriHoch/kamatera-k8s.svg?branch=master)](https://travis-ci.org/OriHoch/kamatera-k8s)


## Prerequisites

* Recent version of [Docker](https://docs.docker.com/engine/installation/)
* An existing project you want to deploy to the Kamatera Kubernetes Cloud
* Kamatera API clientId and secret token


## Running the Kamatera CLI

All kamatera CLI commands should run from a project directory.

The CLI reads and stores configuration to the current working directory.

Install some required dependencies, following might work for Debian based systems:

```
sudo apt-get update
sudo apt-get install curl gcc python-dev python-setuptools apt-transport-https
                     lsb-release openssh-client git bash jq sshpass openssh-client
sudo easy_install -U pip
sudo pip install -U crcmod python-dotenv pyyaml
```


## Create a new cluster

Login to Kamatera (will ask for your clientId and secret)

```
./kamatera.sh auth login
```

Create a cluster

```
./kamatera.sh cluster create <ENVIRONMENT_NAME> <CPU> <RAM> <DISK_SIZE>
```

* **ENVIRONMENT_NAME** - a unique name to identify your cluster, e.g. `testing` / `production`
* **CPU** - should be at least `2B` = 2 cores
* **RAM** - should be at least `2048` = 2GB
* **DISK_SIZE** - in GB

See `kamatera_server_options.json` for the list of available CPU / RAM / DISK_SIZE options.

When the cluster is created you should have the cluster configuration available under `environments/ENVIRONMENT_NAME/`


## Run a local shell session connected to the cluster

```
./kamatera.sh cluster shell <ENVIRONMENT_NAME>
```

You can also run a one-off command, for example, to get the list of nodes from kubectl:

```
./kamatera.sh cluster shell <ENVIRONMENT_NAME> kubectl get nodes
```

You should see a single node, the node name matches the kamatera server name.


## Add a node to the cluster

```
./kamatera.sh cluster node add <ENVIRONMENT_NAME> <CPU> <RAM> <DISK_SIZE>
```

* **ENVIRONMENT_NAME** - name of an existing environment (which has all required files under `environments/ENVIRONMENT_NAME/`)
* **CPU**, **RAM**, **DISK_SIZE** - same as cluster create, you can add nodes with different settings

Get the list of nodes, it might take a minute for the node to be in Ready state

```
./kamatera.sh cluster shell <ENVIRONMENT_NAME> kubectl get nodes
```


## Creating a new environment

Assuming you have an existing cluster you can use and you have the `secret-admin.conf` file for authentication to that cluster.

You can copy another environment (under the `environments` directory) and modify the values, specifically, the `.env` file has the connection details and the `secret-admin.conf` file has the authentication secrets.


## Using an existing environment

Assuming there is an existing cluster and corresponding environment configuration files and secrets in the current project under `environments/ENVIRONMENT_NAME` directory.

Start a shell session:

```
./kamatera.sh cluster shell <ENVIRONMENT_NAME>
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

Make sure helm and tiller are installed:

```
./kamatera.sh cluster shell <ENVIRONMENT_NAME> "
    kubectl apply -f helm-tiller-rbac-config.yaml &&
    helm init --service-account tiller --upgrade
"
```

Deploy

```
./kamatera.sh cluster shell <ENVIRONMENT_NAME> "
    ./helm_upgrade.sh
"
```

Depending on the changes you might need to add arguments to helm upgrade, refer to the Helm documentation for details.

* On first installation you should add `--install`
* To force deployment at cost of down-time: `--force --recreate-pods`


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
