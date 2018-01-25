# Kamatera ❤ Kubernetes

Documentation and code to help using Kamatera cloud for running Kubernetes workloads.

[![Build Status](https://travis-ci.org/OriHoch/kamatera-k8s.svg?branch=master)](https://travis-ci.org/OriHoch/kamatera-k8s)


## Prerequisites

* An existing project you want to deploy to the Kamatera Kubernetes Cloud
* Kamatera API clientId and secret token


## Running the Kamatera CLI

All kamatera CLI commands should run from a project directory.

The CLI reads and stores configuration to the current working directory.

Install some basic dependencies, following might work for Debian based systems:

```
sudo apt-get update
sudo apt-get install curl gcc python-dev python-setuptools apt-transport-https apache2-utils \
                     lsb-release openssh-client git bash jq sshpass openssh-client
sudo easy_install -U pip
sudo pip install -U crcmod python-dotenv pyyaml
```

Install Kubectl, see [Kubectl Installation Docs](https://kubernetes.io/docs/tasks/tools/install-kubectl)

Following might work on Debian based systems:

```
curl -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl
chmod +x ./kubectl
sudo mv ./kubectl /usr/local/bin/kubectl
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

Deploy the root helm chart and ensure the core required components are deployed

```
./kamatera.sh cluster deploy <ENVIRONMENT_NAME> [HELM_UPGRADE_ARGS]..
```

Deploy an independent sub-chart (requires the root chart to be deployed successfully first)

```
./kamatera.sh cluster shell <ENVIRONMENT_NAME> ./helm_upgrade_external_chart.sh <CHART_NAME> [HELM_UPGRADE_ARGS]..
```

All the helm charts and kubernetes templates are in the current working directory under `charts-external`, `charts` and `templates` directories.

The helm values are in `values.yaml` files.

Depending on the changes you might need to add arguments to helm upgrade

* On first installation you should add `--install`
* To force deployment at cost of down-time: `--force --recreate-pods`
* For debugging: `--debug --dry-run`

refer to the [Helm documentation](https://helm.sh/) for details.


## Installing a load balancer to allow secure external access to the cluster

Add the load balancer configuration to `environments/ENVIRONMNET_NAME/values.yaml`

You can see where the values are used in `templates/loadbalancer.yaml` and `templates/loadbalancer-conf.yaml`

```
loadBalancer:
  redirectToHttps: true
  enableHttps: true
  letsEncrypt:
    acmeEmail: your.email@some.domain.com
    dnsProvider: cloudflare
    rootDomain: your.domain.com
```

Install the dedicated load balancer node, provide any required environment variables (optional)

```
./kamatera.sh cluster lb install <ENVIRONMENT_NAME> [OPTIONAL_ENVIRONMENT_VARS]
```

For example, if using the cloudflare provider:

```
./kamatera.sh cluster lb install <ENVIRONMENT_NAME> "CLOUDFLARE_EMAIL=<EMAIL> CLOUDFLARE_API_KEY=<API_KEY>"
```

Check [this list](https://docs.traefik.io/configuration/acme/#provider) for the possible dns providers and required environment variables.

Get the load balancer public IP to set DNS:

```
./kamatera.sh cluster lb info <ENVIRONMENT_NAME>
```

If you made any changes to the load balancer configuration you should update by re-running the install command without any additional arguments:

```
./kamatera.sh cluster lb install <ENVIRONMENT_NAME>
```

Traefik Web UI is not exposed publically by default, you can access it via a proxy

```
./kamatera.sh cluster lb web-ui <ENVIRONMENT_NAME>
```

Web UI is available at http://localhost:3033/
