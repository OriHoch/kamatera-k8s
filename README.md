# Kamatera ❤ Kubernetes

Documentation and code to help using Kamatera cloud for running Kubernetes workloads.


## Prerequisites

Installing dependencies on Ubuntu:

```
sudo apt-get install -y bash jq sshpass openssh-client python2.7
```

Login with your Kamatera API token

```
./kamatera.sh auth login
```


## Using an existing environment

Assuming there is an existing cluster and corresponding environment configuration files and secrets under `environments/ENVIRONMENT_NAME` directory:

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


## Create a new cluster

```
./kamatera.sh cluster create <ENVIRONMENT_NAME> <CPU> <RAM> <DISK_SIZE>
```

* **ENVIRONMENT_NAME** - a unique name to identify your cluster, e.g. `testing` / `production`
* **CPU** - should be at least `2B` = 2 cores
* **RAM** - should be at least `2048` = 2GB
* **DISK_SIZE** - in GB

See `kamatera_server_options.json` for the list of available CPU / RAM / DISK_SIZE options.

When the cluster is created you should have the cluster configuration available under `environments/ENVIRONMENT_NAME/`

Get the list of nodes from kubectl

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

Get the list of nodes, it might take a minute for the node to be in Running state

```
./kamatera.sh cluster shell <ENVIRONMENT_NAME> kubectl get nodes
```


## Creating a new environment

Assuming you have an existing cluster you can use and you have the `secret-admin.conf` file for authentication to that cluster.

You can copy another environment (under the `environments` directory) and modify the values, specifically, the `.env` file has the connection details and the `secret-admin.conf` file has the authentication secrets.


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
