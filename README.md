# Kamatera ❤ Kubernetes

Step by step guide to setting up a kubernetes cluster using [Kamatera Cloud Platform](https://www.kamatera.com/express/compute/?scamp=k8sgithub).

## Installation

[Install Docker Machine](https://docs.docker.com/machine/install-machine/)

Download the latest [Kamatera Docker Machine driver](https://github.com/OriHoch/docker-machine-driver-kamatera/releases), extract and place the binary in your PATH

Get a Kamatera API client id and secret from the Kamatera console web-ui

Set in environment variables:

```
export KAMATERA_API_CLIENT_ID=<YOUR_API_CLIENT_ID>
export KAMATERA_API_SECRET=<YOUR_API_SECRET>
```

## Create the kamatera-cloud-management Docker Machine

This is a standalone server used to run Rancher

```
docker-machine create --driver kamatera --kamatera-ram 2048 --kamatera-cpu 2B kamatera-cloud-management
```

Verify the cloud-management server is running and accessible via Docker Machine

```
eval $(docker-machine env kamatera-cloud-management) &&\
docker version && docker run hello-world
```

## Install Nginx and SSL on kamatera-cloud-management

The following script install Nginx and configures Let's Encrypt for SSL on the `kamatera-cloud-management` Docker Machine:

```
docker-machine ssh kamatera-cloud-management \
    'bash -c "curl -L https://raw.githubusercontent.com/OriHoch/kamatera-k8s/v2-rancher/cloud-management/install_nginx_ssl.sh | sudo bash"'
```

Get the kamatera-cloud-management server IP:

```
docker-machine ip kamatera-cloud-management
```

Register a subdomain to point to that IP e.g. `kamatera-cloud-management.your-domain.com`

Register the SSL certificate (set suitable values for the environment variables):

```
export LETSENCRYPT_EMAIL=your@email.com
export LETSENCRYPT_DOMAIN=kamatera-cloud-management.your-domain.com

docker-machine ssh kamatera-cloud-management \
    'bash -c "curl -L https://raw.githubusercontent.com/OriHoch/kamatera-k8s/v2-rancher/cloud-management/setup_ssl.sh \
                  | sudo bash -s '${LETSENCRYPT_EMAIL}' '${LETSENCRYPT_DOMAIN}'"'
```

## Install Rancher

Create the Rancher data directory

```
docker-machine ssh kamatera-cloud-management sudo mkdir -p /etc/kamatera-cloud/rancher
```

Start Rancher on kamatera-cloud-management

```
eval $(docker-machine env kamatera-cloud-management) &&\
docker run -d --name kamatera-rancher --restart unless-stopped \
               -p 8000:80 \
               -v "/etc/kamatera-cloud/rancher:/var/lib/rancher" \
               rancher/rancher:stable
```

Add Rancher to Nginx

```
export LETSENCRYPT_DOMAIN=kamatera-cloud-management.your-domain.com

docker-machine ssh kamatera-cloud-management \
    'bash -c "curl -L https://raw.githubusercontent.com/OriHoch/kamatera-k8s/v2-rancher/cloud-management/add_rancher_to_nginx.sh \
                  | sudo bash -s '${LETSENCRYPT_DOMAIN}'"'
```

## Create a Cluster

Wait a few minutes for Rancher to start, then activate it via the web-ui at your cloud management domain.

In the Rancher web-ui -

Node Drivers > Add Node Driver >
Paste the latest Linux amd64 [docker-machine-driver-kamatera](https://github.com/OriHoch/docker-machine-driver-kamatera/releases) release archive in the Download Url field and click Create.

Clusters > Add Cluster >
Choose Kamatera driver and configure the node pools - 
For each node pool, click on Add Node Template to set the Kamatera API keys and CPU / RAM settings

Recommended to use a minimum of CPU=2B and ram=2048 for each nodes and to create at least 1 dedicated master node for the control plane and etcd.
