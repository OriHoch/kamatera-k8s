# Kamatera ❤ Kubernetes

Step by step guide to setting up a kubernetes cluster using [Kamatera Cloud](https://www.kamatera.com/express/compute/?scamp=k8sgithub)

[![Build Status](https://travis-ci.org/OriHoch/kamatera-k8s.svg?branch=master)](https://travis-ci.org/OriHoch/kamatera-k8s)


## Installation

Install system dependencies on Debian/Ubuntu based systems:

```
sudo apt-get update
sudo apt-get install curl gcc python-dev python-setuptools apt-transport-https apache2-utils \
                     lsb-release openssh-client git bash jq sshpass openssh-client bash-completion
sudo easy_install -U pip
sudo pip install -U crcmod 'python-dotenv[cli]' pyyaml
```

Install system dependencies on CentOS/RHEL based systems:

```
yum update -y
yum install -y curl gcc python-dev python-setuptools apt-transport-https apache2-utils \
                    lsb-release openssh-client git bash jq sshpass openssh-client bash-completion
easy_install -U pip
pip install -U crcmod 'python-dotenv[cli]' pyyaml
```


Install [Kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/)

```
curl -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl
chmod +x ./kubectl
sudo mv ./kubectl /usr/local/bin/kubectl
```

Install [Helm](https://github.com/kubernetes/helm/blob/master/docs/install.md)

```
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get > get_helm.sh
chmod 700 get_helm.sh
./get_helm.sh
```

Clone the `kamatera-k8s` repository

```
git clone https://github.com/OriHoch/kamatera-k8s.git
```

All the following commands should run from the kamatera-k8s directory

```
cd kamatera-k8s
```


## Login to Kamatera Cloud

Login with your Kamatera API clientId and secret

```
./kamatera.sh auth login
```


## Create a new cluster

Creates a full cluster, containing 1 master node, 1 worker node and 1 load balancer node

```
./kamatera.sh cluster create <ENVIRONMENT_NAME>
```

* **ENVIRONMENT_NAME** - a unique name to identify your cluster, e.g. `testing` / `production`

When the cluster is created you should have the cluster configuration available under `environments/ENVIRONMENT_NAME/`


## Kubernetes Dashboard

Check the output log of cluster create for your dashboard URL and credentials

You can also create a secure tunnel to the kubernetes dashboard allowing to access it without a password

```
./kamatera.sh cluster web-ui <ENVIRONMENT_NAME>
```

The Kubernets Dashboard will then be available at http://localhost:9090/


## Run a workload on the cluster

Start a shell connected to the relevant environment

```
./kamatera.sh cluster shell <ENVIRONMENT_NAME>
```

All kubectl commands will now run for this environment

Start a tiny Elasticsearch pod on the cluster, limited to worker nodes only

```
kubectl run elasticsearch --image=docker.elastic.co/elasticsearch/elasticsearch-oss:6.2.1 \
                          --port=9200 --replicas=1 --env=discovery.type=single-node --expose \
                          --requests=cpu=100m,memory=300Mi \
                          --limits=cpu=300m,memory=600Mi \
                          --env=ES_JAVA_OPTS="-Xms256m -Xmx256m" \
                          --overrides='{"spec":{"template":{"spec":{"nodeSelector":{"kamateranode":"true"}}}}}'
```

Wait for deployment to complete (might take a bit to download the elasticsearch image)

```
kubectl rollout status deployment elasticsearch
```

Check the pod status and logs

```
kubectl get pods
kubectl logs ELASTICSEARCH_POD_NAME
```


## Add worker nodes

You can add additional worker nodes of different types

```
./kamatera.sh cluster node add <ENVIRONMENT_NAME> <CPU> <RAM> <DISK_SIZE>
```

The parameters following environment name may be modified to specify required resources:

* **CPU** - should be at least `2B` = 2 cores
* **RAM** - should be at least `2048` = 2GB
* **DISK_SIZE** - in GB

See `kamatera_server_options.json` for the list of available CPU / RAM / DISK_SIZE options.

Once the node is added and joined the cluster, workloads will automatically start to be scheduled on it.

You should restrict workloads to the worker nodes only by setting the following node selector on the pods:

```
nodeSelector:
    kamateranode: "true"
```


## Configure persistent storage for workloads

You can add persistent storage using the pre-installed [Rook cluster](https://rook.io/)

Add a [Rook filesystem](https://github.com/rook/rook/blob/master/Documentation/filesystem.md) to provide simple shared filesystem for persistent storage

```
apiVersion: rook.io/v1alpha1
kind: Filesystem
metadata:
  name: elasticsearchfs
  namespace: rook
spec:
  metadataPool:
    replicated:
      size: 3
  dataPools:
    - erasureCoded:
       dataChunks: 2
       codingChunks: 1
  metadataServer:
    activeCount: 1
    activeStandby: true
```

And use it in a pod

```
        volumeMounts:
        - name: data
          mountPath: /data
      volumes:
      - name: data
        flexVolume:
          driver: rook.io/rook
          fsType: ceph
          options:
            fsName: data
            clusterName: rook
```

Once the filesystem is deployed you can verify by running `kubectl get filesystem -n rook`

To debug storage problems, use [Rook Toolbox](https://github.com/rook/rook/blob/master/Documentation/toolbox.md#rook-toolbox)


## Using port forwarding to access internal cluster services

You can connect to any pod in the cluster using kubectl port-forward.

This is a good option to connect to internal services without exposing them publically and dealing with authentication.

Following will start a port from your local machine port 9200 to an elasticsearch pod on port 9200

```
kubectl port-forward `kubectl get pods | grep elasticsearch- | cut -d" " -f1 -` 9200
```

Elasticsearch should be accessible at http://localhost:9200


## Exposing internal cluster services publically

You can use the provided nginx pod to expose services

Modify the nginx configuration in `templates/nginx-conf.yaml` according to the routing requirements

For example, add the following under `default.conf` before the last closing curly bracket to route to the elasticsearch pod:

```
      location /elasticsearch {
        proxy_pass http://elasticsearch:9200/;
      }
```

Reload the loadbalancer to apply configuration changes

```
./kamatera.sh cluster loadbalancer reload <ENVIRONMENT_NAME>
```

Elasticsearch should be accessible at https://PUBLIC_IP/elasticsearch

(You can get your IP by running `./kamatera.sh cluster loadbalancer info <ENVIRONMENT_NAME>` )


## Simple service security using http authentication

Add http authentication to your elasticsearch by adding `include /etc/nginx/conf.d/restricted.inc;` to the relevant location configuration

For example:

```
      location /elasticsearch {
        proxy_pass http://elasticsearch:9200/;
        include /etc/nginx/conf.d/restricted.inc;
      }
```

The nginx password is stored in a kubernetes secret, you can modify the htpasswd file used:

```
htpasswd -bc secret-htpasswd-file username "$(read -sp password: && echo $REPLY)"
kubectl delete secret nginx-htpasswd
kubectl create secret generic nginx-htpasswd --from-file=secret-htpasswd-file
```

Apply the changes by reloading the loadbalancer

```
./kamatera.sh cluster loadbalancer reload <ENVIRONMENT_NAME>
```


## Advanced topics


### Node Management

Get list of nodes

```
kubectl get nodes
```

Drain a problematic node

```
kubectl drain NODE_NAME
```

You can reboot the node servers from kamatera web UI, the cluster will be updated automatically

Once node is back, allow to schedule workloads on it

```
kubectl uncordon NODE_NAME
```


### Using Helm for Deployment

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


### Load Balancer configuration

Configure the load balancer by setting values in `environments/ENVIRONMNET_NAME/values.yaml`,
check [this list](https://docs.traefik.io/configuration/acme/#provider) for the possible dns providers and required environment variables.
You can see where the configuration values are used in `templates/loadbalancer.yaml` and `templates/loadbalancer-conf.yaml`

Get the load balancer public IP to set DNS:

```
./kamatera.sh cluster loadbalancer info <ENVIRONMENT_NAME>
```

If you made any changes to the load balancer configuration you should reload

```
./kamatera.sh cluster loadbalancer reload <ENVIRONMENT_NAME>
```

Traefik Web UI is not exposed publicly by default, you can access it via a proxy

```
./kamatera.sh cluster loadbalancer web-ui <ENVIRONMENT_NAME>
```

Load balancer Web UI is available at http://localhost:3033/
