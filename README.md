# Kamatera ❤ Kubernetes

Documentation and code to help using Kamatera cloud for running Kubernetes workloads.

[![Build Status](https://travis-ci.org/OriHoch/kamatera-k8s.svg?branch=master)](https://travis-ci.org/OriHoch/kamatera-k8s)


## Installation

Install the dependencies, following should work for Debian based systems:

```
sudo apt-get update
sudo apt-get install curl gcc python-dev python-setuptools apt-transport-https apache2-utils \
                     lsb-release openssh-client git bash jq sshpass openssh-client bash-completion
sudo easy_install -U pip
sudo pip install -U crcmod python-dotenv pyyaml
curl -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl
chmod +x ./kubectl
sudo mv ./kubectl /usr/local/bin/kubectl
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get > get_helm.sh
chmod 700 get_helm.sh
./get_helm.sh
```

Clone the `kamatera-k8s` repository

```
git clone https://github.com/OriHoch/kamatera-k8s.git
```

Following commands should run from the kamatera-k8s directory

```
cd kamatera-k8s
```

Login with your Kamatera clientId and secret

```
./kamatera.sh auth login
```


## Create a new cluster

Create the master node and initialize the cluster

```
./kamatera.sh cluster create <ENVIRONMENT_NAME>
```

* **ENVIRONMENT_NAME** - a unique name to identify your cluster, e.g. `testing` / `production`

When the cluster is created you should have the cluster configuration available under `environments/ENVIRONMENT_NAME/`

Add a persistent storage node with the given disk size in GB

```
./kamatera.sh cluster storage install <ENVIRONMENT_NAME> <DISK_SIZE_GB>
```

Add a load balancer node

```
./kamatera.sh cluster loadbalancer install <ENVIRONMENT_NAME>
```

Add at least 1 worker node

```
./kamatera.sh cluster node add <ENVIRONMENT_NAME> <CPU> <RAM> <DISK_SIZE>
```

* **CPU** - should be at least `2B` = 2 cores
* **RAM** - should be at least `2048` = 2GB
* **DISK_SIZE** - in GB

See `kamatera_server_options.json` for the list of available CPU / RAM / DISK_SIZE options.


## Accessing the Kubernetes Dashboard

```
./kamatera.sh cluster web-ui <ENVIRONMENT_NAME>
```

Kubernets Dashboard is available at http://localhost:9090/


## Deployment

The core infrastructure components are defined in `templates` directory as helm / kubernetes charts.

To deploy the root helm chart and ensure the core required components are deployed use the `cluster deploy` command:

```
./kamatera.sh cluster deploy <ENVIRONMENT_NAME> [HELM_UPGRADE_ARGS]..
```

Sub-charts are defined independently and can be deployed using `helm_upgrade_external_chart` script:

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

Alternatively - you can use `kubectl apply -f` to install kubernetes templates directly without helm e.g.

```
./kamatera.sh cluster shell <ENVIRONMENT_NAME> kubectl apply -f kubernetes_template_file.yaml
```


## Configuring the load balancer

Configure the load balancer by setting values in `environments/ENVIRONMNET_NAME/values.yaml`,
check [this list](https://docs.traefik.io/configuration/acme/#provider) for the possible dns providers and required environment variables.
You can see where the configuration values are used in `templates/loadbalancer.yaml` and `templates/loadbalancer-conf.yaml`

Get the load balancer public IP to set DNS:

```
./kamatera.sh cluster loadbalancer info <ENVIRONMENT_NAME>
```

If you made any changes to the load balancer configuration you should update by re-running the install command without any additional arguments:

```
./kamatera.sh cluster loadbalancer install <ENVIRONMENT_NAME>
```

Traefik Web UI is not exposed publicly by default, you can access it via a proxy

```
./kamatera.sh cluster loadbalancer web-ui <ENVIRONMENT_NAME>
```

Load balancer Web UI is available at http://localhost:3033/
