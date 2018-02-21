# Kamatera ❤ Kubernetes

Step by step guide to setting up a kubernetes cluster using Kamatera cloud

[![Build Status](https://travis-ci.org/OriHoch/kamatera-k8s.svg?branch=master)](https://travis-ci.org/OriHoch/kamatera-k8s)


## Installation

Install system dependencies, following should work for Debian based systems:

```
sudo apt-get update &&\
sudo apt-get install curl gcc python-dev python-setuptools apt-transport-https apache2-utils \
                     lsb-release openssh-client git bash jq sshpass openssh-client bash-completion &&\
sudo easy_install -U pip &&\
sudo pip install -U crcmod python-dotenv pyyaml
```

Install [Kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/)

```
curl -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl &&\
chmod +x ./kubectl &&\
sudo mv ./kubectl /usr/local/bin/kubectl
```

Install [Helm](https://github.com/kubernetes/helm/blob/master/docs/install.md)

```
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get > get_helm.sh &&\
chmod 700 get_helm.sh &&\
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

Login with your Kamatera clientId and secret

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

You can also create a secure tunnel to the kubernetes dashboard

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

Let's start an Elasticsearch pod

```
kubectl run elasticsearch --image=docker.elastic.co/elasticsearch/elasticsearch-oss:6.2.1 --port=9200 --replicas=1 --env=discovery.type=single-node --expose
```

Wait for deployment to complete

```
kubectl rollout status elasticsearch
```


## Using port forwarding to access internal cluster services

You can connect to any pod in the cluster using kubectl port-forward

Following will start a port forward with the elasticsearch pod

```
kubectl port-forward `kubectl get pods | grep elasticsearch- | cut -d" " -f1 -` 9200
```

Elasticsearch should be accessible at http://localhost:9200


## Exposing internal cluster services publically

You can use the provided nginx pod to expose services

Edit `templates/nginx-conf.yaml` and add the following under `default.conf` before the last closing curly bracket:

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

Add http authentication to your elasticsearch by modifiying the location configuration to:

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


## Schedule workloads on the worker nodes

Recreate the elasticsearch pod, limited to worker nodes only

```
kubectl delete deployment/elasticsearch service/elasticsearch
kubectl run elasticsearch --image=docker.elastic.co/elasticsearch/elasticsearch-oss:6.2.1 \
                          --port=9200 --replicas=1 --env=discovery.type=single-node --expose \
                          --overrides='{"spec":{"template":{"spec":{"nodeSelector":{"kamateranode":"true"}}}}}'
kubectl rollout status deployment/elasticsearch && ./force_update.sh nginx
```

You can add additional worker nodes of different types

```
./kamatera.sh cluster node add <ENVIRONMENT_NAME> <CPU> <RAM> <DISK_SIZE>
```

The parameters following environment name may be modified to specify required resources:

* **CPU** - should be at least `2B` = 2 cores
* **RAM** - should be at least `2048` = 2GB
* **DISK_SIZE** - in GB

See `kamatera_server_options.json` for the list of available CPU / RAM / DISK_SIZE options.


## Configure persistent storage for workloads

Let's add persistent storage for the Elasticsearch deployment

Create the elasticsearch [Rook filesystem](https://github.com/rook/rook/blob/master/Documentation/filesystem.md) configuration and the pod configuration in `elasticsearch.yaml`:

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
---
apiVersion: v1
kind: Service
metadata:
  name: elasticsearch
spec:
  ports:
  - port: 9200
    targetPort: 9200
  selector:
    app: elasticsearch
---
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  labels:
    app: elasticsearch
  name: elasticsearch
spec:
  replicas: 1
  selector:
    matchLabels:
      app: elasticsearch
  template:
    metadata:
      labels:
        app: elasticsearch
    spec:
      containers:
      - env:
        - name: discovery.type
          value: single-node
        image: docker.elastic.co/elasticsearch/elasticsearch-oss:6.2.1
        name: elasticsearch
        ports:
        - containerPort: 9200
      nodeSelector:
        kamateranode: "true"
```

Deploy

```
kubectl delete deployment/elasticsearch service/elasticsearch
kubectl create -f elasticsearch.yaml
kubectl rollout status deployment/elasticsearch && ./force_update.sh nginx
```

Verify that the filesystem was created - `kubectl get filesystem -n rook`

To debug storage problems, use [Rook Toolbox](https://github.com/rook/rook/blob/master/Documentation/toolbox.md#rook-toolbox)


## Advanced topics

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

If you made any changes to the load balancer configuration you should update by re-running the install command without any additional arguments:

```
./kamatera.sh cluster loadbalancer install <ENVIRONMENT_NAME>
```

Traefik Web UI is not exposed publicly by default, you can access it via a proxy

```
./kamatera.sh cluster loadbalancer web-ui <ENVIRONMENT_NAME>
```

Load balancer Web UI is available at http://localhost:3033/
